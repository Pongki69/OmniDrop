import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

const int _chunkSize = 1024 * 1024;
const int _maxManifestFiles = 100;

class TransferCancelledException implements Exception {
  const TransferCancelledException(this.message);
  final String message;

  @override
  String toString() => message;
}

class TransferPausedException implements Exception {
  const TransferPausedException();
}

/// Authenticated, encrypted file transport used only after the pairing secret
/// has been retrieved from the platform secure store.
class TrustedTransferProtocol {
  static final _hmac = Hmac.sha256();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: _hmac, outputLength: 32);

  static Future<void> send({
    required Socket socket,
    required String localDeviceId,
    required String localName,
    required String transferId,
    required List<int> secret,
    required List<File> files,
    bool Function()? isCancelled,
    bool Function()? isPaused,
    bool chatAttachment = false,
    void Function(String fileName, int sent, int total)? onProgress,
  }) async {
    if (files.isEmpty || files.length > _maxManifestFiles) {
      throw const FormatException('Choose between 1 and 100 files.');
    }
    final clientNonce = _randomBytes(16);
    final reader = TransferSocketReader(socket);
    try {
      await _writeLine(socket, {
        'type': 'transfer_request',
        'device_id': localDeviceId,
        'device_name': localName,
        'nonce': base64Encode(clientNonce),
        'transfer_id': transferId,
      });
      final challenge = await _readResponse(reader,
          timeout: const Duration(seconds: 20));
      if (challenge['type'] != 'transfer_challenge' ||
          challenge['nonce'] is! String ||
          challenge['proof'] is! String) {
        throw const FormatException('The trusted device sent an invalid challenge.');
      }
      final serverNonce = base64Decode(challenge['nonce'] as String);
      final transcript = _transcript(localDeviceId, clientNonce, serverNonce);
      if (!_constantTimeEquals(
          await _mac(secret, <int>[...utf8.encode('server'), ...transcript]),
          base64Decode(challenge['proof'] as String))) {
        throw const FormatException('The trusted device could not be authenticated.');
      }
      await _writeLine(socket, {
        'type': 'transfer_auth',
        'proof': base64Encode(await _mac(
            secret, <int>[...utf8.encode('client'), ...transcript])),
      });
      final key = await _sessionKey(secret, clientNonce, serverNonce);
      final manifest = <Map<String, Object>>[];
      for (final file in files) {
        manifest.add({
          'name': file.uri.pathSegments.isEmpty
              ? 'file'
              : Uri.decodeComponent(file.uri.pathSegments.last),
          'size': await file.length(),
          'modified': (await file.lastModified()).millisecondsSinceEpoch,
        });
      }
      final encryptedManifest = await _aes.encrypt(
          utf8.encode(jsonEncode({
            'files': manifest,
            'context': chatAttachment ? 'chat' : 'transfer',
            'transfer_id': transferId,
          })),
          secretKey: key,
          nonce: _nonce(clientNonce, 0),
          aad: utf8.encode('manifest'));
      await _writeLine(socket, {
        'type': 'manifest',
        'ciphertext': base64Encode(encryptedManifest.cipherText),
        'mac': base64Encode(encryptedManifest.mac.bytes),
      });
      final decision = await _readResponse(reader,
          timeout: const Duration(minutes: 2, seconds: 15));
      if (decision['type'] != 'transfer_decision' ||
          decision['accepted'] != true) {
        throw const SocketException('The recipient declined this transfer.');
      }
      final rawOffsets = decision['resume_offsets'];
      if (rawOffsets is! List || rawOffsets.length != files.length ||
          rawOffsets.any((value) => value is! int)) {
        throw const FormatException('The recipient sent invalid resume information.');
      }
      var remoteResponseReady = false;
      final remoteResponse = reader.readJsonLine().then((value) {
        remoteResponseReady = true;
        return value;
      }, onError: (Object error, StackTrace stackTrace) {
        remoteResponseReady = true;
        Error.throwWithStackTrace(error, stackTrace);
      });
      unawaited(remoteResponse.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
        if (isPaused?.call() == true) throw const TransferPausedException();
        if (isCancelled?.call() == true) {
          throw const TransferCancelledException('Transfer cancelled.');
        }
        var sent = rawOffsets[fileIndex] as int;
        final total = manifest[fileIndex]['size']! as int;
        if (sent < 0 || sent > total ||
            (sent != total && sent % _chunkSize != 0)) {
          throw const FormatException('The resume position is invalid.');
        }
        onProgress?.call(manifest[fileIndex]['name']! as String, sent, total);
        final handle = await files[fileIndex].open(mode: FileMode.read);
        try {
          await handle.setPosition(sent);
          while (sent < total) {
            if (isPaused?.call() == true) throw const TransferPausedException();
            if (isCancelled?.call() == true) {
              throw const TransferCancelledException('Transfer cancelled.');
            }
            if (isPaused?.call() == true) throw const TransferPausedException();
            final chunk = await _readFileChunk(handle, min(_chunkSize, total - sent));
            if (chunk.length != min(_chunkSize, total - sent)) {
              throw const FileSystemException('File changed during transfer.');
            }
            final chunkIndex = sent ~/ _chunkSize;
            final nonce = _nonce(clientNonce,
                ((fileIndex + 1) << 32) | (chunkIndex + 1));
            final box = await _aes.encrypt(chunk,
                secretKey: key,
                nonce: nonce,
                aad: utf8.encode('$fileIndex:$sent'));
            final encrypted = <int>[...box.cipherText, ...box.mac.bytes];
            await _writeFrame(socket, encrypted);
            sent += chunk.length;
            onProgress?.call(manifest[fileIndex]['name']! as String, sent, total);
            if (isCancelled?.call() == true) {
              throw const TransferCancelledException('Transfer cancelled.');
            }
            if (remoteResponseReady) {
              final response = await remoteResponse;
              if (response['type'] == 'transfer_cancelled') {
                throw TransferCancelledException(
                    response['message'] as String? ?? 'The receiving device cancelled this transfer.');
              }
              if (response['type'] == 'transfer_error') {
                throw SocketException(response['message'] as String? ?? 'The receiving device could not complete this transfer.');
              }
              throw const FormatException('The receiving device sent an unexpected transfer response.');
            }
          }
        } finally {
          await handle.close();
        }
      }
      await _writeLine(socket, {
        'type': 'transfer_complete',
        'transfer_id': transferId,
      });
      final receipt = await remoteResponse.timeout(const Duration(seconds: 45));
      if (receipt['type'] == 'transfer_cancelled') {
        throw TransferCancelledException(
            receipt['message'] as String? ?? 'The receiving device cancelled this transfer.');
      }
      if (receipt['type'] == 'transfer_error') {
        throw SocketException(receipt['message'] as String? ?? 'The receiving device could not complete this transfer.');
      }
      if (receipt['type'] != 'transfer_receipt' || receipt['accepted'] != true) {
        throw const SocketException('The recipient could not complete the transfer.');
      }
    } finally {
      await reader.close();
    }
  }

  static Future<void> serve({
    required Socket socket,
    required TransferSocketReader reader,
    required Map<String, dynamic> request,
    required Future<List<int>?> Function(String deviceId) secretFor,
    required Future<bool> Function(IncomingTransferOffer offer) acceptOffer,
    required Future<Directory> Function() destination,
    Future<String> Function(File file, String name)? publishFile,
    Future<bool> Function(String path)? publishedFileExists,
    void Function(IncomingTransferFile file, int received, bool complete)? onProgress,
  }) async {
    final deviceId = request['device_id'];
    final name = request['device_name'];
    final transferId = request['transfer_id'];
    if (deviceId is! String || deviceId.isEmpty ||
        name is! String || name.length > 64 || request['nonce'] is! String ||
        transferId is! String || transferId.isEmpty || transferId.length > 96) {
      throw const FormatException('Invalid transfer request.');
    }
    final secret = await secretFor(deviceId);
    if (secret == null || secret.length < 32) {
      await _writeLine(socket, {'type': 'transfer_decision', 'accepted': false});
      return;
    }
    final clientNonce = base64Decode(request['nonce'] as String);
    if (clientNonce.length != 16) throw const FormatException('Invalid transfer nonce.');
    final serverNonce = _randomBytes(16);
    final transcript = _transcript(deviceId, clientNonce, serverNonce);
    await _writeLine(socket, {
      'type': 'transfer_challenge',
      'nonce': base64Encode(serverNonce),
      'proof': base64Encode(await _mac(
          secret, <int>[...utf8.encode('server'), ...transcript])),
    });
    final auth = await reader.readJsonLine().timeout(const Duration(seconds: 20));
    if (auth['type'] != 'transfer_auth' || auth['proof'] is! String ||
        !_constantTimeEquals(
            await _mac(secret, <int>[...utf8.encode('client'), ...transcript]),
            base64Decode(auth['proof'] as String))) {
      throw const FormatException('Sender authentication failed.');
    }
    final key = await _sessionKey(secret, clientNonce, serverNonce);
    final manifestPayload = await reader.readJsonLine().timeout(const Duration(seconds: 20));
    if (manifestPayload['type'] != 'manifest' ||
        manifestPayload['ciphertext'] is! String || manifestPayload['mac'] is! String) {
      throw const FormatException('Invalid file list.');
    }
    final clearManifest = await _aes.decrypt(
        SecretBox(base64Decode(manifestPayload['ciphertext'] as String),
            nonce: _nonce(clientNonce, 0),
            mac: Mac(base64Decode(manifestPayload['mac'] as String))),
        secretKey: key,
        aad: utf8.encode('manifest'));
    final decodedManifest = jsonDecode(utf8.decode(clearManifest)) as Map<String, dynamic>;
    final rawFiles = decodedManifest['files'];
    final manifestContext = decodedManifest['context'];
    if (decodedManifest['transfer_id'] != transferId) {
      throw const FormatException('Transfer identity did not match.');
    }
    if (rawFiles is! List || rawFiles.isEmpty || rawFiles.length > _maxManifestFiles) {
      throw const FormatException('Invalid file list.');
    }
    final files = <IncomingTransferFile>[];
    for (final raw in rawFiles) {
      if (raw is! Map || raw['name'] is! String || raw['size'] is! int || raw['modified'] is! int) {
        throw const FormatException('Invalid file entry.');
      }
      final fileName = _safeFileName(raw['name'] as String);
      final size = raw['size'] as int;
      if (size < 0 || size > 20 * 1024 * 1024 * 1024) {
        throw const FormatException('File size is outside the supported range.');
      }
      files.add(IncomingTransferFile(
          name: fileName, size: size, modified: raw['modified'] as int));
    }
    final offer = IncomingTransferOffer(
        deviceId: deviceId,
        deviceName: name,
        files: List.unmodifiable(files),
        isChatAttachment: manifestContext == 'chat');
    final accepted = await acceptOffer(offer);
    if (!accepted) {
      await _writeLine(socket, {'type': 'transfer_decision', 'accepted': false});
      return;
    }

    final folder = await destination();
    await folder.create(recursive: true);
    final partialRoot = Directory('${folder.path}${Platform.pathSeparator}.omnidrop_partials');
    await partialRoot.create(recursive: true);
    await _removeExpiredPartials(partialRoot);
    final transferFolder = Directory(
        '${partialRoot.path}${Platform.pathSeparator}${await _transferToken(transferId)}');
    await transferFolder.create(recursive: true);
    final manifestStamp = jsonEncode([
      for (final file in files)
        {'name': file.name, 'size': file.size, 'modified': file.modified}
    ]);
    final completionMarker = File('${transferFolder.path}${Platform.pathSeparator}complete.json');
    List<String>? completedPaths;
    if (await completionMarker.exists()) {
      try {
        final marker = jsonDecode(await completionMarker.readAsString()) as Map<String, dynamic>;
        final paths = marker['paths'];
        if (marker['manifest'] == manifestStamp && paths is List &&
            paths.length == files.length && paths.every((path) => path is String)) {
          final storedPaths = paths.cast<String>();
          final pathChecks = await Future.wait(storedPaths.map((path) =>
              publishedFileExists?.call(path) ?? File(path).exists()));
          if (pathChecks.every((exists) => exists)) completedPaths = storedPaths;
          else await completionMarker.delete();
        } else {
          await completionMarker.delete();
        }
      } catch (_) {
        await completionMarker.delete();
      }
    }
    final partialFiles = <File>[];
    final resumeOffsets = <int>[];
    for (var i = 0; i < files.length; i++) {
      if (completedPaths != null) {
        partialFiles.add(File(completedPaths[i]));
        resumeOffsets.add(files[i].size);
      } else {
        final prepared = await _preparePartial(transferFolder, i, files[i]);
        partialFiles.add(prepared.$1);
        resumeOffsets.add(prepared.$2);
      }
    }
    await _writeLine(socket, {
      'type': 'transfer_decision',
      'accepted': true,
      'resume_offsets': resumeOffsets,
    });
    try {
      for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
        final file = files[fileIndex];
        var received = resumeOffsets[fileIndex];
        onProgress?.call(file, received, received == file.size);
        if (completedPaths != null || received == file.size) {
          onProgress?.call(file, received, true);
          continue;
        }
        final handle = await partialFiles[fileIndex].open(mode: FileMode.append);
        await handle.setPosition(received);
        var chunksSinceFlush = 0;
        try {
          while (received < file.size) {
            final expectedPlain = min(_chunkSize, file.size - received);
            final encrypted = await reader.readFrame(expectedPlain + 16);
            final chunkIndex = received ~/ _chunkSize;
            final nonce = _nonce(clientNonce,
                ((fileIndex + 1) << 32) | (chunkIndex + 1));
            final clear = await _aes.decrypt(
                SecretBox(encrypted.sublist(0, encrypted.length - 16),
                    nonce: nonce,
                    mac: Mac(encrypted.sublist(encrypted.length - 16))),
                secretKey: key,
                aad: utf8.encode('$fileIndex:$received'));
            if (clear.length != expectedPlain) {
              throw const FormatException('Encrypted chunk size did not match.');
            }
            await handle.writeFrom(clear);
            received += clear.length;
            chunksSinceFlush++;
            if (chunksSinceFlush >= 8) {
              await handle.flush();
              chunksSinceFlush = 0;
            }
            onProgress?.call(file, received, false);
          }
          await handle.flush();
        } finally {
          await handle.close();
        }
        onProgress?.call(file, received, true);
      }
      final complete = await reader.readJsonLine();
      final acceptedReceipt = complete['type'] == 'transfer_complete' &&
          complete['transfer_id'] == transferId;
      if (!acceptedReceipt && completedPaths == null) {
        throw const FormatException('Transfer did not finish cleanly.');
      }
      if (completedPaths == null) {
        final finalPaths = <String>[];
        for (var i = 0; i < files.length; i++) {
          final finalFile = await _uniqueDestination(folder, files[i].name);
          final moved = await partialFiles[i].rename(finalFile.path);
          finalPaths.add(await publishFile?.call(moved, files[i].name) ?? moved.path);
        }
        await completionMarker.writeAsString(jsonEncode({
          'manifest': manifestStamp,
          'paths': finalPaths,
          'completed_at': DateTime.now().millisecondsSinceEpoch,
        }));
      }
      await _writeLine(socket, {'type': 'transfer_receipt', 'accepted': acceptedReceipt});
    } catch (_) {
      // Verified complete chunks stay in the hidden partial directory so a
      // retry can continue from the last durable boundary.
      rethrow;
    }
  }

  static Future<List<int>> _mac(List<int> secret, List<int> data) async =>
      (await _hmac.calculateMac(data, secretKey: SecretKey(secret))).bytes;

  static Future<Map<String, dynamic>> _readResponse(TransferSocketReader reader,
      {required Duration timeout}) async {
    final response = await reader.readJsonLine().timeout(timeout);
    if (response['type'] == 'transfer_cancelled') {
      throw TransferCancelledException(
          response['message'] as String? ?? 'The receiving device cancelled this transfer.');
    }
    if (response['type'] == 'transfer_error') {
      final message = response['message'];
      throw SocketException(message is String
          ? message
          : 'The other device could not complete the transfer.');
    }
    return response;
  }

  static Future<SecretKey> _sessionKey(
      List<int> secret, List<int> client, List<int> server) =>
      _hkdf.deriveKey(
          secretKey: SecretKey(secret),
          nonce: <int>[...client, ...server],
          info: utf8.encode('OmniDrop trusted file transfer v1'));

  static List<int> _transcript(String deviceId, List<int> client, List<int> server) =>
      <int>[...utf8.encode(deviceId), 0, ...client, ...server];

  static List<int> _randomBytes(int length) =>
      List<int>.generate(length, (_) => Random.secure().nextInt(256));

  static List<int> _nonce(List<int> prefix, int counter) => <int>[
        ...prefix.take(4),
        for (var shift = 56; shift >= 0; shift -= 8) (counter >> shift) & 0xff,
      ];

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  static String _safeFileName(String input) {
    final normalized = input.replaceAll('\\', '/').split('/').last;
    final safe = normalized.replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_').trim();
    if (safe.isEmpty || safe == '.' || safe == '..') {
      throw const FormatException('Unsafe file name.');
    }
    return safe.length > 240 ? safe.substring(safe.length - 240) : safe;
  }

  static Future<(File, int)> _preparePartial(
      Directory transferFolder, int index, IncomingTransferFile file) async {
    final stem = index.toString().padLeft(3, '0');
    final partial = File('${transferFolder.path}${Platform.pathSeparator}$stem.part');
    final metadata = File('${transferFolder.path}${Platform.pathSeparator}$stem.json');
    var matching = false;
    if (await metadata.exists() && await partial.exists()) {
      try {
        final saved = jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
        matching = saved['name'] == file.name &&
            saved['size'] == file.size &&
            saved['modified'] == file.modified;
      } catch (_) {
        matching = false;
      }
    }
    if (!matching) {
      if (await partial.exists()) await partial.delete();
      await metadata.writeAsString(jsonEncode({
        'name': file.name,
        'size': file.size,
        'modified': file.modified,
      }));
      final handle = await partial.open(mode: FileMode.writeOnlyAppend);
      await handle.close();
      return (partial, 0);
    }
    final length = await partial.length();
    if (length > file.size) {
      await partial.delete();
      final handle = await partial.open(mode: FileMode.writeOnlyAppend);
      await handle.close();
      return (partial, 0);
    }
    final offset = length == file.size ? length : length - (length % _chunkSize);
    if (offset != length) {
      final handle = await partial.open(mode: FileMode.append);
      await handle.truncate(offset);
      await handle.close();
    }
    return (partial, offset);
  }

  static Future<String> _transferToken(String transferId) async {
    final digest = await Sha256().hash(utf8.encode(transferId));
    return digest.bytes.take(16)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static Future<void> _removeExpiredPartials(Directory root) async {
    try {
      final now = DateTime.now();
      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory) {
          final modified = await entity.stat().then((stat) => stat.modified);
          if (now.difference(modified) > const Duration(days: 1)) {
            await entity.delete(recursive: true);
          }
        }
      }
    } on FileSystemException {
      // A stale partial must never block a new transfer.
    }
  }

  static Future<File> _uniqueDestination(Directory folder, String name) async {
    var candidate = File('${folder.path}${Platform.pathSeparator}$name');
    if (!await candidate.exists()) return candidate;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var i = 1; i < 10000; i++) {
      candidate = File('${folder.path}${Platform.pathSeparator}$stem ($i)$extension');
      if (!await candidate.exists()) return candidate;
    }
    throw const FileSystemException('Could not choose a unique download name.');
  }
}

