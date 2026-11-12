import 'package:flutter/material.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'ui/omnidrop_app.dart';

void main() {
  FlutterCryptography.enable();
  runApp(const OmniDropApp());
}
