import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

const _directRadioChannel = MethodChannel('com.omnidrop/direct_radio');

enum RadioSupport { supported, unsupported, unavailable, unknown }

class RadioCapability {
  const RadioCapability({required this.name, required this.support, required this.message});
  final String name;
  final RadioSupport support;
  final String message;

  factory RadioCapability.fromMap(Map<Object?, Object?> map) => RadioCapability(
        name: map['name'] as String? ?? 'Radio',
        support: switch (map['support']) {
          'supported' => RadioSupport.supported,
          'unsupported' => RadioSupport.unsupported,
          'unavailable' => RadioSupport.unavailable,
          _ => RadioSupport.unknown,
        },
        message: map['message'] as String? ?? 'Capability could not be checked.',
      );
}

class DirectRadioService {
  Future<List<DirectDevice>> discoverWindowsDirectDevices() async {
    try {
      final response = await _directRadioChannel
          .invokeListMethod<Object?>('discoverDirectDevices')
          .timeout(const Duration(seconds: 16));
      return (response ?? const <Object?>[]).whereType<Map<Object?, Object?>>().map((item) => DirectDevice(
        id: item['id'] as String? ?? '', name: item['name'] as String? ?? 'Wi-Fi Direct device')).where((item) => item.id.isNotEmpty).toList(growable: false);
    } on PlatformException catch (error) {
      throw StateError(error.message ?? 'Windows could not search for Wi-Fi Direct devices.');
    }
  }

  Future<String> connectWindowsDirectDevice(String deviceId) async {
    try {
      final address = await _directRadioChannel.invokeMethod<String>('connectDirectDevice', {'id': deviceId});
      if (address == null || address.isEmpty) throw StateError('Windows did not return a direct connection address.');
      return address;
    } on PlatformException catch (error) {
      throw StateError(error.message ?? 'Windows could not connect to this direct device.');
    }
  }

  Future<void> stopWindowsDirectDevice() => _directRadioChannel.invokeMethod<void>('stopDirectDevice');

  Future<Map<String, Object?>> startAndroidDirectGroup() async {
    try {
      final result = await _directRadioChannel
          .invokeMapMethod<Object?, Object?>('startDirectGroup')
          .timeout(const Duration(seconds: 20));
      return Map<String, Object?>.from(result ?? const {});
    } on MissingPluginException {
      return {'ok': false, 'reason': 'Wi-Fi Direct setup is unavailable in this app build.'};
    } on PlatformException catch (error) {
      return {'ok': false, 'reason': error.message ?? 'Could not start Wi-Fi Direct.'};
    }
  }

  Future<void> stopAndroidDirectGroup() async {
    await _directRadioChannel
        .invokeMethod<void>('stopDirectGroup')
        .timeout(const Duration(seconds: 10));
  }

  Future<String> currentNetworkBand() async {
    try {
      final band = await _directRadioChannel.invokeMethod<String>('getNetworkBand');
      return band == null || band == 'unknown' ? 'Could not detect' : band;
    } on MissingPluginException {
      return 'Could not detect';
    } on PlatformException {
      return 'Could not detect';
    }
  }

  Future<List<RadioCapability>> inspect() async {
    try {
      final response = await _directRadioChannel.invokeListMethod<Object?>('getCapabilities');
      return (response ?? const <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map(RadioCapability.fromMap)
          .toList(growable: false);
    } on MissingPluginException {
      return [
        RadioCapability(
          name: Platform.isWindows ? 'Windows Wi-Fi Direct' : 'Direct radio support',
          support: RadioSupport.unknown,
          message: 'This platform build does not have its direct-radio bridge yet.',
        ),
      ];
    } on PlatformException catch (error) {
      return [RadioCapability(name: 'Direct radio support', support: RadioSupport.unavailable, message: error.message ?? 'The operating system could not inspect this device.')];
    }
  }
}

class DirectDevice {
  const DirectDevice({required this.id, required this.name});
  final String id;
  final String name;
}
