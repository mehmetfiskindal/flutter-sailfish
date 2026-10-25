# Engine build notes

## Pinned versions

See `engine/flutter_engine.lock`. Current pin: Flutter 3.47.8 (stable), engine `cf636b1dfb818dd6a3ff16e390e93b1a036969c8`, Dart 3.13.7.

## Locations (Windows host)

| What | Path |
|---|---|
| Flutter SDK (app builds) | `tools\flutter` |
| depot_tools | `C:\src\flutter-engine\depot_tools` |
| Flutter + Engine monorepo | `C:\src\flutter-engine\flutter` (engine sources under `engine\src`) |
| `.gclient` | `C:\src\flutter-engine\flutter\.gclient` (solution name `.`) |

Engine and depot_tools live outside OneDrive on purpose (tens of GB, many small files).

## How the checkout was made

```powershell
$env:PATH = "C:\src\flutter-engine\depot_tools;$env:PATH"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
cd C:\src\flutter-engine\flutter
gclient sync -D --no-history --nohooks -j8
```

Hooks were skipped (`--nohooks`): sysroots and toolchains are not downloaded yet.

## flutter doctor (2026-10-25)

- OK: Windows, Android toolchain, Chrome, Visual Studio 2026, devices, network.
- Crashed: the "Flutter" check, because the SDK path contains a non-ASCII character
  (`Masaüstü`): `Cannot resolve symbolic links`. Harmless for this setup, but use an
  ASCII-only path (for example `C:\src\flutter`) if `flutter` commands misbehave.

## Sailfish SDK (found 2026-10-25)

- SDK on host: `C:\SailfishOS` (release 3.13.5); `sfdk.exe` is `C:\SailfishOS\bin\sfdk.exe`, not on PATH.
- Build engine runs in Docker: container `sailfish-sdk-build-engine_mfisk` (image `sailfish-sdk-build-engine:mfisk`, 1.35 GB). `sfdk` is also at `/usr/bin/sfdk` inside it.
- Targets (`sfdk tools list`): `SailfishOS-5.1.0.11-{aarch64,armv7hl,i486}` and the early-access `SailfishOS-5.1.0.11EA-{aarch64,armv7hl,i486}`.
- `sfdk.exe` warns "Not running under MSYS shell" and prints D-Bus NoReply errors when run from PowerShell, but `tools list` still works.

## Target sysroot facts: SailfishOS-5.1.0.11-aarch64 (read from the build engine)

- glibc 2.41, libstdc++ 13.4.0 (`libstdc++.so.6.0.32`), wayland 1.24.0.
- Present: `libEGL`, `libGLESv2`, `libwayland-client/-egl/-cursor`, `libxkbcommon`, Qt 5.6.3 (`libQt5Gui`, `libQt5WaylandClient`).
- This is newer than what Google's prebuilt Linux arm64 engine needs, so a prebuilt engine should link and load without rebuilding it.

## Prebuilt engine artifacts (HTTP HEAD checked for engine `cf636b1d...`)

Base URL: `https://storage.googleapis.com/flutter_infra_release/flutter/<engine_version>/`

| Path | Status |
|---|---|
| `linux-arm64/linux-arm64-embedder.zip` (debug `libflutter_engine.so` + `flutter_embedder.h`) | exists, 14.2 MB |
| `linux-arm64/artifacts.zip` | exists, 32.3 MB |
| `linux-arm64-release/linux-arm64-flutter-gtk.zip` | exists, GTK-based, not usable on Sailfish |
| `linux-arm64-{profile,release}/linux-arm64-embedder.zip` | 404, release engine must be built from source |

## Proof-of-concept plan (before any real development)

1. Download `linux-arm64-embedder.zip` (debug JIT engine); no engine build needed.
2. Build a minimal C++ Wayland + EGL/GLES runner against the aarch64 target with `sfdk`, linking `libflutter_engine.so`.
3. Build the sample app with `flutter build bundle` (kernel blob and assets, debug mode).
4. Run on a real aarch64 device. The SDK emulator is i486 and cannot run the Flutter engine.
5. Success: first frame, text rendered, touch reaches a widget.

## PoC status (2026-10-26)

- The Flutter SDK was moved to `C:\src\flutter-sdk` (ASCII path). With the `ü` path, `flutter build bundle` failed in impellerc (shader includes not found) and `flutter doctor` crashed.
- `embedder/src/main.cpp` (Qt + OpenGL ES runner) compiles and links for aarch64 inside the build engine (`sb2 -t SailfishOS-5.1.0.11-aarch64`). sb2 only sees `$HOME` and `/tmp`, so sources are copied to `~/frb` in the container first.
- `examples/counter` builds with `flutter build bundle` (debug, JIT kernel blob).
- Deployable set is staged in `dist/poc/`: `flutter-sailfish-runner`, `libflutter_engine.so`, `icudtl.dat`, `flutter_assets/`.
- **2026-10-26: runs on a Redmi Note 8 (Sailfish OS 5.1.0.11, aarch64, Adreno 610, OpenGL ES 3.2).** The prebuilt debug linux-arm64 engine plus the Qt runner renders the counter app. Touch confirmed by the user: tapping the + button increments the counter (2026-10-26). Debug/JIT only so far.
- Fixes needed on the way: Qt on Sailfish reports window size in device pixels (do not multiply by the pixel ratio); the window is 0x0 until the compositor sizes it, so fall back to the screen size.

Run on the device:

```sh
cd /home/defaultuser/flutter-poc
LD_LIBRARY_PATH=. ./flutter-sailfish-runner ./flutter_assets ./icudtl.dat
```

## Release/AOT build (2026-10-26, confirmed on the Redmi Note 8)

