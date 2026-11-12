import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Temporary, token-protected LAN file server with an automatic expiry.
class BrowserShareService {
  HttpServer? _server;
  String? _token;
  String? _lanHost;
  Timer? _expiry;
  Uri? get url => _server == null || _lanHost == null
      ? null
      : Uri(scheme: 'http', host: _lanHost!, port: _server!.port, path: 'drop', queryParameters: {'token': _token});

  Future<Uri> start(List<File> files, {Duration lifetime = const Duration(minutes: 10)}) async {
    await stop();
    _token = base64UrlEncode(List<int>.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    _lanHost = await _findLanHost();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: false);
    _server!.listen((request) async {
      if (request.uri.path != '/drop' || request.uri.queryParameters['token'] != _token) {
        request.response.statusCode = HttpStatus.notFound;
      } else if (request.method == 'GET' && request.uri.queryParameters.containsKey('file')) {
        final index = int.tryParse(request.uri.queryParameters['file'] ?? '');
        if (index == null || index < 0 || index >= files.length) {
          request.response.statusCode = HttpStatus.badRequest;
        } else {
          final file = files[index];
          request.response.headers.set('content-disposition', 'attachment; filename="${_escape(file.uri.pathSegments.last)}"');
          await request.response.addStream(file.openRead());
        }
      } else if (request.method == 'GET') {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<!doctype html><meta name="viewport" content="width=device-width"><title>OmniDrop</title><h1>Shared files</h1><ul>');
        for (var i = 0; i < files.length; i++) {
          request.response.write('<li><a href="?token=$_token&file=$i">${_escape(files[i].uri.pathSegments.last)}</a></li>');
        }
        request.response.write('</ul>');
      } else {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      }
      await request.response.close();
    });
    _expiry = Timer(lifetime, () => unawaited(stop()));
    return url!;
  }

  String _escape(String value) => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');

  Future<String> _findLanHost() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    final addresses = interfaces.expand((interface) => interface.addresses)
        .where((address) => !address.isLoopback && !address.isLinkLocal)
        .toList();
    bool isPrivateIpv4(InternetAddress address) {
      final bytes = address.rawAddress;
      return bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168);
    }
    final privateAddresses = addresses.where(isPrivateIpv4).toList();
    if (privateAddresses.isNotEmpty) return privateAddresses.first.address;
    if (addresses.isNotEmpty) return addresses.first.address;
    throw const SocketException('No local IPv4 address is available for browser sharing');
  }

  Future<void> stop() async {
    _expiry?.cancel();
    _expiry = null;
    await _server?.close(force: true);
    _server = null;
    _token = null;
    _lanHost = null;
  }
}