class IncomingTransferFile {
  const IncomingTransferFile({required this.name, required this.size, required this.modified});
  final String name;
  final int size;
  final int modified;
}

class IncomingTransferOffer {
  IncomingTransferOffer({required this.deviceId, required this.deviceName, required this.files, this.isChatAttachment = false});
  final String deviceId;
  final String deviceName;
  final List<IncomingTransferFile> files;
  final bool isChatAttachment;
  final Completer<bool> decision = Completer<bool>();
}

class IncomingTransferProgress {
  const IncomingTransferProgress({
    required this.transferId,
    required this.deviceId,
    required this.deviceName,
    required this.fileName,
    required this.bytesReceived,
    required this.totalBytes,
    required this.complete,
    this.failed = false,
  });

  final String transferId;
  final String deviceId;
  final String deviceName;
  final String fileName;
  final int bytesReceived;
  final int totalBytes;
  final bool complete;
  final bool failed;
}

class TransferSocketReader {
  TransferSocketReader(this.socket) : _iterator = StreamIterator<List<int>>(socket);
  final Socket socket;
  final StreamIterator<List<int>> _iterator;
  final List<int> _buffer = [];

  Future<int?> _takeByte() async {
    while (_buffer.isEmpty) {
      if (!await _iterator.moveNext()) return null;
      _buffer.addAll(_iterator.current);
    }
    return _buffer.removeAt(0);
  }

