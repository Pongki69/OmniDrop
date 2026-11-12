import 'dart:io';

abstract interface class DiskSpaceProvider {
  Future<int> availableBytes(Directory directory);
}

class IncomingTransferDecision {
  const IncomingTransferDecision({required this.accepted, required this.destination, this.reason});
  final bool accepted;
  final File? destination;
  final String? reason;
}

/// Trust bypass still performs identity, path, and capacity checks before any
/// bytes are written. A native disk-space provider is required per platform.
class IncomingTransferService {
  IncomingTransferService(this.diskSpace);
  final DiskSpaceProvider diskSpace;

  Future<IncomingTransferDecision> decide({
    required String relativePath,
    required int fileSize,
    required Directory destination,
    required bool trustedSignatureValid,
    required bool userAccepted,
  }) async {
    if (!trustedSignatureValid && !userAccepted) {
      return const IncomingTransferDecision(accepted: false, destination: null, reason: 'Sender is not trusted');
    }
    if (fileSize < 0) return const IncomingTransferDecision(accepted: false, destination: null, reason: 'Invalid file size');
    final safePath = _validatePath(relativePath);
    final available = await diskSpace.availableBytes(destination);
    if (available < fileSize) return const IncomingTransferDecision(accepted: false, destination: null, reason: 'Not enough free disk space');
    final target = File('${destination.path}${Platform.pathSeparator}$safePath');
    await target.parent.create(recursive: true);
    return IncomingTransferDecision(accepted: true, destination: target);
  }

  String _validatePath(String value) {
    if (value.isEmpty || value.startsWith('/') || value.startsWith('\\') || RegExp(r'^[a-zA-Z]:').hasMatch(value)) {
      throw const FormatException('Expected a relative path');
    }
    final parts = value.replaceAll('\\', '/').split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..' || part.contains(':'))) {
      throw const FormatException('Unsafe path component');
    }
    return parts.join(Platform.pathSeparator);
  }
}
