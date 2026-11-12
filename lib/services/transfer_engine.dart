import 'dart:convert';
import 'dart:io';

const int transferChunkBytes = 256 * 1024;

/// Stream file bytes from disk with a bounded working set and resume offset.
/// Call only over a SecureSocket whose peer identity has been verified.
class TransferEngine {
  Future<void> sendFile({required Socket socket, required File file, required String relativePath, int resumeFromByte = 0, void Function(int bytesSent)? onProgress}) async {
    final length = await file.length();
    if (resumeFromByte < 0 || resumeFromByte > length) throw RangeError.range(resumeFromByte, 0, length, 'resumeFromByte');
    await _writeHeader(socket, {'type': 'file', 'path': relativePath, 'length': length, 'resumeFrom': resumeFromByte, 'chunkSize': transferChunkBytes});
    var sent = resumeFromByte;
    await for (final chunk in file.openRead(resumeFromByte)) {
      socket.add(chunk);
      sent += chunk.length;
      onProgress?.call(sent);
      await socket.flush();
    }
    await socket.flush();
  }

  Future<void> receiveFile({required Socket socket, required File destination, required int length, required int resumeFromByte, void Function(int bytesReceived)? onProgress}) async {
    if (resumeFromByte < 0 || resumeFromByte > length) throw RangeError.range(resumeFromByte, 0, length, 'resumeFromByte');
    final existingLength = await destination.exists() ? await destination.length() : 0;
    if (existingLength != resumeFromByte) throw StateError('Destination length does not match the validated resume offset');
    await destination.parent.create(recursive: true);
    final sink = destination.openWrite(mode: resumeFromByte == 0 ? FileMode.write : FileMode.append);
    var received = resumeFromByte;
    try {
      await for (final chunk in socket) {
        if (received + chunk.length > length) throw const FormatException('Payload exceeds declared size');
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received);
        if (received == length) break;
      }
      if (received != length) throw const SocketException('Connection closed before transfer completed');
      await sink.flush();
    } finally { await sink.close(); }
  }

  /// Rejects absolute paths, traversal, and empty components before a caller
  /// joins a peer-supplied relative path to the selected destination folder.
  String validateRelativePath(String value) {
    if (value.isEmpty || value.startsWith('/') || value.startsWith('\\') || RegExp(r'^[a-zA-Z]:').hasMatch(value)) {
      throw const FormatException('Expected a relative file path');
    }
    final parts = value.replaceAll('\\', '/').split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..' || part.contains(':'))) {
      throw const FormatException('Unsafe path component');
    }
    return parts.join(Platform.pathSeparator);
  }

  Future<void> _writeHeader(Socket socket, Map<String, Object> header) async {
    final bytes = utf8.encode(jsonEncode(header));
    if (bytes.length > 65536) throw const FormatException('Header too large');
    socket.add([bytes.length >> 8, bytes.length & 0xff, ...bytes]);
    await socket.flush();
  }
}

class SecureTransferListener {
  Future<SecureServerSocket> listen({required InternetAddress address, required int port, required SecurityContext context}) => SecureServerSocket.bind(address, port, context, shared: true);
}
