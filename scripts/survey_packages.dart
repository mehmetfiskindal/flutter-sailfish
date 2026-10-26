// Classifies the packages of a flutter/packages checkout by what it takes to use them on Sailfish.
//
//   dart --packages=<sdk>/packages/flutter_tools/.dart_tool/package_config.json \
//        survey_packages.dart <flutter/packages checkout> [output.md]
//
// Sailfish reports itself as Linux to Dart, so an app-facing plugin is judged by its Linux
// implementation (federated plugins list it under `flutter: plugin: platforms: linux`):
//
//   pure Dart Linux implementation  -> usable as is (flutter-sailfish registers it)
//   native Linux implementation     -> has a pluginClass (GTK/glib C++); calls fail at run time,
//                                      a Sailfish implementation is needed
//   no Linux implementation         -> nothing to use; a Sailfish implementation is needed
//
// Packages without any plugin declaration are plain Dart/Flutter packages. They run anywhere the
// engine does unless they use something the platform lacks; the survey flags library code that
// imports dart:ffi or dart:html / package:web, which is only a hint.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class Pkg {
  Pkg(this.name, this.dir, this.pubspec);
  final String name;
  final String dir;
  final YamlMap pubspec;

  YamlMap? get platforms =>
      (((pubspec['flutter'] as YamlMap?)?['plugin'] as YamlMap?)?['platforms']) as YamlMap?;
  String? get implementsPackage => ((pubspec['flutter'] as YamlMap?)?['plugin'] as YamlMap?)?['implements'] as String?;
  bool get isPlugin => platforms != null || implementsPackage != null;
  String get version => '${pubspec['version'] ?? ''}';
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: survey_packages.dart <flutter/packages checkout> [output.md]');
    exit(2);
  }
  final root = Directory(p.join(args[0], 'packages'));
  final pkgs = <String, Pkg>{};
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    if (p.basename(f.path) != 'pubspec.yaml') continue;
    final rel = p.relative(f.path, from: root.path).replaceAll('\\', '/');
    if (RegExp(r'(^|/)(example|test|build|\.dart_tool|integration_test)(/|$)').hasMatch(rel)) continue;
    try {
      final y = loadYaml(f.readAsStringSync());
      if (y is YamlMap && y['name'] is String) {
        pkgs[y['name'] as String] = Pkg(y['name'] as String, p.dirname(f.path), y);
      }
    } catch (_) {}
  }

  // What does a Linux entry amount to?
  String linuxKind(YamlMap? entry) {
    if (entry == null) return 'none';
    final dart = entry['dartPluginClass'] != null;
    final native = entry['pluginClass'] != null;
    if (dart && native) return 'native';
    if (dart) return 'dart';
    if (native) return 'native';
    return 'endorsed';
  }

  String implLinuxKind(String implName) {
    final impl = pkgs[implName];
    return impl == null ? 'unknown' : linuxKind(impl.platforms?['linux'] as YamlMap?);
  }

  // A pure Dart implementation can still depend on a package that has a native Linux part
  // (image_picker_linux uses file_selector_linux); return that package's name.
  String? nativeDependency(String implName) {
    final deps = pkgs[implName]?.pubspec['dependencies'];
    if (deps is! YamlMap) return null;
    for (final dep in deps.keys.cast<String>()) {
      final other = pkgs[dep];
      if (other != null && linuxKind(other.platforms?['linux'] as YamlMap?) == 'native') return dep;
    }
    return null;
  }

  // App-facing plugins: plugins that do not implement another package. Packages that only
  // exist to test the tooling, or to help Android code, are left out.
  bool relevant(Pkg x) {
    if (x.name.contains('test_plugin') || x.name.startsWith('alternate_language')) return false;
    if (x.name == 'flutter_plugin_android_lifecycle') return false;
    return true;
  }
  final appFacing = pkgs.values.where((x) => x.isPlugin && x.implementsPackage == null && relevant(x)).toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  final rows = <List<String>>[];
  final summary = <String, int>{'works': 0, 'native': 0, 'none': 0, 'other': 0};

  for (final pkg in appFacing) {
    final linux = pkg.platforms?['linux'];
    final platformNames = (pkg.platforms?.keys.cast<String>().toList() ?? <String>[])..sort();
    String kind;
    String detail;
    String status;
    if (linux == null) {
      kind = 'none';
      detail = 'no Linux entry (${platformNames.join(', ')})';
      status = 'needs a Sailfish implementation';
      summary['none'] = summary['none']! + 1;
    } else if (linux is YamlMap && linux['default_package'] != null) {
      final impl = linux['default_package'] as String;
      final k = implLinuxKind(impl);
      kind = k;
      detail = '`$impl` (${{'dart': 'pure Dart', 'native': 'native GTK/C++', 'unknown': 'not in this repo', 'none': 'no Linux code'}[k] ?? k})';
      final nativeDep = k == 'dart' ? nativeDependency(impl) : null;
      if (k == 'dart' && nativeDep != null) {
        detail = '`$impl` (pure Dart, but depends on `$nativeDep`, which is native GTK/C++)';
        status = 'needs a Sailfish implementation of `$nativeDep`';
        summary['native'] = summary['native']! + 1;
      } else if (k == 'dart') {
        status = 'works as is';
        summary['works'] = summary['works']! + 1;
      } else if (k == 'native') {
        status = 'needs a Sailfish implementation';
        summary['native'] = summary['native']! + 1;
      } else {
        status = 'check';
        summary['other'] = summary['other']! + 1;
      }
    } else {
      final k = linuxKind(linux as YamlMap?);
      kind = k;
      detail = 'in the package itself (${k == 'dart' ? 'pure Dart' : 'native'})';
      status = k == 'dart' ? 'works as is' : 'needs a Sailfish implementation';
      summary[k == 'dart' ? 'works' : 'native'] = summary[k == 'dart' ? 'works' : 'native']! + 1;
    }
    rows.add([pkg.name, pkg.version, detail, status]);
  }

  // Plain packages: no plugin declaration at all.
  final plain = pkgs.values.where((x) => !x.isPlugin).toList()..sort((a, b) => a.name.compareTo(b.name));
  String hint(Pkg x) {
    final lib = Directory(p.join(x.dir, 'lib'));
    if (!lib.existsSync()) return '';
    final found = <String>{};
    for (final f in lib.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final text = f.readAsStringSync();
      if (text.contains('dart:ffi')) found.add('dart:ffi');
      if (text.contains('dart:html') || text.contains("package:web/")) found.add('web only');
    }
    return found.join(', ');
  }
  final platformInterfaces = plain.where((x) => x.name.endsWith('_platform_interface')).toList();
  final plainOthers = plain.where((x) => !x.name.endsWith('_platform_interface')).toList();

  // Implementations other than Linux are not relevant; count them for completeness.
  final implementations = pkgs.values.where((x) => x.implementsPackage != null).length;

  final out = StringBuffer()
    ..writeln('# flutter/packages on Sailfish OS')
    ..writeln()
    ..writeln('Generated by `scripts/survey_packages.dart` from a checkout of `flutter/packages`')
    ..writeln('(${pkgs.length} packages, ${appFacing.length} app-facing plugins, $implementations platform implementations, ${plain.length} plain Dart packages).')
    ..writeln('This is a static reading of the pubspec files; nothing here was run on a device unless stated in `docs/engine-build.md`.')
    ..writeln()
    ..writeln('Sailfish OS reports itself as Linux to Dart, so a plugin is judged by its Linux implementation.')
    ..writeln()
    ..writeln('## App-facing plugins')
    ..writeln()
    ..writeln('| Plugin | Version | Linux implementation | On Sailfish |')
    ..writeln('|---|---|---|---|');
  for (final r in rows) {
    out.writeln('| `${r[0]}` | ${r[1]} | ${r[2]} | ${r[3]} |');
  }
  out
    ..writeln()
    ..writeln('Totals: ${summary['works']} work as is, ${summary['native']} have a native Linux part, '
        '${summary['none']} have no Linux implementation, ${summary['other']} need a closer look.')
    ..writeln()
    ..writeln('## Plain packages (no platform code declared)')
    ..writeln()
    ..writeln('| Package | Version | Hint |')
    ..writeln('|---|---|---|');
  for (final x in plainOthers) {
    out.writeln('| `${x.name}` | ${x.version} | ${hint(x)} |');
  }
  out
    ..writeln()
    ..writeln('Platform interface packages (pure Dart, used by the plugins above): '
        '${platformInterfaces.map((x) => '`${x.name}`').join(', ')}.');

  final target = args.length > 1 ? args[1] : null;
  if (target != null) {
    File(target).writeAsStringSync(out.toString());
    stdout.writeln('wrote $target');
  }
  stdout.writeln('${pkgs.length} packages; app-facing plugins: ${appFacing.length}; '
      'works as is: ${summary['works']}, native: ${summary['native']}, none: ${summary['none']}, '
      'other: ${summary['other']}; plain: ${plainOthers.length}; interfaces: ${platformInterfaces.length}');
  for (final r in rows) {
    stdout.writeln('${r[0].padRight(28)} ${r[3].padRight(34)} ${r[2]}');
  }
}
