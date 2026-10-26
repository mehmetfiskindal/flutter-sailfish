import 'dart:io';

import 'package:dbus/dbus.dart';

// One long-lived client per bus, the way a plugin would hold it. Opening and closing a
// connection for every call made the Sailjail D-Bus proxy refuse later connections.
DBusClient? _session;
DBusClient? _system;
DBusClient get _sessionBus => _session ??= DBusClient.session();
DBusClient get _systemBus => _system ??= DBusClient.system();

int _runs = 0;

/// Tries a few things an app inside Sailjail would need for D-Bus based plugins and
/// reports each result, so a failure shows exactly which step is blocked.
Future<List<String>> runDbusProbe() async {
  final out = <String>['run ${++_runs} (shared connections)'];

  Future<void> step(String label, Future<String> Function() body) async {
    final started = DateTime.now();
    try {
      final result = await body().timeout(const Duration(seconds: 5));
      out.add('$label: $result');
    } catch (e) {
      final ms = DateTime.now().difference(started).inMilliseconds;
      out.add('$label: FAILED after ${ms}ms $e');
    }
  }

  Future<String> mce(String method) async {
    final response = await _systemBus.callMethod(
      destination: 'com.nokia.mce',
      path: DBusObjectPath('/com/nokia/mce/request'),
      interface: 'com.nokia.mce.request',
      name: method,
    );
    return response.values.first.toNative().toString();
  }

  await step('file /sys battery', () async {
    final text = await File('/sys/class/power_supply/battery/capacity').readAsString();
    return '${text.trim()}%';
  });
  await step('session bus', () async => '${(await _sessionBus.listNames()).length} names');
  await step('system bus', () async => '${(await _systemBus.listNames()).length} names');
  await step('mce get_charger_state', () => mce('get_charger_state'));
  await step('mce get_battery_level', () => mce('get_battery_level'));
  await step('mce get_charging_state', () => mce('get_charging_state'));
  await step('mce methods', () async {
    final response = await _systemBus.callMethod(
      destination: 'com.nokia.mce',
      path: DBusObjectPath('/com/nokia/mce/request'),
      interface: 'org.freedesktop.DBus.Introspectable',
      name: 'Introspect',
    );
    final xml = (response.values.first as DBusString).value;
    final names = RegExp(r'<method name="([^"]+)"').allMatches(xml).map((m) => m.group(1)).toList();
    return '${names.length} methods';
  });
  await step('mce get_battery_status', () => mce('get_battery_status'));
  return out;
}
