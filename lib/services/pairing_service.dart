import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

/// Ed25519 primitives. Persist private keys with OS-backed secure storage.
class PairingService {
  final Ed25519 _algorithm = Ed25519();
  Future<SimpleKeyPair> createIdentity() => _algorithm.newKeyPair();
  Future<List<int>> exportPublicKey(SimpleKeyPair keyPair) async => (await keyPair.extractPublicKey()).bytes;
  Future<List<int>> sign(SimpleKeyPair keyPair, List<int> message) async => (await _algorithm.sign(message, keyPair: keyPair)).bytes;
  Future<bool> verify({required List<int> publicKey, required List<int> message, required List<int> signature}) async {
    try {
      return await _algorithm.verify(message, signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
    } on ArgumentError { return false; }
  }
  String makePairingPin() => Random.secure().nextInt(1000000).toString().padLeft(6, '0');
  String fingerprint(List<int> publicKey) => base64UrlEncode(publicKey).replaceAll('=', '');
}

class TrustedPeerStore {
  final Map<String, List<int>> _keys = {};
  bool isTrusted(String fingerprint) => _keys.containsKey(fingerprint);
  List<int>? keyFor(String fingerprint) => _keys[fingerprint];
  void trust(String fingerprint, List<int> publicKey) => _keys[fingerprint] = List.unmodifiable(publicKey);
  void forget(String fingerprint) => _keys.remove(fingerprint);
}
