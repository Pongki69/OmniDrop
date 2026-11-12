import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'trusted_transfer_protocol.dart';

class TrustedChatProtocol {
  static final Hmac _hmac = Hmac.sha256();
  static final AesGcm _aes = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: _hmac, outputLength: 32);

  static Future<void> send({
    required Socket socket,
    required String deviceId,
    required String deviceName,
    required List<int> secret,
    required String text,
    bool clipboard = false,
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty || cleanText.length > 4000) {
      throw const FormatException('Messages must be between 1 and 4,000 characters.');
    }
    final clientNonce = _randomBytes(16);
    final reader = TransferSocketReader(socket);
    try {
      await _writeLine(socket, {
        'type': 'chat_request',
        'device_id': deviceId,
        'device_name': deviceName,
        'nonce': base64Encode(clientNonce),
      });
      final challenge = await reader.readJsonLine().timeout(const Duration(seconds: 20));
      if (challenge['type'] == 'chat_error') {
        throw SocketException(challenge['message'] as String? ?? 'Chat was rejected.');
      }
      if (challenge['type'] != 'chat_challenge' ||
          challenge['nonce'] is! String || challenge['proof'] is! String) {
        throw const FormatException('The paired device sent an invalid chat challenge.');
      }
      final serverNonce = base64Decode(challenge['nonce'] as String);
      final transcript = _transcript(deviceId, clientNonce, serverNonce);
      if (!_constantTimeEquals(
          await _mac(secret, <int>[...utf8.encode('server'), ...transcript]),
          base64Decode(challenge['proof'] as String))) {
        throw const FormatException('The paired device could not be authenticated.');
      }
      await _writeLine(socket, {
        'type': 'chat_auth',
        'proof': base64Encode(await _mac(
            secret, <int>[...utf8.encode('client'), ...transcript])),
      });
      final key = await _sessionKey(secret, clientNonce, serverNonce);
      final box = await _aes.encrypt(utf8.encode(jsonEncode({
        'kind': clipboard ? 'clipboard' : 'text',
        'text': cleanText,
      })),
          secretKey: key, nonce: _nonce(clientNonce), aad: utf8.encode('chat'));
      await _writeLine(socket, {
        'type': 'chat_message',
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      });
      final ack = await reader.readJsonLine().timeout(const Duration(seconds: 20));
      if (ack['type'] != 'chat_ack' || ack['accepted'] != true) {
        throw const SocketException('The paired device did not receive the message.');
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
    required Future<void> Function(String deviceId, String name, String text, bool clipboard) onMessage,
  }) async {
    final deviceId = request['device_id'];
    final name = request['device_name'];
    if (deviceId is! String || deviceId.isEmpty || name is! String ||
        name.length > 64 || request['nonce'] is! String) {
      throw const FormatException('Invalid chat request.');
    }
    final secret = await secretFor(deviceId);
    if (secret == null || secret.length < 32) {
      await _writeLine(socket, {'type': 'chat_error', 'message': 'This device is not paired.'});
      return;
    }
    final clientNonce = base64Decode(request['nonce'] as String);
    if (clientNonce.length != 16) throw const FormatException('Invalid chat nonce.');
    final serverNonce = _randomBytes(16);
    final transcript = _transcript(deviceId, clientNonce, serverNonce);
    await _writeLine(socket, {
      'type': 'chat_challenge',
      'nonce': base64Encode(serverNonce),
      'proof': base64Encode(await _mac(secret, <int>[...utf8.encode('server'), ...transcript])),
    });
    final auth = await reader.readJsonLine().timeout(const Duration(seconds: 20));
    if (auth['type'] != 'chat_auth' || auth['proof'] is! String ||
        !_constantTimeEquals(
            await _mac(secret, <int>[...utf8.encode('client'), ...transcript]),
            base64Decode(auth['proof'] as String))) {
      throw const FormatException('Chat sender authentication failed.');
    }
    final payload = await reader.readJsonLine().timeout(const Duration(seconds: 20));
    if (payload['type'] != 'chat_message' || payload['ciphertext'] is! String || payload['mac'] is! String) {
      throw const FormatException('Invalid chat message.');
    }
    final key = await _sessionKey(secret, clientNonce, serverNonce);
    final clear = await _aes.decrypt(
        SecretBox(base64Decode(payload['ciphertext'] as String), nonce: _nonce(clientNonce), mac: Mac(base64Decode(payload['mac'] as String))),
        secretKey: key,
        aad: utf8.encode('chat'));
    final message = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    final text = message['text'];
    final kind = message['kind'];
    if (text is! String || text.trim().isEmpty || text.length > 4000 ||
        (kind != 'text' && kind != 'clipboard')) {
      throw const FormatException('Invalid chat text.');
    }
    await onMessage(deviceId, name, text.trim(), kind == 'clipboard');
    await _writeLine(socket, {'type': 'chat_ack', 'accepted': true});
  }

  static Future<List<int>> _mac(List<int> secret, List<int> data) async =>
      (await _hmac.calculateMac(data, secretKey: SecretKey(secret))).bytes;

  static Future<SecretKey> _sessionKey(List<int> secret, List<int> client, List<int> server) =>
      _hkdf.deriveKey(secretKey: SecretKey(secret), nonce: [...client, ...server], info: utf8.encode('OmniDrop ephemeral chat v1'));

  static List<int> _transcript(String deviceId, List<int> client, List<int> server) =>
      [...utf8.encode(deviceId), 0, ...client, ...server];

  static List<int> _randomBytes(int length) =>
      List<int>.generate(length, (_) => Random.secure().nextInt(256));

  static List<int> _nonce(List<int> client) => [...client.take(4), 0, 0, 0, 0, 0, 0, 0, 0];

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) { difference |= a[i] ^ b[i]; }
    return difference == 0;
  }
}

Future<void> _writeLine(Socket socket, Map<String, Object?> value) async {
  socket.write('${jsonEncode(value)}\n');
  await socket.flush();
}
