// Generates the Dart plugin registration for a Sailfish build.
//
// The flutter tool normally writes this for the platforms it knows; the Sailfish build
// does not go through it, so this script does the same job. It reads every package in
// `.dart_tool/package_config.json`, looks at `flutter: plugin: platforms:` in its
// pubspec.yaml and, for each plugin that has a Dart implementation for Sailfish, writes
// an entry point that registers it and then calls the app's own `main`.
//
// Per plugin, the `sailfish` platform entry is used when present, otherwise `linux`
// (Sailfish reports itself as Linux to Dart, so pure Dart Linux implementations work).
//
// A `sailfish` entry may also carry native C++ code:
//
//   flutter:
//     plugin:
//       platforms:
//         sailfish:
//           nativeSources: sailfish        # directory with the *.cc files, relative to the package
//           nativeLibrary: my_plugin       # optional, default: the package name -> libmy_plugin.so
//           dartPluginClass: MyPluginSailfish   # optional, a Dart class with registerWith()
//           sailjailPermissions: [Internet]     # optional, added to the app's desktop entry
//
// A package that implements another plugin for Sailfish (federated plugins) says so with
// `flutter: plugin: implements: <app-facing package>`; the Linux implementations of that
// package are then not registered, and are listed under "overridden" in plugins.json.
//
// Those are listed under "native_sailfish" in plugins.json; `flutter-sailfish native` builds them.
// "sailjail_permissions" is the union over all plugins and the app (with the requesters in
// "sailjail_permission_sources"); `flutter-sailfish permissions` checks and writes it.
//
// Run with the packages of the flutter tool, which provide `yaml` and `path`:
//   dart --packages=<sdk>/packages/flutter_tools/.dart_tool/package_config.json \
//        sailfish_plugins.dart <app dir>
//
// Output: <app>/.dart_tool/sailfish/main.dart and plugins.json (a report).

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class Plugin {
  Plugin(this.name, this.dartClass, this.platform, this.implementsPackage);
  final String name;
  final String dartClass;
  final String platform; // 'sailfish' or 'linux'
  final String? implementsPackage; // `flutter: plugin: implements:` (federated plugins)
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: sailfish_plugins.dart <app dir>');
    exit(2);
  }
  final appDir = Directory(args[0]).absolute.path;
  final configFile = File(p.join(appDir, '.dart_tool', 'package_config.json'));
  if (!configFile.existsSync()) {
    stderr.writeln('${configFile.path} not found; run "flutter pub get" first.');
    exit(1);
  }

  final appPubspec = loadYaml(File(p.join(appDir, 'pubspec.yaml')).readAsStringSync()) as YamlMap;
  final appName = appPubspec['name'] as String;
  final deps = _keys(appPubspec['dependencies']);
  final devOnly = _keys(appPubspec['dev_dependencies']).difference(deps);

  final config = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final plugins = <Plugin>[];
  final native = <Map<String, String>>[];
  final nativeSailfish = <Map<String, String>>[];
  final skipped = <String>[];
  final permissionSources = <String, Set<String>>{}; // permission -> who asked for it

  // The app itself can ask for permissions too:
  //   flutter:
  //     sailfish:
  //       sailjailPermissions: [Internet]
  final appSailfish = (appPubspec['flutter'] as YamlMap?)?['sailfish'];
  if (appSailfish is YamlMap && appSailfish['sailjailPermissions'] is YamlList) {
    for (final permission in (appSailfish['sailjailPermissions'] as YamlList).cast<String>()) {
      permissionSources.putIfAbsent(permission, () => <String>{}).add('$appName (app)');
    }
  }

  for (final entry in (config['packages'] as List).cast<Map<String, dynamic>>()) {
    final name = entry['name'] as String;
    if (name == appName || devOnly.contains(name)) continue;
    final root = configFile.uri.resolve(entry['rootUri'] as String);
    final pubspecFile = File(p.join(root.toFilePath(), 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) continue;

    final YamlMap pubspec;
    try {
      pubspec = loadYaml(pubspecFile.readAsStringSync()) as YamlMap;
    } catch (_) {
      continue;
    }
    final platforms = (((pubspec['flutter'] as YamlMap?)?['plugin'] as YamlMap?)?['platforms']) as YamlMap?;
    if (platforms == null) continue;

    final String platform;
    if (platforms['sailfish'] != null) {
      platform = 'sailfish';
    } else if (platforms['linux'] != null) {
      platform = 'linux';
    } else {
      continue;
    }
    final spec = platforms[platform];
    if (spec is! YamlMap) continue;

    // Native code for Sailfish: a directory of C++ sources, built into lib<library>.so and
    // loaded by the runner (see embedder/include/flutter_sailfish_plugin.h).
    // Sailjail permissions the plugin needs; they end up in the app's desktop entry.
    if (platform == 'sailfish' && spec['sailjailPermissions'] is YamlList) {
      for (final permission in (spec['sailjailPermissions'] as YamlList).cast<String>()) {
        permissionSources.putIfAbsent(permission, () => <String>{}).add(name);
      }
    }

    final nativeSources = spec['nativeSources'];
    if (platform == 'sailfish' && nativeSources is String) {
      final dir = p.normalize(p.join(root.toFilePath(), nativeSources));
      if (!Directory(dir).existsSync()) {
        stderr.writeln('WARNING: $name: nativeSources "$nativeSources" does not exist');
      } else {
        nativeSailfish.add({
          'name': name,
          'sources': dir,
          'library': (spec['nativeLibrary'] as String?) ?? name,
        });
      }
    }

    final implementsPackage =
        (((pubspec['flutter'] as YamlMap?)?['plugin'] as YamlMap?)?['implements']) as String?;
    if (spec['dartPluginClass'] != null) {
      plugins.add(Plugin(name, spec['dartPluginClass'] as String, platform, implementsPackage));
      // A Dart class next to a native pluginClass means the Dart code talks to native code
      // through a platform channel; the Sailfish runner has no such native part yet.
      if (spec['pluginClass'] != null) {
        native.add({
          'name': name,
          'platform': platform,
          'pluginClass': spec['pluginClass'] as String,
          'implements': implementsPackage ?? '',
        });
      }
    } else if (spec['default_package'] != null) {
      skipped.add('$name (endorses ${spec['default_package']})');
    } else if (spec['pluginClass'] != null) {
      native.add({
        'name': name,
        'platform': platform,
        'pluginClass': spec['pluginClass'] as String,
        'implements': implementsPackage ?? '',
      });
    }
  }

  // A federated plugin can have its implementation replaced: when a package with a `sailfish`
  // entry says `implements: url_launcher`, the Linux implementations of url_launcher (which
  // would need GTK, or would register on top of it) are dropped. Without this both would
  // register and the last one registered would win.
  final replacedBy = <String, String>{}; // app-facing package -> Sailfish implementation
  for (final pl in plugins) {
    if (pl.platform == 'sailfish' && pl.implementsPackage != null) {
      replacedBy[pl.implementsPackage!] = pl.name;
    }
  }
  final overridden = <Map<String, String>>[];
  plugins.removeWhere((pl) {
    final by = pl.platform == 'linux' ? replacedBy[pl.implementsPackage] : null;
    if (by == null) return false;
    overridden.add({'name': pl.name, 'platform': pl.platform, 'implements': pl.implementsPackage!, 'replacedBy': by});
    return true;
  });
  native.removeWhere((n) => n['platform'] == 'linux' && replacedBy.containsKey(n['implements']));
  plugins.sort((a, b) => a.name.compareTo(b.name));

  final mainSource = File(p.join(appDir, 'lib', 'main.dart')).readAsStringSync();
  final mainTakesArgs = RegExp(r'\bmain\s*\(\s*List<String>').hasMatch(mainSource);

  final out = StringBuffer()
    ..writeln('// Generated by flutter-sailfish. Do not edit.')
    ..writeln('// ignore_for_file: type=lint')
    ..writeln()
    ..writeln("import 'package:$appName/main.dart' as entrypoint;");
  for (var i = 0; i < plugins.length; i++) {
    out.writeln("import 'package:${plugins[i].name}/${plugins[i].name}.dart' as p$i;");
  }
  out
    ..writeln()
    ..writeln('void _registerPlugins() {');
  for (var i = 0; i < plugins.length; i++) {
    final pl = plugins[i];
    out
      ..writeln('  try {')
      ..writeln('    p$i.${pl.dartClass}.registerWith();')
      ..writeln('  } catch (err) {')
      ..writeln("    print('`${pl.name}` threw an error: \$err. The app may not function as expected.');")
      ..writeln('  }');
  }
  out
    ..writeln('}')
    ..writeln()
    ..writeln("@pragma('vm:entry-point')")
    ..writeln('Future<void> main(List<String> args) async {')
    ..writeln('  _registerPlugins();')
    ..writeln('  entrypoint.main(${mainTakesArgs ? 'args' : ''});')
    ..writeln('}');

  final outDir = Directory(p.join(appDir, '.dart_tool', 'sailfish'))..createSync(recursive: true);
  File(p.join(outDir.path, 'main.dart')).writeAsStringSync(out.toString());
  File(p.join(outDir.path, 'plugins.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'registered': [
      for (final pl in plugins) {'name': pl.name, 'class': pl.dartClass, 'platform': pl.platform},
    ],
    'sailjail_permissions': permissionSources.keys.toList()..sort(),
    'sailjail_permission_sources': {
      for (final e in permissionSources.entries) e.key: e.value.toList()..sort(),
    },
    'overridden': overridden,
    'native_sailfish': nativeSailfish,
    'native_not_supported': native,
    'endorsing_only': skipped,
  }));

  stdout.writeln('flutter-sailfish: ${plugins.length} Dart plugin(s) registered');
  for (final pl in plugins) {
    stdout.writeln('  ${pl.name} (${pl.platform}) -> ${pl.dartClass}');
  }
  for (final o in overridden) {
    stdout.writeln('  ${o['name']} (linux) not registered: ${o['replacedBy']} implements ${o['implements']} for Sailfish');
  }
  for (final n in nativeSailfish) {
    stdout.writeln('  native:${n['name']} -> lib${n['library']}.so (${n['sources']})');
  }
  for (final e in permissionSources.entries) {
    stdout.writeln('  Sailjail permission ${e.key} (requested by ${(e.value.toList()..sort()).join(', ')})');
  }
  for (final n in native) {
    stdout.writeln('  WARNING: ${n['name']} needs a native ${n['platform']} implementation '
        '(${n['pluginClass']}), which the Sailfish runner does not provide yet; '
        'calls into it will fail at run time');
  }
  stdout.writeln('  entry point: ${p.join(outDir.path, 'main.dart')}');
}

Set<String> _keys(Object? map) => map is YamlMap ? map.keys.cast<String>().toSet() : <String>{};
