# url_launcher_sailfish

Sailfish OS implementation of the [`url_launcher`](https://pub.dev/packages/url_launcher) plugin.
Pure Dart; it talks to the system over D-Bus. Part of the flutter-sailfish repository (BSD 3-Clause,
see the top-level `LICENSE`).

Add it next to `url_launcher` in the app's pubspec:

```yaml
dependencies:
  url_launcher: ^6.3.0
  url_launcher_sailfish:
    path: ../path/to/packages/url_launcher_sailfish
```

`flutter-sailfish` then registers this implementation and not `url_launcher_linux` (the package
declares `implements: url_launcher`).

Status: experimental. See `docs/flutter-packages.md` in the repository for what has been verified on a device.
