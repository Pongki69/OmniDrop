enum TransferStatus { queued, connecting, transferring, complete, paused, failed }

class TransferItem {
  const TransferItem({required this.id, required this.name, required this.size, required this.status, this.bytesTransferred = 0, this.bytesPerSecond = 0, this.error});
  final String id;
  final String name;
  final int size;
  final TransferStatus status;
  final int bytesTransferred;
  final int bytesPerSecond;
  final String? error;
  double get progress => size == 0 ? 0 : (bytesTransferred / size).clamp(0, 1);
  Duration? get eta => bytesPerSecond <= 0 || size <= bytesTransferred ? null : Duration(seconds: (size - bytesTransferred) ~/ bytesPerSecond);
}
