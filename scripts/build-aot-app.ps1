# Builds a Flutter app as a linux-arm64 AOT bundle for the Sailfish runner.
#
# Needs: Flutter SDK at C:\src\flutter-sdk (ASCII path, matching the pinned engine),
# and the Docker container "flutter-engine-build" holding the release engine build
# (provides the x64 gen_snapshot that targets arm64).
#
# Usage: .\scripts\build-aot-app.ps1 -App examples\counter
param(
  [Parameter(Mandatory)][string]$App,
  [string]$FlutterSdk = 'C:\src\flutter-sdk',
  [string]$Container = 'flutter-engine-build',
  [string]$GenSnapshot = '/work/flutter/engine/src/out/linux_release_arm64/clang_x64/gen_snapshot'
)
# Native tools write warnings to stderr; success is checked explicitly instead.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$src = (Resolve-Path (Join-Path $root $App)).Path
$out = Join-Path $root 'dist\aot\app'
$cache = Join-Path $FlutterSdk 'bin\cache'
$env:PATH = "$FlutterSdk\bin;$env:PATH"

# Build in a copy under an ASCII path (impellerc fails on non-ASCII paths). An app with local
# path dependencies (path: ../some_plugin) is copied together with its siblings, so the
# relative paths keep working.
$hasPathDeps = (Get-Content (Join-Path $src 'pubspec.yaml') -Raw) -match '(?m)^\s+path:\s*\.\.'
$copyRoot = if ($hasPathDeps) { Split-Path -Parent $src } else { $src }
$workRoot = Join-Path 'C:\src\aot-build' (Split-Path -Leaf $copyRoot)
$work = if ($hasPathDeps) { Join-Path $workRoot (Split-Path -Leaf $src) } else { $workRoot }
if (Test-Path $workRoot) { Remove-Item $workRoot -Recurse -Force }
robocopy $copyRoot $workRoot /E /XD build .dart_tool .git linux windows android ios macos web .idea /NFL /NDL /NJH /NJS /NP | Out-Null
Push-Location $work
try {
  flutter pub get | Out-Null

  # 0. Plugin registration: generates .dart_tool\sailfish\main.dart, which registers the
  #    plugins' Dart implementations and then calls the app's main.
  & "$PSScriptRoot\flutter-sailfish.ps1" plugins -App $work -FlutterSdk $FlutterSdk
  if (-not (Test-Path '.dart_tool\sailfish\main.dart')) { throw 'plugin registration failed' }

  # 0b. Native C++ code of the plugins, built for aarch64 in the Sailfish SDK build engine.
  New-Item -ItemType Directory -Force $out | Out-Null
  & "$PSScriptRoot\flutter-sailfish.ps1" native -App $work -Out "$out\plugins" -FlutterSdk $FlutterSdk

  # 0c. Sailjail permissions asked for by the plugins and the app; the RPM build writes them
  #     into the desktop entry.
  & "$PSScriptRoot\flutter-sailfish.ps1" permissions -App $work -Out "$out\sailjail-permissions.txt" -FlutterSdk $FlutterSdk

  # 1. AOT kernel (release, tree shaken). The -D options must go through an array in PowerShell.
  $fe = @("$cache\artifacts\engine\windows-x64\frontend_server_aot.dart.snapshot",
    '--sdk-root', "$cache\artifacts\engine\common\flutter_patched_sdk_product\",
    '--target=flutter', '--no-print-incremental-dependencies',
    '-Ddart.vm.profile=false', '-Ddart.vm.product=true', '--aot', '--tfa',
    '--packages', '.dart_tool\package_config.json', '--output-dill', 'app.dill',
    '--verbosity=error', '.dart_tool\sailfish\main.dart')
  & "$cache\dart-sdk\bin\dartaotruntime.exe" @fe
  if (-not (Test-Path app.dill)) { throw 'kernel compilation failed' }

  # 2. Assets (release bundles carry no kernel blob).
  flutter build bundle --release | Out-Null

  # 3. Precompile to an arm64 ELF with the x64 gen_snapshot from the engine build.
  docker cp app.dill "${Container}:/work/app.dill"
  docker exec $Container bash -c "cd /work && $GenSnapshot --deterministic --snapshot_kind=app-aot-elf --elf=libapp.so --strip app.dill"
  if ($LASTEXITCODE -ne 0) { throw 'gen_snapshot failed' }
  docker cp "${Container}:/work/libapp.so" libapp.so
} finally {
  Pop-Location
}

if (Test-Path "$out\flutter_assets") { Remove-Item "$out\flutter_assets" -Recurse -Force }
Copy-Item "$work\build\flutter_assets" "$out\flutter_assets" -Recurse
Copy-Item "$work\libapp.so" "$out\libapp.so" -Force
Write-Host "AOT bundle written to $out"
