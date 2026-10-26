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
# path dependencies (path: ../some_plugin) is copied together with them: the copy is the
# closest common parent of the app and of every such dependency, so that the relative paths
# keep working.
$localDeps = @()
foreach ($m in [regex]::Matches((Get-Content (Join-Path $src 'pubspec.yaml') -Raw), '(?m)^\s+path:\s*(\S+)')) {
  $candidate = [IO.Path]::GetFullPath((Join-Path $src $m.Groups[1].Value.Trim('"', "'")))
  if (Test-Path $candidate -PathType Container) { $localDeps += $candidate }   # (skips "path: ^1.9.0", the version of the path package)
}
$copyRoot = $src
if ($localDeps.Count -gt 0) {
  $common = @($src.TrimEnd('\').Split('\'))
  foreach ($dep in $localDeps) {
    $parts = $dep.TrimEnd('\').Split('\')
    $n = 0
    while ($n -lt $common.Count -and $n -lt $parts.Count -and $common[$n] -ieq $parts[$n]) { $n++ }
    $common = $common[0..($n - 1)]
  }
  $copyRoot = $common -join '\'
}
$workRoot = Join-Path 'C:\src\aot-build' (Split-Path -Leaf $copyRoot)
$work = Join-Path $workRoot $src.Substring($copyRoot.Length).TrimStart('\')
if (Test-Path $workRoot) { Remove-Item $workRoot -Recurse -Force }
robocopy $copyRoot $workRoot /E /XD build .dart_tool .git dist tools node_modules linux windows android ios macos web .idea /NFL /NDL /NJH /NJS /NP | Out-Null
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
  $feOutput = @(& "$cache\dart-sdk\bin\dartaotruntime.exe" @fe 2>&1 | ForEach-Object { "$_" })
  # The compiler writes a kernel file even when the program has errors; the last line of its
  # output ends with the number of errors ("<id> app.dill 2").
  $summary = $feOutput | Where-Object { $_.Trim() } | Select-Object -Last 1
  if (-not (Test-Path app.dill) -or $summary -notmatch '\s0$') {
    $feOutput | Where-Object { $_ -match 'Error|error:|\.dart:\d+' } | ForEach-Object { Write-Host $_ }
    throw "kernel compilation failed ($summary)"
  }

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
