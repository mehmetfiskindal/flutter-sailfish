# Building

How to go from a fresh checkout to RPMs you can install on a Sailfish OS device. The scripts are
PowerShell and were written on Windows 11 with Docker Desktop. Nothing in the build needs WSL
distributions of your own; the Linux parts run in Docker containers. On Linux or macOS the
shell scripts (`*.sh`) and `sailfish_plugins.dart` carry over, the `*.ps1` wrappers would need a port.

Everything here was run for the pinned versions in `engine/flutter_engine.lock` and checked on one
device (Redmi Note 8, aarch64, Sailfish OS 5.1.0.11). The one script that has not been run from an
empty container is `scripts/build-engine.sh`; it collects the commands that were run by hand.

## What you need

| Tool | Notes |
|---|---|
| Windows 10/11, PowerShell 5.1 or newer | |
| Docker Desktop | about 100 GB free for the engine build; 8 CPUs and 8 GB RAM are enough |
| [Sailfish SDK](https://docs.sailfishos.org/Tools/Sailfish_SDK/) | its build engine runs as the Docker container `sailfish-sdk-build-engine*`; it must be running |
| Flutter SDK at `C:\src\flutter-sdk` | the pinned version (`flutter_tag` in the lock file), e.g. `git clone --branch stable ...` then `git checkout <flutter_commit>`; run `flutter --version` once. Use an ASCII path: shader compilation fails when the SDK or the app is under a path with non-ASCII characters |
| Git, Dart (comes with Flutter) | |
| A device in Developer Mode | for `scp` and `rpm`; no SSH passwords are stored anywhere in this repository |

`flutter-sailfish.ps1` finds the SDK build engine container by name. Target `SailfishOS-5.1.0.11-aarch64`
is the default (`-SdkTarget` changes it).

## 1. Build the engine (long, once per Flutter version)

```powershell
docker volume create flutter-engine-src
docker run -d --name flutter-engine-build -v flutter-engine-src:/work ubuntu:24.04 sleep infinity
docker cp engine\flutter_engine.lock flutter-engine-build:/work/flutter_engine.lock
docker cp scripts\build-engine.sh flutter-engine-build:/work/build-engine.sh
docker exec -d flutter-engine-build bash -c "bash /work/build-engine.sh > /work/build.log 2>&1"
```

Watch it with `docker exec flutter-engine-build tail -n 3 /work/build.log`; the last line is
`ENGINE_BUILD_DONE`. The engine is built unmodified (no patches) for `linux-arm64`, release mode,
without GTK. The API header used by the runner is vendored in `embedder/third_party/flutter_engine/`
and must match the pinned commit.

Then take what the Sailfish build needs out of the container:

```powershell
.\scripts\export-engine.ps1       # dist\aot\engine: libflutter_engine.so, gen_snapshot, icudtl.dat
```

## 2. Build the runner

```powershell
.\scripts\flutter-sailfish.ps1 runner      # dist\aot\app\flutter-sailfish-runner
```

This compiles `embedder/src/main.cpp` for aarch64 inside the SDK build engine with qmake (Qt 5 as shipped
by Sailfish). `sb2`, the SDK's cross-compilation sandbox, only sees `$HOME` and `/tmp`, so the script
copies the sources into the container first.

## 3. Build an app

```powershell
.\scripts\flutter-sailfish.ps1 build -App examples\counter
```

In order, in a copy of the app under `C:\src\aot-build` (and its sibling `path:` dependencies):

1. `flutter pub get`.
2. `sailfish_plugins.dart` finds plugins and writes `.dart_tool/sailfish/main.dart`, which registers their Dart classes and then runs the app's `main`.
3. Plugins with `nativeSources` are compiled for aarch64 into `dist\aot\app\plugins\`.
4. The Sailjail permissions plugins and the app ask for are validated and written to `dist\aot\app\sailjail-permissions.txt`.
5. The release kernel (`frontend_server_aot` with `--aot --tfa`), the asset bundle, and `libapp.so` with the engine's x64 `gen_snapshot` (run in the `flutter-engine-build` container).

## 4. Package

```powershell
.\scripts\flutter-sailfish.ps1 package     # dist\rpm\*.rpm
```

Two packages: `flutter-sailfish-runtime` (runner, engine, ICU data) and the app, which requires the
runtime and carries the app's `libapp.so`, assets, plugins, a copy of the runner and its own
`icudtl.dat`. The `.desktop` file's `Permissions=` comes from step 3. Names and versions are in
`packaging/*.spec`; raise `Release` for every package you want to update with `rpm -U`.

## 5. Install and run

```powershell
scp dist\rpm\flutter-sailfish-runtime-0.1.0-5.aarch64.rpm dist\rpm\harbour-flutter-counter-0.1.0-16.aarch64.rpm defaultuser@<device ip>:/home/defaultuser/
```

On the device:

```sh
devel-su rpm -Uvh flutter-sailfish-runtime-*.rpm harbour-flutter-counter-*.rpm
```

Start the app from the app grid. To see the runner's messages start it from a terminal instead
(`harbour-flutter-counter`; add `FLUTTER_SAILFISH_VERBOSE=1` for per-message logging). Running from a
terminal is not sandboxed; from the app grid it is, which matters for permissions, D-Bus and writable
directories.

## Things that went wrong before (so they do not again)

- **No platform channel messages arrive:** the engine needs a custom platform task runner; see the runner source.
- **Files are saved but not kept:** Sailjail only keeps writes under `~/.local/share/<Org>/<App>` (also `.config`, `.cache`). The runner points the XDG directories there.
- **Launching from the app grid fails with "is not elf binary":** the launcher must be an ELF binary, not a script.
- **`icudtl.dat` cannot be opened in the sandbox:** it must live under the app's own `/usr/share/<app>/`.
- **D-Bus calls fail after a few connections:** keep one connection per bus open instead of opening one per call.
- **A native plugin does not load, `undefined symbol ... ReplyManager`:** compile `reply_manager.cc` into it (the build script does).
- **PowerShell eats `-Ddart.vm.product=true`:** pass such options through an argument array.
- **`flutter doctor` crashes and shader builds fail:** the SDK path contains non-ASCII characters.
