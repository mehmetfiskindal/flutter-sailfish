# flutter-sailfish

An unofficial, experimental port that runs Flutter apps on Sailfish OS.

It is a small Qt/OpenGL ES host ("runner") for the **unmodified** Flutter engine, plus packaging scripts and notes on how to build everything. It is not affiliated with or endorsed by Google, the Flutter team or Jolla.

## Status

Proof of concept. A Flutter example app runs from the app grid, in release (AOT) mode, on one device.

Tested on: Redmi Note 8 (`aarch64`), Sailfish OS 5.1.0.11, Flutter 3.47.8 (engine `cf636b1dfb818dd6a3ff16e390e93b1a036969c8`).

| Area | State |
|---|---|
| Rendering (OpenGL ES, Wayland through Qt) | Works |
| Touch input | Works |
| Release / AOT mode | Works (engine built from source, see docs) |
| Debug / JIT mode | Works (prebuilt linux-arm64 embedder from Google) |
| On-screen keyboard and text input | Works: typing, backspace, enter, predictive text selection |
| App lifecycle (`resumed`, `inactive`, `hidden`, `paused`) | Works |
| Clipboard, `SystemNavigator.pop` | Implemented, lightly tested |
| RPM packaging, launch from the app grid under Sailjail | Works |
| Keyboard avoiding a covered field, hardware keyboard, selection handles, context menu | Not verified |
| Accessibility | Not implemented |
| Pure Dart Linux plugins (`shared_preferences`, `path_provider`) | Work, registered by hand in `main.dart` |
| Native Sailfish plugins (camera, location, notifications, ...) | None yet; D-Bus from Sailjail untested |
| `armv7hl`, `i486` | Not tried |
| Other devices and Sailfish versions | Not tested |
| Harbour store compliance | No |

Do not assume it works on your device. Reports are welcome.

## How it works

- The engine is the stock Flutter engine for `linux-arm64`, built from the pinned Flutter commit with no patches (`engine/flutter_engine.lock`, build recipe in `docs/engine-build.md`).
- `embedder/src/main.cpp` is the runner. It uses Qt 5 (as shipped by Sailfish) for the window, the OpenGL ES context, touch events and the Maliit input method, and talks to the engine through the C embedder API.
- A custom **platform task runner** is required. Without it the engine never delivers platform channel messages.
- Apps are compiled ahead of time with the engine's own `gen_snapshot` and shipped as `libapp.so` plus `flutter_assets`.
- Under Sailjail the launcher must be an ELF binary and only the app's own `/usr/share/<name>/` is visible, so the app package installs a copy of the runner as `/usr/bin/<name>` and bundles `icudtl.dat` next to the app.

## Repository layout

| Path | Purpose |
|---|---|
| `embedder/` | The Qt runner and its qmake project |
| `packaging/` | RPM specs, desktop entry, icon (runtime package and example app package) |
| `scripts/build-aot-app.ps1` | Builds a Flutter app as an arm64 AOT bundle |
| `examples/counter/` | Example app (counter, text fields, lifecycle display) |
| `engine/flutter_engine.lock` | Pinned Flutter and engine versions |
| `docs/engine-build.md` | Environment notes, engine build recipe, packaging, lessons learned |

Not in the repository: the Flutter engine sources, built binaries and RPMs.

## Building

The full, current procedure is in [`docs/engine-build.md`](docs/engine-build.md). In short:

1. Check out the pinned Flutter commit and build the engine on Linux x64 with the GN arguments listed in the docs (`--linux --linux-cpu arm64 --runtime-mode release --embedder-for-target --disable-desktop-embeddings`). This produces `libflutter_engine.so` and the x64 `gen_snapshot` that targets arm64.
2. Build the runner for the `aarch64` target with the Sailfish SDK build engine (`sb2`, qmake).
3. Build an app with `scripts/build-aot-app.ps1`.
4. Package with `rpmbuild` through `sb2 -m sdk-build` using the specs in `packaging/`.

The paths and tools in the scripts reflect the author's Windows + Docker setup and will need adapting.

## Known caveats

- Every Flutter release needs a matching engine rebuild.
- The runner still prints some diagnostics to stderr; set `FLUTTER_SAILFISH_VERBOSE=1` for per-message logging.
- The example package is called `harbour-flutter-counter` only because it was the first name used. The `harbour-` prefix is meant for apps accepted into the Harbour store, so rename it for your own work.
- The desktop entry grants no Sailjail permissions.

## License

The code in this repository is under the BSD 3-Clause license (see `LICENSE`).

The Flutter engine and Dart SDK are Copyright The Flutter Authors / The Dart Project Authors, licensed under BSD-3-Clause; their license notices must accompany any binaries you redistribute. The runner links dynamically against Qt 5 (LGPL) as provided by Sailfish OS.
