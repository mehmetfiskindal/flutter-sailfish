import 'package:flutter/services.dart';

/// Dart API of the example plugin; the work is done by the native part in `sailfish/`.
class EchoPlugin {
  EchoPlugin._();

  /// The channel the native part answers on.
  static const MethodChannel channel = MethodChannel('flutter_sailfish/echo');

  /// The event channel the native part streams on.
  static const EventChannel events = EventChannel('flutter_sailfish/echo_events');

  /// Returns [value] after a round trip through the native standard method codec.
  static Future<Object?> echo([Object? value]) => channel.invokeMethod<Object?>('echo', value);

  /// System name, machine and C++ standard of the native part.
  static Future<Map<String, Object?>?> info() => channel.invokeMapMethod<String, Object?>('info');

  /// Always fails with a [PlatformException] (code `demo_error`, details 42).
  static Future<void> fail() => channel.invokeMethod<void>('fail');

  /// A stream of the integers 1..[count] sent from a native thread, one every [intervalMs]
  /// milliseconds. With [failAt] set, that number is sent as an error event instead.
  static Stream<Object?> ticks({int count = 5, int intervalMs = 100, int failAt = 0}) =>
      events.receiveBroadcastStream({'count': count, 'intervalMs': intervalMs, 'failAt': failAt});

  /// How many streams Dart cancelled and how many the native side ran to the end.
  static Future<Map<String, Object?>?> streamStats() =>
      channel.invokeMapMethod<String, Object?>('streamStats');
}
