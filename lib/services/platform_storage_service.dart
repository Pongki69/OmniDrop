import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _nativeChannel = MethodChannel('com.omnidrop/direct_radio');

class PlatformStorageService {
  Future<Directory> defaultDownloadFolder() async {
    if (Platform.isAndroid || Platform.isWindows) {
      try {
        final path = await _nativeChannel.invokeMethod<String>('getDefaultDownloadFolder');
        if (path != null && path.isNotEmpty) return Directory(path);
      } on MissingPluginException {
        // Use the platform-safe app folder if the native bridge is unavailable.
      } on PlatformException {
        // Fall through to a writable application folder.
      }
    }
    final downloads = await getDownloadsDirectory();
    final folder = Directory('${(downloads ?? await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}OmniDrop');
    await folder.create(recursive: true);
    return folder;
  }

  Future<String> publishReceivedFile(File source, String fileName) async {
    if (!Platform.isAndroid) return source.path;
    return await _nativeChannel.invokeMethod<String>('publishReceivedFile', {
          'sourcePath': source.path,
          'fileName': fileName,
        }) ?? source.path;
  }

  Future<bool> publishedFileExists(String path) async {
    if (!Platform.isAndroid || !path.startsWith('content://')) {
      return File(path).exists();
    }
    return await _nativeChannel.invokeMethod<bool>('publishedFileExists', {'uri': path}) ?? false;
  }
}