Engine built from the pinned source in a Docker Ubuntu 24.04 container (`flutter-engine-build`, volume `flutter-engine-src` mounted at `/work`, 8 CPUs, 7.7 GB RAM, `ninja -j6`, about 1 h).

```sh
cd /work/flutter/engine/src
python3 flutter/tools/gn --linux --linux-cpu arm64 --runtime-mode release --embedder-for-target \
  --disable-desktop-embeddings --no-lto --no-rbe --no-goma --no-enable-unittests --no-build-glfw-shell
cd out/linux_release_arm64 && ninja -j6 libflutter_engine.so clang_x64/gen_snapshot
```

- `libflutter_engine.so`: aarch64, 15 MB, needs at most GLIBC_2.18. `clang_x64/gen_snapshot`: x86-64 Linux host tool. Copies are in `dist/aot/engine/`.
- App kernel: `frontend_server_aot.dart.snapshot` from the Windows SDK cache with `--aot --tfa -Ddart.vm.product=true` against `flutter_patched_sdk_product`. In PowerShell pass the `-D...` options through an argument array, otherwise they are mangled.
- App library: `gen_snapshot --deterministic --snapshot_kind=app-aot-elf --elf=libapp.so --strip app.dill` (run in the container).
- Assets: `flutter build bundle --release`.
- The runner takes the AOT library as an optional third argument: `flutter-sailfish-runner <flutter_assets> <icudtl.dat> [libapp.so]`. Package: `dist/aot/app`.
- Result: counter app runs in release mode, renders and reacts to touch.

## RPM packages (2026-10-26)

Specs in `packaging/`, built in the build engine with
`sb2 -t SailfishOS-5.1.0.11-aarch64 -m sdk-build rpmbuild -bb --target aarch64 ...` (plain `rpmbuild` on the SDK host refuses aarch64: "No compatible architectures"). Prebuilt files are passed in with `--define "stage <dir>"`; `__os_install_post`, strip and debuginfo are disabled so the engine and `libapp.so` stay untouched.

- `flutter-sailfish-runtime-0.1.0-1.aarch64.rpm` (5.5 MB): `/usr/bin/flutter-sailfish-runner`, `/usr/libexec/flutter-sailfish/libflutter_engine.so`, `/usr/share/flutter-sailfish/icudtl.dat`.
- `harbour-flutter-counter-0.1.0-1.aarch64.rpm` (1.7 MB): launcher `/usr/bin/harbour-flutter-counter`, `/usr/share/harbour-flutter-counter/{flutter_assets,lib/libapp.so}`, desktop entry and icon. Requires the runtime package.
- Output copies: `dist/rpm/` (release `-3` is the working one). Installed and launched from the app grid on the Redmi Note 8 (confirmed 2026-10-26).
- Lessons from getting it to launch from the menu:
  - Sailfish starts apps through `invoker`/`sailjail`, which enforces a sandbox and needs an ELF binary (`is not elf binary` for a shell launcher). The app package therefore installs a copy of the runner as `/usr/bin/harbour-flutter-counter`; with no arguments the runner derives its bundle from its own file name (`/usr/share/<name>/{flutter_assets,lib/libapp.so,icudtl.dat}`).
  - The sandbox only exposes the app's own `/usr/share/<name>/`, so `icudtl.dat` is shipped there as well (the runtime's copy at `/usr/share/flutter-sailfish/` is not visible).
  - The desktop entry has an `[X-Sailjail]` section with empty `Permissions=`.
- Debug stderr logging of the runner is still on; remove before release.

## Platform channels, text input, lifecycle (2026-10-26, release `-5`)

Implemented in `embedder/src/main.cpp`: `flutter/platform` (SystemNavigator.pop, clipboard), `flutter/textinput` (JSON codec, editing model, Qt input method events, hardware key events), `flutter/lifecycle` (from `QGuiApplication::applicationStateChanged`), keyboard height as bottom view inset.

- **Platform task runner is mandatory.** Without `custom_task_runners.platform_task_runner` the engine queues platform tasks on the calling thread's message loop, which the runner never runs, so no platform channel message from Dart ever arrives (rendering and pointer events still work, which hides the problem). The runner posts engine tasks to the Qt GUI thread (`TaskEvent`, `QObject::startTimer` for delayed tasks, `FlutterEngineRunTask`).
- Engine callbacks run on engine threads; messages are handed to the GUI thread with `QCoreApplication::postEvent` (Qt 5.6 has no functor `invokeMethod`).
- Confirmed on the Redmi Note 8: the Maliit keyboard opens, typed characters reach the `TextField`, lifecycle `inactive` then `resumed` at startup.
- Also confirmed by the user on the Redmi Note 8: backspace, Enter (new line in the multiline field, `submitted` in the single-line field), predictive text selection, and lifecycle changes when the app is sent to the background and brought back.
- Not yet checked: layout when the keyboard covers a field, hardware keyboards, IME composition for languages that use preedit text, text selection handles and the context menu, accessibility.
- `FLUTTER_SAILFISH_VERBOSE=1` enables per-message and per-input-event logging.

## Open questions (not yet verified)

- Cross-compiling the engine from Windows to Linux/aarch64 is not supported upstream.
  A real build needs the Sailfish SDK build engine or a Linux host.
- Which sysroot / GN toolchain the Sailfish target needs (libc, libstdc++, EGL/GLES, Wayland).
- Whether the pinned engine builds for `armv7hl` and `i486` at all.

## Next steps

1. Locate Sailfish SDK and run `sfdk tools list`.
2. Record target sysroot facts (`uname -m`, `ldd --version`, Qt/Wayland/EGL versions).
3. Define a GN args file for `aarch64` and try `gn gen` + linking `//flutter/shell/platform/embedder:flutter_engine`.
