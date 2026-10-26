import 'package:flutter/services.dart';

/// Dart API of the example plugin; the work is done by the native part in `sailfish/`.
class EchoPlugin {
  EchoPlugin._();

  /// The channel the native part answers on.
  static const MethodChannel channel = MethodChannel('flutter_sailfish/echo');

  /// Returns [value] after a round trip through the native standard method codec.
  static Future<Object?> echo([Object? value]) => channel.invokeMethod<Object?>('echo', value);

  /// System name, machine and C++ standard of the native part.
  static Future<Map<String, Object?>?> info() => channel.invokeMapMethod<String, Object?>('info');

  /// Always fails with a [PlatformException] (code `demo_error`, details 42).
  static Future<void> fail() => channel.invokeMethod<void>('fail');
}
