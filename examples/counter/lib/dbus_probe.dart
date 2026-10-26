import 'dart:io';

import 'package:dbus/dbus.dart';

/// Tries a few things an app inside Sailjail would need for D-Bus based plugins and
/// reports each result, so a failure shows exactly which step is blocked.
Future<List<String>> runDbusProbe() async {
  final out = <String>[];

  Future<void> step(String label, Future<String> Function() body) async {
    try {
      out.add('$label: ${await body().timeout(const Duration(seconds: 5))}');
    } catch (e) {
      out.add('$label: FAILED $e');
    }
  }

  Future<String> listNames(DBusClient client) async {
    try {
      final names = await client.listNames();
      return '${names.length} names';
    } finally {
      await client.close();
    }
  }

  Future<DBusValue> mce(String method) async {
    final client = DBusClient.system();
    try {
      final response = await client.callMethod(
        destination: 'com.nokia.mce',
        path: DBusObjectPath('/com/nokia/mce/request'),
        interface: 'com.nokia.mce.request',
        name: method,
      );
      return response.values.first;
    } finally {
      await client.close();
    }
  }

  await step('file /sys battery', () async {
    final text = await File('/sys/class/power_supply/battery/capacity').readAsString();
    return '${text.trim()}%';
  });
  await step('session bus', () => listNames(DBusClient.session()));
  await step('system bus', () => listNames(DBusClient.system()));
  await step('mce get_charger_state', () async => (await mce('get_charger_state')).toNative().toString());
  await step('mce get_battery_level', () async => (await mce('get_battery_level')).toNative().toString());
  await step('mce get_battery_status', () async => (await mce('get_battery_status')).toNative().toString());
  await step('upower percentage', () async {
    final client = DBusClient.system();
    try {
      final object = DBusRemoteObject(client,
          name: 'org.freedesktop.UPower',
          path: DBusObjectPath('/org/freedesktop/UPower/devices/DisplayDevice'));
      final value = await object.getProperty('org.freedesktop.UPower.Device', 'Percentage');
      return '${value.toNative()}%';
    } finally {
      await client.close();
    }
  });
  await step('mce methods', () async {
    final client = DBusClient.system();
    try {
      final response = await client.callMethod(
        destination: 'com.nokia.mce',
        path: DBusObjectPath('/com/nokia/mce/request'),
        interface: 'org.freedesktop.DBus.Introspectable',
        name: 'Introspect',
      );
      final xml = (response.values.first as DBusString).value;
      final names = RegExp(r'<method name="([^"]+)"').allMatches(xml).map((m) => m.group(1)).toList();
      return '${names.length} methods: ${names.take(12).join(", ")}';
    } finally {
      await client.close();
    }
  });
  return out;
}
