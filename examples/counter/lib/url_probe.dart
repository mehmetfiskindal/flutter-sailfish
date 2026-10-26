import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher_sailfish/url_launcher_sailfish.dart';

DBusClient? _session;
DBusClient get _bus => _session ??= DBusClient.session();

/// Looks (without starting anything) at what could open a URL on this device, from inside the
/// sandbox: names on the session bus, which of the likely ones are running or can be started,
/// their D-Bus interfaces, and whether `xdg-open` can be run.
Future<List<String>> runUrlInspect() async {
  final out = <String>[];

  Future<void> step(String label, Future<String> Function() body) async {
    try {
      out.add('$label: ${await body().timeout(const Duration(seconds: 6))}');
    } catch (e) {
      out.add('$label: FAILED $e');
    }
  }

  final interesting = RegExp('browser|url|open|launch|content|mime|share|lipstick|jolla|nemo|sailfish', caseSensitive: false);
  var running = <String>[];
  var activatable = <String>[];

  await step('session names', () async {
    running = (await _bus.listNames()).where((n) => !n.startsWith(':')).toList()..sort();
    return '${running.length}: ${running.join(', ')}';
  });
  await step('activatable names', () async {
    activatable = (await _bus.listActivatableNames()).toList()..sort();
    final shown = activatable.where(interesting.hasMatch).toList();
    return '${activatable.length}, matching: ${shown.join(', ')}';
  });

  // Introspect the services the sandbox lets this app see. Introspection is allowed by the
  // sandbox for any name; only names that already run are asked, so that nothing is started.
  for (final target in const [
    ['com.jolla.lipstick', '/'],
    ['com.jolla.lipstick', '/com/jolla/lipstick'],
    ['org.sailfishos.share', '/'],
    ['org.sailfishos.share', '/org/sailfishos/share'],
    ['org.sailfishos.browser.ui', '/ui'],
  ]) {
    final name = target[0];
    final path = target[1];
    if (!running.contains(name)) {
      out.add('$name $path: ${activatable.contains(name) ? 'not running, can be started' : 'not on the bus'}');
      continue;
    }
    await step('$name $path', () async {
      final response = await _bus.callMethod(
        destination: name,
        path: DBusObjectPath(path),
        interface: 'org.freedesktop.DBus.Introspectable',
        name: 'Introspect',
      );
      return _describe((response.values.first as DBusString).value);
    });
  }

  // Which programs can the sandbox run? Reports the file's mode and what starting it did.
  for (final program in const [
    '/bin/sh',
    '/usr/bin/xdg-open',
    '/usr/bin/invoker',
    '/usr/bin/dbus-send',
    '/usr/bin/gdbus',
    '/usr/bin/gio',
    '/usr/bin/env',
    '/usr/bin/sailfish-browser',
  ]) {
    await step('exec $program', () async {
      final stat = FileStat.statSync(program);
      if (stat.type == FileSystemEntityType.notFound) return 'not visible in the sandbox';
      try {
        final result = await Process.run(program, ['--version']);
        final text = '${result.stdout}${result.stderr}'.trim().split('\n').first;
        return 'mode ${stat.modeString()}, started, exit ${result.exitCode} "$text"';
      } on ProcessException catch (e) {
        return 'mode ${stat.modeString()}, could not start: ${e.message} (errno ${e.errorCode})';
      }
    });
  }

  // The sandbox's view of the environment.
  final environment = Platform.environment;
  for (final key in const ['PATH', 'DBUS_SESSION_BUS_ADDRESS', 'XDG_RUNTIME_DIR', 'HOME', 'QT_IM_MODULE']) {
    out.add('env $key: ${environment[key] ?? '(unset)'}');
  }
  await step('/proc/self/status', () async {
    final lines = await File('/proc/self/status').readAsLines();
    return lines.where((l) => RegExp('^(NoNewPrivs|Seccomp|Uid|CapEff)').hasMatch(l)).map((l) => l.replaceAll(RegExp(r'\s+'), ' ')).join('; ');
  });
  return out;
}

/// Summarises introspection XML: interfaces (without the standard org.freedesktop.DBus ones)
/// with their methods and the types of their input arguments, e.g. `openUrl(s)`.
String _describe(String xml) {
  final lines = <String>[];
  for (final iface in RegExp(r'<interface name="([^"]+)">(.*?)</interface>', dotAll: true).allMatches(xml)) {
    final name = iface.group(1)!;
    if (name.startsWith('org.freedesktop.DBus.')) continue;
    final methods = <String>[];
    for (final method in RegExp(r'<method name="([^"]+)"[^>]*?(?:/>|>(.*?)</method>)', dotAll: true).allMatches(iface.group(2)!)) {
      final types = RegExp(r'<arg[^>]*type="([^"]+)"[^>]*direction="in"|<arg[^>]*direction="in"[^>]*type="([^"]+)"')
          .allMatches(method.group(2) ?? '')
          .map((a) => a.group(1) ?? a.group(2))
          .join('');
      methods.add('${method.group(1)}($types)');
    }
    lines.add('$name: ${methods.join(' ')}');
  }
  return lines.isEmpty ? '(no interfaces)' : lines.join(' || ');
}

/// Opens a URL through the url_launcher plugin API, i.e. through whichever implementation
/// flutter-sailfish registered, and reports which routes the Sailfish implementation tried.
Future<List<String>> runUrlLaunch(String url) async {
  final out = <String>[];
  final implementation = UrlLauncherSailfish.current;
  out.add('implementation: ${implementation == null ? 'NOT the Sailfish one' : 'UrlLauncherSailfish'}');
  try {
    final uri = Uri.parse(url);
    out.add('canLaunchUrl: ${await canLaunchUrl(uri)}');
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    out.add('launchUrl: $opened');
  } catch (e) {
    out.add('launchUrl: FAILED $e');
  }
  for (final attempt in implementation?.attempts ?? const <String>[]) {
    out.add('  $attempt');
  }
  return out;
}
