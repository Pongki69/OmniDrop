import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bonsoir/bonsoir.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/peer.dart';
import 'pairing_key_store.dart';
import 'trusted_transfer_protocol.dart';
import 'trusted_chat_protocol.dart';
import 'platform_storage_service.dart';

const String omniDropServiceType = '_omnidrop._tcp';
const int omniDropDirectPort = 53679;

/// Advertises this running OmniDrop instance and discovers other instances on
/// the local network. Only resolved OmniDrop TXT records are surfaced.
class LocalDiscoveryService {
  final Map<String, Peer> _peersByService = {};
  final Map<String, Peer> _directPeersById = {};
  final StreamController<List<Peer>> _updates = StreamController.broadcast();
  final StreamController<PairingRequest> _pairingRequests =
      StreamController.broadcast();
  final StreamController<IncomingTransferOffer> _incomingTransfers =
      StreamController.broadcast();
  final StreamController<IncomingTransferProgress> _transferProgress =
      StreamController.broadcast();
  final StreamController<IncomingChatMessage> _chatMessages =
      StreamController.broadcast();
  final Map<String, PairingRequest> _pendingPairings = {};
  final Map<String, Socket> _outgoingTransferSockets = {};
  final Set<String> _pausedTransferIds = {};
  final Map<String, Socket> _incomingTransferSockets = {};
  final Set<String> _cancelledTransferIds = {};
  final PairingKeyStore _keyStore = PairingKeyStore();
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _subscription;
  ServerSocket? _presenceSocket;
  String? _localDeviceId;
  String? _localServiceName;

  Stream<List<Peer>> get peers => _updates.stream;
  Stream<PairingRequest> get pairingRequests => _pairingRequests.stream;
  Stream<IncomingTransferOffer> get incomingTransfers =>
      _incomingTransfers.stream;
  Stream<IncomingTransferProgress> get transferProgress =>
      _transferProgress.stream;
  Stream<IncomingChatMessage> get chatMessages => _chatMessages.stream;

