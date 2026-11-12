import 'package:flutter/services.dart';

class PairingKeyStore {
  static const MethodChannel _channel = MethodChannel('com.omnidrop/secure_store');

  Future<void> write(String key, String value) => _channel.invokeMethod<void>('write', {'key': key, 'value': value});

  Future<String?> read(String key) => _channel.invokeMethod<String>('read', {'key': key});

  Future<void> delete(String key) => _channel.invokeMethod<void>('delete', {'key': key});
}
