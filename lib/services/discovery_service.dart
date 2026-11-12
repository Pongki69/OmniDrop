import 'dart:async';
import '../models/peer.dart';

/// Implement with platform mDNS/Bonjour and BLE plugins to provide real peers.
abstract interface class DiscoveryAdapter {
  Stream<Peer> discover();
  Future<void> advertise(Peer localPeer);
  Future<void> stop();
}

class DiscoveryService {
  DiscoveryService(this._adapter);
  final DiscoveryAdapter _adapter;
  final Map<String, Peer> _peers = {};
  StreamSubscription<Peer>? _subscription;
  final StreamController<List<Peer>> _updates = StreamController.broadcast();
  Stream<List<Peer>> get peers => _updates.stream;

  Future<void> start(Peer localPeer) async {
    await stop();
    await _adapter.advertise(localPeer);
    _subscription = _adapter.discover().listen((peer) {
      _peers[peer.id] = peer;
      final sorted = _peers.values.toList()..sort((a, b) => (b.rssi ?? -127).compareTo(a.rssi ?? -127));
      _updates.add(List.unmodifiable(sorted));
    });
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _peers.clear();
    await _adapter.stop();
    if (!_updates.isClosed) _updates.add(const []);
  }

  Future<void> dispose() async { await stop(); await _updates.close(); }
}
