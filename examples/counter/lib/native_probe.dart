import 'dart:typed_data';

import 'package:flutter/services.dart';

const _channel = MethodChannel('flutter_sailfish/echo');

/// Exercises the native echo plugin (examples/echo_plugin): every standard codec type must
/// survive the round trip through the C++ plugin, and errors must map to the right exceptions.
Future<List<String>> runNativeProbe() async {
  final out = <String>[];

  Future<void> step(String label, Future<String> Function() body) async {
    try {
      out.add('$label: ${await body().timeout(const Duration(seconds: 5))}');
    } catch (e) {
      out.add('$label: FAILED $e');
    }
  }

  final sample = <Object?, Object?>{
    'null': null,
    'bool': true,
    'int': 42,
    'negative': -7,
    'bigInt': 1 << 40,
    'double': 3.5,
    'string': 'héllo ✓ 日本語',
    'bytes': Uint8List.fromList([1, 2, 3, 255]),
    'int32s': Int32List.fromList([1, -2, 3]),
    'int64s': Int64List.fromList([1 << 40, -5]),
    'doubles': Float64List.fromList([1.5, -2.25]),
    'list': [1, 'two', 3.0, null, [4]],
    'map': {
      'nested': {'a': 1, 'b': [true, false]},
      5: 'int key',
    },
  };

  await step('echo all types', () async {
    final reply = await _channel.invokeMethod<Object?>('echo', sample);
    final difference = _difference(sample, reply, 'value');
    return difference == null ? 'OK' : 'MISMATCH $difference';
  });
  await step('echo 200k string', () async {
    final text = 'x' * 200000;
    final reply = await _channel.invokeMethod<Object?>('echo', text);
    return reply == text ? 'OK' : 'MISMATCH (${(reply as String?)?.length} chars)';
  });
  await step('echo no argument', () async {
    final reply = await _channel.invokeMethod<Object?>('echo');
    return reply == null ? 'OK (null)' : 'MISMATCH $reply';
  });
  await step('info', () async {
    final info = await _channel.invokeMapMethod<String, Object?>('info');
    return '$info';
  });
  await step('error result', () async {
    try {
      await _channel.invokeMethod<Object?>('fail');
      return 'MISMATCH no exception';
    } on PlatformException catch (e) {
      final ok = e.code == 'demo_error' && e.details == 42;
      return '${ok ? 'OK' : 'MISMATCH'} code=${e.code} message="${e.message}" details=${e.details}';
    }
  });
  await step('unknown method', () async {
    try {
      await _channel.invokeMethod<Object?>('nope');
      return 'MISMATCH no exception';
    } on MissingPluginException {
      return 'OK (MissingPluginException)';
    }
  });
  return out;
}

/// Returns a description of the first difference between [a] and [b], or null if equal.
String? _difference(Object? a, Object? b, String path) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return '$path: map size ${a.length} vs ${b.length}';
    for (final key in a.keys) {
      if (!b.containsKey(key)) return '$path: missing key $key';
      final d = _difference(a[key], b[key], '$path[$key]');
      if (d != null) return d;
    }
    return null;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return '$path: length ${a.length} vs ${b.length}';
    for (var i = 0; i < a.length; i++) {
      final d = _difference(a[i], b[i], '$path[$i]');
      if (d != null) return d;
    }
    return null;
  }
  return a == b ? null : '$path: $a (${a.runtimeType}) vs $b (${b.runtimeType})';
}
