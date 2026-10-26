import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Sailfish OS implementation of [UrlLauncherPlatform].
///
/// Web links (http and https) are handed to the Sailfish browser over D-Bus
/// (`org.sailfishos.browser.ui`, object `/ui`, method `openUrl`).
///
/// Inside the Sailjail sandbox an app can only reach that service when it has the
/// `FlutterOpenUrl` permission. The runtime package of flutter-sailfish installs that permission
/// and this package asks for it in its pubspec, so `flutter-sailfish` adds it to the app's
/// desktop entry. Other schemes (mailto, tel, ...) are not supported yet: [canLaunch] says no.
///
/// What each attempt did is kept in [attempts] (most recent launch only), which helps when a
/// launch fails.
class UrlLauncherSailfish extends UrlLauncherPlatform {
  UrlLauncherSailfish({SailfishUrlOpener? opener}) : _opener = opener ?? SailfishUrlOpener();

  /// Called by the code that flutter-sailfish generates.
  static void registerWith() {
    UrlLauncherPlatform.instance = UrlLauncherSailfish();
  }

  final SailfishUrlOpener _opener;

  /// Outcome of each route tried by the last [launchUrl], oldest first.
  List<String> get attempts => _opener.attempts;

  /// The platform instance when it is a [UrlLauncherSailfish], for diagnostics.
  static UrlLauncherSailfish? get current {
    final instance = UrlLauncherPlatform.instance;
    return instance is UrlLauncherSailfish ? instance : null;
  }

  @override
  final LinkDelegate? linkDelegate = null;

  static const _schemes = {'http', 'https'};

  @override
  Future<bool> canLaunch(String url) async {
    final uri = Uri.tryParse(url);
    return uri != null && _schemes.contains(uri.scheme.toLowerCase());
  }

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) {
    return launchUrl(url, const LaunchOptions());
  }

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    if (!await canLaunch(url)) return false;
    final error = await _opener.open(url);
    if (error != null) {
      throw PlatformException(code: 'Launch Error', message: 'Failed to launch URL: $error');
    }
    return true;
  }

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async {
    return mode == PreferredLaunchMode.platformDefault || mode == PreferredLaunchMode.externalApplication;
  }

  @override
  Future<bool> supportsCloseForMode(PreferredLaunchMode mode) async => false;

  @override
  Future<void> closeWebView() async {}
}

/// Opens web links through the routes described at [UrlLauncherSailfish].
class SailfishUrlOpener {
  /// The session bus connection is kept open: inside Sailjail, opening a connection per call
  /// made the sandbox's D-Bus proxy refuse later ones.
  static DBusClient? _session;
  static DBusClient get _bus => _session ??= DBusClient.session();

  /// Outcome of each route tried by the last [open], oldest first.
  final List<String> attempts = <String>[];

  /// Returns null when a route worked, otherwise why every route failed.
  Future<String?> open(String url) async {
    attempts.clear();
    // The browser accepts the links as a list of strings; some versions may take one string.
    if (await _try('browser openUrl(as)', () => _openWithBrowser(url, DBusArray.string([url])))) return null;
    if (await _try('browser openUrl(s)', () => _openWithBrowser(url, DBusString(url)))) return null;
    // Without the sandbox (an app started from a terminal) the generic opener works.
    if (await _try('xdg-open', () => _openWithXdg(url))) return null;
    return '${attempts.join('; ')}. Inside the Sailjail sandbox the app needs the '
        'FlutterOpenUrl permission (sailjailPermissions in the pubspec of url_launcher_sailfish) '
        'and the flutter-sailfish-runtime package that provides it.';
  }

  Future<bool> _try(String name, Future<void> Function() route) async {
    try {
      await route().timeout(const Duration(seconds: 10));
      attempts.add('$name: OK');
      return true;
    } catch (e) {
      attempts.add('$name: $e');
      return false;
    }
  }

  Future<void> _openWithBrowser(String url, DBusValue argument) async {
    await _bus.callMethod(
      destination: 'org.sailfishos.browser.ui',
      path: DBusObjectPath('/ui'),
      interface: 'org.sailfishos.browser.ui',
      name: 'openUrl',
      values: [argument],
      replySignature: DBusSignature(''),
    );
  }

  Future<void> _openWithXdg(String url) async {
    final result = await Process.run('xdg-open', [url]);
    if (result.exitCode != 0) {
      throw 'exit code ${result.exitCode} ${result.stderr}'.trim();
    }
  }
}