  Future<String> readLine() async {
    final bytes = <int>[];
    while (bytes.length <= 65536) {
      final byte = await _takeByte();
      if (byte == null) throw const SocketException('Connection closed unexpectedly.');
      if (byte == 10) return utf8.decode(bytes).replaceFirst(RegExp(r'\r$'), '');
      bytes.add(byte);
    }
    throw const FormatException('Protocol message is too large.');
  }

  Future<Map<String, dynamic>> readJsonLine() async =>
      jsonDecode(await readLine()) as Map<String, dynamic>;

  Future<List<int>> readExact(int count) async {
    final result = <int>[];
    while (result.length < count) {
      if (_buffer.isEmpty) {
        if (!await _iterator.moveNext()) throw const SocketException('Connection closed during transfer.');
        _buffer.addAll(_iterator.current);
      }
      final take = min(count - result.length, _buffer.length);
      result.addAll(_buffer.getRange(0, take));
      _buffer.removeRange(0, take);
    }
    return result;
  }

  Future<List<int>> readFrame(int expectedMax) async {
    final header = await readExact(4);
    final length = (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
    if (length < 16 || length > expectedMax) throw const FormatException('Invalid encrypted chunk frame.');
    return readExact(length);
  }

  Future<void> close() => _iterator.cancel();
}

Future<void> _writeLine(Socket socket, Map<String, Object?> value) async {
  socket.write('${jsonEncode(value)}\n');
  await socket.flush();
}

Future<void> _writeFrame(Socket socket, List<int> bytes) async {
  final n = bytes.length;
  socket.add([(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);
  socket.add(bytes);
  await socket.flush();
}

Future<List<int>> _readFileChunk(RandomAccessFile file, int expected) async {
  final bytes = <int>[];
  while (bytes.length < expected) {
    final part = await file.read(expected - bytes.length);
    if (part.isEmpty) break;
    bytes.addAll(part);
  }
  return bytes;
}