  Future<void> start() async {
    await stop();
    final deviceId = await _stableDeviceId();
    _localDeviceId = deviceId;
    _localServiceName = 'OmniDrop-${deviceId.substring(0, 8)}';

    _presenceSocket =
        await ServerSocket.bind(InternetAddress.anyIPv4, omniDropDirectPort);
    _presenceSocket!.listen(_handleSocket);

    _broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: _localServiceName!,
        type: omniDropServiceType,
        port: _presenceSocket!.port,
        attributes: {
          'app': 'omnidrop',
          'device_id': deviceId,
          'device_name': Platform.localHostname,
          'device_kind': _deviceKind.name,
          'protocol': '1',
        },
      ),
    );
    await _broadcast!.initialize();
    await _broadcast!.start();

    _discovery = BonsoirDiscovery(type: omniDropServiceType);
    await _discovery!.initialize();
    _subscription = _discovery!.eventStream!.listen(_handleEvent);
    await _discovery!.start();
  }

  DeviceKind get _deviceKind {
    if (Platform.isAndroid || Platform.isIOS) return DeviceKind.phone;
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows)
      return DeviceKind.desktop;
    return DeviceKind.browser;
  }

  Future<void> _handleEvent(BonsoirDiscoveryEvent event) async {
    if (event is BonsoirDiscoveryServiceFoundEvent) {
      final service = event.service;
      if (service.name != _localServiceName) {
        await service.resolve(_discovery!.serviceResolver);
      }
      return;
    }
    if (event is BonsoirDiscoveryServiceLostEvent) {
      final service = event.service;
      _peersByService.remove(service.name);
      _publish();
      return;
    }
    if (event is! BonsoirDiscoveryServiceResolvedEvent) return;
    final service = event.service;
    if (service.name == _localServiceName) return;
    if (service.attributes['app'] != 'omnidrop' ||
        service.attributes['protocol'] != '1') return;
    final deviceId = service.attributes['device_id'];
    if (deviceId == null || deviceId == _localDeviceId) return;
    final deviceName = service.attributes['device_name']?.trim();
    final kindName = service.attributes['device_kind'];
    final matchingKinds =
        DeviceKind.values.where((value) => value.name == kindName);
    final kind =
        matchingKinds.isEmpty ? DeviceKind.desktop : matchingKinds.first;
    _peersByService[service.name] = Peer(
      id: deviceId,
      name:
          deviceName == null || deviceName.isEmpty ? service.name : deviceName,
      kind: kind,
      address: service.hostAddress,
      port: service.port,
      trusted: (await SharedPreferences.getInstance())
              .getStringList('omnidrop_trusted_devices')
              ?.contains(deviceId) ??
          false,
    );
    _publish();
  }

  void _publish() {
    final peersById = <String, Peer>{
      for (final peer in _peersByService.values) peer.id: peer,
      for (final peer in _directPeersById.values) peer.id: peer,
    };
    final peers = peersById.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (!_updates.isClosed) _updates.add(List.unmodifiable(peers));
  }

  Peer? peerForTransport(String deviceId, {required bool direct}) {
    if (direct) return _directPeersById[deviceId];
    for (final peer in _peersByService.values) {
      if (peer.id == deviceId) return peer;
    }
    return null;
  }

  Future<Peer> connectDirectEndpoint(String address) async {
    final socket = await Socket.connect(address, omniDropDirectPort,
        timeout: const Duration(seconds: 12));
    final reader = TransferSocketReader(socket);
    try {
      await _writeIdentityRequest(socket);
      final identity =
          await reader.readJsonLine().timeout(const Duration(seconds: 12));
      if (identity['type'] != 'direct_identity' ||
          identity['device_id'] is! String ||
          !RegExp(r'^[a-f0-9]{32}$')
              .hasMatch(identity['device_id'] as String) ||
          identity['device_name'] is! String ||
          (identity['device_name'] as String).length > 64) {
        throw const FormatException(
            'The nearby device did not identify itself as OmniDrop.');
      }
      final peer = Peer(
        id: identity['device_id'] as String,
        name: (identity['device_name'] as String).trim(),
        kind: _deviceKindForName(identity['device_kind']),
        address: address,
        port: omniDropDirectPort,
        trusted: (await SharedPreferences.getInstance())
                .getStringList('omnidrop_trusted_devices')
                ?.contains(identity['device_id']) ??
            false,
        isDirect: true,
      );
      _directPeersById[peer.id] = peer;
      _publish();
      return peer;
    } finally {
      await reader.close();
      socket.destroy();
    }
  }

  void disconnectDirectPeer(String deviceId) {
    _directPeersById.remove(deviceId);
    _publish();
  }

  void clearDirectPeers() {
    _directPeersById.clear();
    _publish();
  }

  DeviceKind _deviceKindForName(Object? value) =>
      DeviceKind.values.where((kind) => kind.name == value).firstOrNull ??
      DeviceKind.desktop;

  Future<void> _writeIdentityRequest(Socket socket) async {
    socket.write('${jsonEncode({
          'type': 'direct_identity_request',
          'device_id': _localDeviceId,
          'device_name': Platform.localHostname,
          'device_kind': _deviceKind.name,
        })}\n');
    await socket.flush();
  }

  Future<String> _stableDeviceId() async {
    final preferences = await SharedPreferences.getInstance();
    const key = 'omnidrop_device_id';
    final saved = preferences.getString(key);
    if (saved != null) return saved;
    final id = List<int>.generate(16, (_) => Random.secure().nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    await preferences.setString(key, id);
    return id;
  }

  Future<PairingSession> requestPairing(Peer peer) async {
    final address = peer.address;
    final port = peer.port;
    final localDeviceId = _localDeviceId;
    if (address == null || port == null || localDeviceId == null) {
      throw const SocketException('This device is no longer reachable.');
    }
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final socket = await Socket.connect(address, port,
        timeout: const Duration(seconds: 5));
    final lines = StreamIterator<String>(
        utf8.decoder.bind(socket).transform(const LineSplitter()));
    socket.write('${jsonEncode({
          'type': 'pair_request',
          'device_id': localDeviceId,
          'device_name': Platform.localHostname,
          'public_key': base64Encode(publicKey.bytes)
        })}\n');
    await socket.flush();
    try {
      if (!await lines.moveNext().timeout(const Duration(seconds: 10)))
        throw const FormatException('Pairing challenge was not received.');
      final challenge = jsonDecode(lines.current) as Map<String, dynamic>;
      if (challenge['type'] != 'pair_challenge' ||
          challenge['public_key'] is! String ||
          challenge['code'] is! String) {
        throw const FormatException('Invalid pairing challenge.');
      }
      final remoteKey = SimplePublicKey(
          base64Decode(challenge['public_key'] as String),
          type: KeyPairType.x25519);
      final secret = await algorithm.sharedSecretKey(
          keyPair: keyPair, remotePublicKey: remoteKey);
      final secretBytes = await secret.extractBytes();
      final code = await _verificationCode(secretBytes);
      if (challenge['code'] != code)
        throw const FormatException(
            'The pairing verification code did not match.');
      return PairingSession(
        code: code,
        confirm: (approved) async {
          socket.write('${jsonEncode({
                'type': 'pair_confirm',
                'approved': approved
              })}\n');
          await socket.flush();
          if (!approved) return false;
          if (!await lines.moveNext().timeout(const Duration(seconds: 90)))
            return false;
          final result = jsonDecode(lines.current) as Map<String, dynamic>;
          final accepted = result['accepted'] == true;
          if (accepted) {
            await _keyStore.write(_keyFor(peer.id), base64Encode(secretBytes));
            await _rememberTrusted(peer.id, peer.name);
          }
          return accepted;
        },
        close: () async {
          await lines.cancel();
          socket.destroy();
        },
      );
    } on Object {
      await lines.cancel();
      socket.destroy();
      rethrow;
    }
  }

  Future<void> sendTrustedFiles(Peer peer, List<File> files,
      {required String transferId,
      bool chatAttachment = false,
      void Function(String fileName, int sent, int total)? onProgress}) async {
    if (!peer.trusted)
      throw StateError('Pair this device before sending files.');
    final address = peer.address;
    final port = peer.port;
    final localDeviceId = _localDeviceId;
    if (address == null || port == null || localDeviceId == null) {
      throw const SocketException('This device is no longer reachable.');
    }
    final preferences = await SharedPreferences.getInstance();
    final trusted = preferences.getStringList('omnidrop_trusted_devices') ??
        const <String>[];
    if (!trusted.contains(peer.id))
      throw StateError(
          'This device is no longer trusted. Pair again to continue.');
    final encoded = await _keyStore.read(_keyFor(peer.id));
    if (encoded == null)
      throw StateError(
          'The secure pairing key is missing. Pair this device again.');
    if (_cancelledTransferIds.contains(transferId)) {
      _cancelledTransferIds.remove(transferId);
      throw const SocketException('Transfer cancelled.');
    }
    late final Socket socket;
    try {
      socket = await Socket.connect(address, port,
          timeout: const Duration(seconds: 8));
    } catch (_) {
      _cancelledTransferIds.remove(transferId);
      rethrow;
    }
    if (_cancelledTransferIds.contains(transferId)) {
      _cancelledTransferIds.remove(transferId);
      socket.destroy();
      throw const SocketException('Transfer cancelled.');
    }
    _outgoingTransferSockets[transferId] = socket;
    try {
      await TrustedTransferProtocol.send(
        socket: socket,
        localDeviceId: localDeviceId,
        localName: Platform.localHostname,
        transferId: transferId,
        secret: base64Decode(encoded),
        files: files,
        isCancelled: () => _cancelledTransferIds.contains(transferId),
        isPaused: () => _pausedTransferIds.contains(transferId),
        chatAttachment: chatAttachment,
        onProgress: onProgress,
      ).timeout(const Duration(hours: 2));
    } finally {
      _outgoingTransferSockets.remove(transferId);
      _cancelledTransferIds.remove(transferId);
      _pausedTransferIds.remove(transferId);
      socket.destroy();
    }
  }

  void cancelTransfer(String transferId) {
    _cancelledTransferIds.add(transferId);
    _outgoingTransferSockets.remove(transferId)?.destroy();
    final incoming = _incomingTransferSockets.remove(transferId);
    if (incoming != null) {
      incoming.write('${jsonEncode({
            'type': 'transfer_cancelled',
            'message': 'The receiving device cancelled this transfer.',
          })}\n');
      unawaited(
          incoming.flush().catchError((_) {}).whenComplete(incoming.destroy));
    }
  }

  void pauseTransfer(String transferId) {
    _pausedTransferIds.add(transferId);
  }

  Future<void> sendChatMessage(Peer peer, String text,
      {bool clipboard = false}) async {
    if (!peer.trusted) throw StateError('Pair this device before chatting.');
    final address = peer.address;
    final port = peer.port;
    final localDeviceId = _localDeviceId;
    if (address == null || port == null || localDeviceId == null) {
      throw const SocketException('This device is no longer connected.');
    }
    final preferences = await SharedPreferences.getInstance();
    final trusted = preferences.getStringList('omnidrop_trusted_devices') ??
        const <String>[];
    if (!trusted.contains(peer.id))
      throw StateError(
          'This device is no longer trusted. Pair again to continue.');
    final encoded = await _keyStore.read(_keyFor(peer.id));
    if (encoded == null)
      throw StateError(
          'The secure pairing key is missing. Pair this device again.');
    final socket = await Socket.connect(address, port,
        timeout: const Duration(seconds: 8));
    try {
      await TrustedChatProtocol.send(
        socket: socket,
        deviceId: localDeviceId,
        deviceName: Platform.localHostname,
        secret: base64Decode(encoded),
        text: text,
        clipboard: clipboard,
      ).timeout(const Duration(seconds: 45));
    } finally {
      socket.destroy();
    }
  }

  Future<void> respondToTransfer(IncomingTransferOffer offer,
      {required bool accept}) async {
    if (!offer.decision.isCompleted) offer.decision.complete(accept);
  }

  Future<void> respondToPairing(String requestId,
      {required bool accept}) async {
    final request = _pendingPairings.remove(requestId);
    if (request == null) return;
    request.complete(accept);
    if (accept) {
      await _keyStore.write(
          _keyFor(request.deviceId), base64Encode(request.sharedSecret));
      await _rememberTrusted(request.deviceId, request.deviceName);
    }
  }

  Future<void> _rememberTrusted(String deviceId, String deviceName) async {
    final preferences = await SharedPreferences.getInstance();
    final trusted =
        preferences.getStringList('omnidrop_trusted_devices') ?? <String>[];
    if (!trusted.contains(deviceId)) {
      trusted.add(deviceId);
      await preferences.setStringList('omnidrop_trusted_devices', trusted);
    }
    await preferences.setString(
        'omnidrop_trusted_device_name_$deviceId', deviceName);
    for (final entry in _peersByService.entries.toList()) {
      if (entry.value.id == deviceId) {
        final peer = entry.value;
        _peersByService[entry.key] = Peer(
            id: peer.id,
            name: peer.name,
            kind: peer.kind,
            rssi: peer.rssi,
            address: peer.address,
            port: peer.port,
            trusted: true,
            isDirect: peer.isDirect);
      }
    }
    final directPeer = _directPeersById[deviceId];
    if (directPeer != null) {
      _directPeersById[deviceId] = Peer(
          id: directPeer.id,
          name: directPeer.name,
          kind: directPeer.kind,
          address: directPeer.address,
          port: directPeer.port,
          trusted: true,
          isDirect: true);
    }
    _publish();
  }

  Future<void> forgetTrustedDevice(String deviceId) async {
    final preferences = await SharedPreferences.getInstance();
    final trusted =
        preferences.getStringList('omnidrop_trusted_devices') ?? <String>[];
    trusted.remove(deviceId);
    await preferences.setStringList('omnidrop_trusted_devices', trusted);
    await preferences.remove('omnidrop_trusted_device_name_$deviceId');
    await _keyStore.delete(_keyFor(deviceId));
    for (final entry in _peersByService.entries.toList()) {
      final peer = entry.value;
      if (peer.id == deviceId) {
        _peersByService[entry.key] = Peer(
          id: peer.id,
          name: peer.name,
          kind: peer.kind,
          rssi: peer.rssi,
          address: peer.address,
          port: peer.port,
          trusted: false,
          isDirect: peer.isDirect,
        );
      }
    }
    final directPeer = _directPeersById[deviceId];
    if (directPeer != null) {
      _directPeersById[deviceId] = Peer(
        id: directPeer.id,
        name: directPeer.name,
        kind: directPeer.kind,
        address: directPeer.address,
        port: directPeer.port,
        trusted: false,
        isDirect: true,
      );
    }
    _publish();
  }

  Future<void> _handleSocket(Socket socket) async {
    final reader = TransferSocketReader(socket);
    var isTransfer = false;
    var isChat = false;
    String? activeTransferId;
    IncomingTransferProgress? latestProgress;
    try {
      final payload =
          await reader.readJsonLine().timeout(const Duration(seconds: 10));
      if (payload['type'] == 'direct_identity_request') {
        final deviceId = payload['device_id'];
        final deviceName = payload['device_name'];
        if (deviceId is String &&
            RegExp(r'^[a-f0-9]{32}$').hasMatch(deviceId) &&
            deviceName is String &&
            deviceName.length <= 64) {
          final preferences = await SharedPreferences.getInstance();
          final directPeer = Peer(
            id: deviceId,
            name: deviceName,
            kind: _deviceKindForName(payload['device_kind']),
            address: socket.remoteAddress.address,
            port: omniDropDirectPort,
            trusted: preferences
                    .getStringList('omnidrop_trusted_devices')
                    ?.contains(deviceId) ??
                false,
            isDirect: true,
          );
          _directPeersById[deviceId] = directPeer;
          _publish();
          socket.write('${jsonEncode({
                'type': 'direct_identity',
                'device_id': _localDeviceId,
                'device_name': Platform.localHostname,
                'device_kind': _deviceKind.name,
              })}\n');
          await socket.flush();
        }
      } else if (payload['type'] == 'pair_request') {
        await _handlePairingPayload(socket, reader, payload);
      } else if (payload['type'] == 'transfer_request') {
        isTransfer = true;
        final transferId =
            '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
        activeTransferId = transferId;
        _incomingTransferSockets[transferId] = socket;
        await TrustedTransferProtocol.serve(
          socket: socket,
          reader: reader,
          request: payload,
          secretFor: (deviceId) async {
            final preferences = await SharedPreferences.getInstance();
            final trusted =
                preferences.getStringList('omnidrop_trusted_devices') ??
                    const <String>[];
            if (!trusted.contains(deviceId)) return null;
            final encoded = await _keyStore.read(_keyFor(deviceId));
            return encoded == null ? null : base64Decode(encoded);
          },
          acceptOffer: (offer) async {
            if (_incomingTransfers.isClosed) return false;
            _incomingTransfers.add(offer);
            return offer.decision.future
                .timeout(const Duration(minutes: 2), onTimeout: () => false);
          },
          destination: _receiveDirectory,
          publishFile: await _usesDefaultDownloadFolder() && Platform.isAndroid
              ? (file, name) =>
                  PlatformStorageService().publishReceivedFile(file, name)
              : null,
          publishedFileExists:
              await _usesDefaultDownloadFolder() && Platform.isAndroid
                  ? (path) => PlatformStorageService().publishedFileExists(path)
                  : null,
          onProgress: (file, received, complete) {
            if (!_transferProgress.isClosed) {
              latestProgress = IncomingTransferProgress(
                transferId: transferId,
                deviceId: payload['device_id'] as String? ?? 'unknown',
                deviceName:
                    payload['device_name'] as String? ?? 'Paired device',
                fileName: file.name,
                bytesReceived: received,
                totalBytes: file.size,
                complete: complete,
              );
              _transferProgress.add(latestProgress!);
            }
          },
        ).timeout(const Duration(hours: 2));
      } else if (payload['type'] == 'chat_request') {
        isChat = true;
        await TrustedChatProtocol.serve(
          socket: socket,
          reader: reader,
          request: payload,
          secretFor: (deviceId) async {
            final preferences = await SharedPreferences.getInstance();
            final trusted =
                preferences.getStringList('omnidrop_trusted_devices') ??
                    const <String>[];
            if (!trusted.contains(deviceId)) return null;
            final encoded = await _keyStore.read(_keyFor(deviceId));
            return encoded == null ? null : base64Decode(encoded);
          },
          onMessage: (deviceId, name, text, clipboard) async {
            if (!_chatMessages.isClosed) {
              _chatMessages.add(IncomingChatMessage(
                  deviceId: deviceId,
                  deviceName: name,
                  text: text,
                  clipboard: clipboard));
            }
          },
        ).timeout(const Duration(seconds: 45));
      }
    } catch (_) {
      final cancelledLocally = activeTransferId != null &&
          _cancelledTransferIds.contains(activeTransferId);
      if (isTransfer && latestProgress != null && !_transferProgress.isClosed) {
        final progress = latestProgress!;
        _transferProgress.add(IncomingTransferProgress(
          transferId: progress.transferId,
          deviceId: progress.deviceId,
          deviceName: progress.deviceName,
          fileName: progress.fileName,
          bytesReceived: progress.bytesReceived,
          totalBytes: progress.totalBytes,
          complete: false,
          failed: true,
        ));
      }
      if ((isTransfer && !cancelledLocally) || isChat) {
        try {
          socket.write('${jsonEncode({
                'type': isChat ? 'chat_error' : 'transfer_error',
                'message': isChat
                    ? 'The other device could not receive this message. Check that both apps are open and paired.'
                    : 'The receiving device could not process this transfer. Check that both apps are open and paired.',
              })}\n');
          await socket.flush();
        } catch (_) {
          // The sender may already have disconnected.
        }
      }
    } finally {
      if (activeTransferId != null) {
        _incomingTransferSockets.remove(activeTransferId);
        _cancelledTransferIds.remove(activeTransferId);
      }
      await reader.close();
      socket.destroy();
    }
  }

  Future<Directory> _receiveDirectory() async {
    final preferences = await SharedPreferences.getInstance();
    final configured = preferences.getString('omnidrop_download_path');
    if (configured != null &&
        configured.trim().isNotEmpty &&
        configured != 'Choose a destination') {
      if (Platform.isAndroid) {
        final defaultPath =
            (await PlatformStorageService().defaultDownloadFolder()).path;
        if (configured == defaultPath)
          return getApplicationDocumentsDirectory();
      }
      return Directory(configured);
    }
    if (Platform.isAndroid) return getApplicationDocumentsDirectory();
    return PlatformStorageService().defaultDownloadFolder();
  }

  Future<bool> _usesDefaultDownloadFolder() async {
    final preferences = await SharedPreferences.getInstance();
    final configured = preferences.getString('omnidrop_download_path');
    if (configured == null) return true;
    return configured ==
        (await PlatformStorageService().defaultDownloadFolder()).path;
  }

  Future<void> _handlePairingPayload(Socket socket, TransferSocketReader reader,
      Map<String, dynamic> payload) async {
    if (payload['type'] != 'pair_request') return;
    final deviceId = payload['device_id'];
    final name = payload['device_name'];
    final encodedKey = payload['public_key'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        name is! String ||
        encodedKey is! String) return;
    final remoteKey =
        SimplePublicKey(base64Decode(encodedKey), type: KeyPairType.x25519);
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final localPublicKey = await keyPair.extractPublicKey();
    final sharedSecret = await (await algorithm.sharedSecretKey(
            keyPair: keyPair, remotePublicKey: remoteKey))
        .extractBytes();
    final code = await _verificationCode(sharedSecret);
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final request = PairingRequest._(
        id: requestId,
        deviceId: deviceId,
        deviceName: name,
        code: code,
        sharedSecret: sharedSecret);
    _pendingPairings[requestId] = request;
    _pairingRequests.add(request);
    socket.write('${jsonEncode({
          'type': 'pair_challenge',
          'public_key': base64Encode(localPublicKey.bytes),
          'code': code
        })}\n');
    await socket.flush();
    final confirmation =
        await reader.readJsonLine().timeout(const Duration(seconds: 90));
    final senderApproved = confirmation['type'] == 'pair_confirm' &&
        confirmation['approved'] == true;
    final receiverApproved = senderApproved
        ? await request.decision.future
            .timeout(const Duration(seconds: 90), onTimeout: () => false)
        : false;
    final accepted = senderApproved && receiverApproved;
    _pendingPairings.remove(requestId);
    socket.write('${jsonEncode({'accepted': accepted})}\n');
    await socket.flush();
    request.finish(accepted);
    if (!request.decision.isCompleted) request.complete(false);
  }

  String _keyFor(String deviceId) => 'omnidrop_pairing_$deviceId';

  Future<String> _verificationCode(List<int> sharedSecret) async {
    final digest = (await Sha256().hash(sharedSecret)).bytes;
    final number = ((digest[0] << 16) | (digest[1] << 8) | digest[2]) % 1000000;
    return number.toString().padLeft(6, '0');
  }

  Future<void> stop() async {
    for (final socket in _outgoingTransferSockets.values.toList()) {
      socket.destroy();
    }
    for (final socket in _incomingTransferSockets.values.toList()) {
      socket.destroy();
    }
    _outgoingTransferSockets.clear();
    _incomingTransferSockets.clear();
    _cancelledTransferIds.clear();
    await _subscription?.cancel();
    _subscription = null;
    await _discovery?.stop();
    _discovery = null;
    await _broadcast?.stop();
    _broadcast = null;
    await _presenceSocket?.close();
    _presenceSocket = null;
    _peersByService.clear();
    _directPeersById.clear();
    _publish();
  }

  Future<void> dispose() async {
    await stop();
    await _updates.close();
    await _pairingRequests.close();
    await _incomingTransfers.close();
    await _transferProgress.close();
    await _chatMessages.close();
  }
}

class IncomingChatMessage {
  const IncomingChatMessage(
      {required this.deviceId,
      required this.deviceName,
      required this.text,
      this.clipboard = false});
  final String deviceId;
  final String deviceName;
  final String text;
  final bool clipboard;
}

class PairingRequest {
  PairingRequest._(
      {required this.id,
      required this.deviceId,
      required this.deviceName,
      required this.code,
      required this.sharedSecret});
  final String id;
  final String deviceId;
  final String deviceName;
  final String code;
  final List<int> sharedSecret;
  final Completer<bool> decision = Completer<bool>();
  final Completer<bool> completed = Completer<bool>();

  void complete(bool accepted) {
    if (!decision.isCompleted) decision.complete(accepted);
  }

  void finish(bool paired) {
    if (!completed.isCompleted) completed.complete(paired);
  }
}

class PairingSession {
  const PairingSession(
      {required this.code, required this.confirm, required this.close});
  final String code;
  final Future<bool> Function(bool approved) confirm;
  final Future<void> Function() close;
}
