# Third-party notices

This repository's own code is under the BSD 3-Clause license (`LICENSE`).

## Included in this repository

| Path | What | License |
|---|---|---|
| `embedder/third_party/flutter_client_wrapper/` | Flutter's C++ client wrapper (`MethodChannel`, `StandardMethodCodec`, `EncodableValue`, ...), copied from `flutter/shell/platform/common/client_wrapper` at the pinned Flutter commit. Two changes: `reply_manager.cc` is an unchanged extract of `core_implementations.cc`, and `include/flutter/event_channel.h` has a one-line fix marked in the file. | BSD 3-Clause, The Flutter Authors; see `LICENSE` in that directory |
| `embedder/third_party/flutter_engine/flutter_embedder.h` | The engine's C embedder API header, unmodified | BSD 3-Clause, The Flutter Authors; see `LICENSE` in that directory |

## Used but not included

- **Flutter engine and Dart SDK** (BSD 3-Clause, The Flutter Authors / The Dart Project Authors): built from source with `scripts/build-engine.sh` without patches. If you distribute `libflutter_engine.so` or an app built with it, include Flutter's license notices (the engine tree's `LICENSE` and the license data it produces) with it.
- **Qt 5** (LGPL 3 and others): the runner links dynamically against the Qt libraries that Sailfish OS provides.
- **Flutter framework and packages used by the example app** (`shared_preferences`, `path_provider`, `dbus` and their dependencies): downloaded by `flutter pub get`; their licenses apply to apps that include them. An app's `NOTICES` are bundled in its `flutter_assets`.

This is not legal advice; check the licenses of what you ship.
