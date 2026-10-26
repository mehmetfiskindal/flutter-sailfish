import 'dart:async';
import 'dart:typed_data';

import 'package:echo_plugin/echo_plugin.dart';
import 'package:flutter/services.dart';

const _channel = EchoPlugin.channel;

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

  // Event channel: the native side sends from its own thread.
  await step('events 5 ticks', () async {
    final values = await EchoPlugin.ticks(count: 5, intervalMs: 20).toList();
    return '${values.toString() == '[1, 2, 3, 4, 5]' ? 'OK' : 'MISMATCH'} $values, stream ended';
  });
  await step('events error event', () async {
    final done = Completer<void>();
    final values = <Object?>[];
    final errors = <String>[];
    EchoPlugin.ticks(count: 5, intervalMs: 20, failAt: 3).listen(
      values.add,
      onError: (Object e) {
        if (e is PlatformException) errors.add('${e.code}/${e.details}');
      },
      onDone: done.complete,
    );
    await done.future;
    final ok = values.toString() == '[1, 2, 4, 5]' && errors.length == 1 && errors.first == 'tick_failed/3';
    return '${ok ? 'OK' : 'MISMATCH'} values=$values errors=$errors';
  });
  await step('events cancel', () async {
    final before = await EchoPlugin.streamStats();
    final first = await EchoPlugin.ticks(count: 1000, intervalMs: 10).take(3).toList();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final after = await EchoPlugin.streamStats();
    final cancelled = (after?['cancelled'] as int) - (before?['cancelled'] as int);
    final completed = (after?['completed'] as int) - (before?['completed'] as int);
    final ok = first.toString() == '[1, 2, 3]' && cancelled == 1 && completed == 0;
    return '${ok ? 'OK' : 'MISMATCH'} got $first, native cancelled +$cancelled, completed +$completed';
  });
  await step('events listen again', () async {
    final values = await EchoPlugin.ticks(count: 3, intervalMs: 10).toList();
    return '${values.toString() == '[1, 2, 3]' ? 'OK' : 'MISMATCH'} $values';
  });
  await step('events 300 fast', () async {
    final watch = Stopwatch()..start();
    final values = await EchoPlugin.ticks(count: 300, intervalMs: 1).toList();
    var inOrder = values.length == 300;
    for (var i = 0; inOrder && i < values.length; i++) {
      inOrder = values[i] == i + 1;
    }
    return '${inOrder ? 'OK' : 'MISMATCH'} ${values.length} events in order, ${watch.elapsedMilliseconds} ms';
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
