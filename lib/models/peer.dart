enum DeviceKind { desktop, phone, tablet, browser }

class Peer {
  const Peer({required this.id, required this.name, required this.kind, this.rssi, this.address, this.port, this.trusted = false, this.isDirect = false});
  final String id;
  final String name;
  final DeviceKind kind;
  final int? rssi;
  final String? address;
  final int? port;
  final bool trusted;
  final bool isDirect;
}
