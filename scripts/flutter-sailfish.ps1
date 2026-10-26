# flutter-sailfish: small wrapper around the flutter tool for the Sailfish OS target.
#
#   flutter-sailfish.ps1 plugins -App <dir>                  generate the Dart plugin registration
#                                                            for an app that has run "flutter pub get"
#   flutter-sailfish.ps1 native  -App <dir> -Out <plugins>   build the plugins' native C++ code
#                                                            (needs "plugins" first)
#   flutter-sailfish.ps1 build   -App <dir>                  build an AOT bundle: plugins, native
#                                                            plugins, kernel, assets, libapp.so
#
# The flutter tool does not know the Sailfish platform, so what it would generate for Linux,
# Android and so on is produced here by scripts\sailfish_plugins.dart. A plugin is picked up
# through its pubspec.yaml: a Dart implementation for the "sailfish" platform, or failing that
# for "linux", and optionally native code for Sailfish:
#
#   flutter:
#     plugin:
#       platforms:
#         sailfish:
#           dartPluginClass: MyPluginSailfish   # Dart class with a static registerWith()
#           nativeSources: sailfish             # directory of *.cc files, built into a .so
#           nativeLibrary: my_plugin            # optional, default: the package name
param(
  [Parameter(Position = 0)][ValidateSet('plugins', 'native', 'build', 'help')][string]$Command = 'help',
  [string]$App = '.',
  [string]$Out,
  [string]$FlutterSdk = 'C:\src\flutter-sdk',
  [string]$SdkContainer = 'sailfish-sdk-build-engine_mfisk'
)
$ErrorActionPreference = 'Continue'

switch ($Command) {
  'plugins' {
    $dart = Join-Path $FlutterSdk 'bin\cache\dart-sdk\bin\dart.exe'
    # The flutter tool's own package config supplies the "yaml" and "path" packages.
    $toolPackages = Join-Path $FlutterSdk 'packages\flutter_tools\.dart_tool\package_config.json'
    foreach ($f in $dart, $toolPackages) {
      if (-not (Test-Path $f)) { throw "$f not found; run flutter once so the tool is built." }
    }
    & $dart "--packages=$toolPackages" (Join-Path $PSScriptRoot 'sailfish_plugins.dart') (Resolve-Path $App)
    if ($LASTEXITCODE -ne 0) { throw 'plugin registration failed' }
  }
  'native' {
    if (-not $Out) { throw 'native needs -Out <directory for the .so files>' }
    $report = Join-Path (Resolve-Path $App) '.dart_tool\sailfish\plugins.json'
    if (-not (Test-Path $report)) { throw "$report not found; run the plugins command first." }
    $natives = @((Get-Content $report -Raw | ConvertFrom-Json).native_sailfish)
    if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
    New-Item -ItemType Directory -Force $Out | Out-Null
    if ($natives.Count -eq 0) { Write-Host 'flutter-sailfish: no native plugins'; return }

    $repo = Split-Path -Parent $PSScriptRoot
    $stage = '/home/mersdk/native'
    # Files are copied into the build engine (as root, so the staging area is reset as root),
    # then compiled as the SDK user inside the aarch64 sb2 target.
    docker exec -u root $SdkContainer sh -c "rm -rf $stage && mkdir -p $stage/out && chown mersdk $stage $stage/out" | Out-Null
    docker cp (Join-Path $repo 'embedder\third_party\flutter_client_wrapper') "${SdkContainer}:$stage/wrapper"
    docker cp (Join-Path $repo 'embedder\include') "${SdkContainer}:$stage/include"
    docker cp (Join-Path $PSScriptRoot 'build-native-plugin.sh') "${SdkContainer}:$stage/build-native-plugin.sh"
    foreach ($n in $natives) {
      Write-Host "flutter-sailfish: building native plugin $($n.name) -> lib$($n.library).so"
      docker cp $n.sources "${SdkContainer}:$stage/src-$($n.name)"
      docker exec -u mersdk -e "WRAPPER_DIR=$stage/wrapper" -e "PLUGIN_INCLUDE_DIR=$stage/include" $SdkContainer `
        sh "$stage/build-native-plugin.sh" "$stage/src-$($n.name)" "$stage/out/lib$($n.library).so"
      if ($LASTEXITCODE -ne 0) { throw "building native plugin $($n.name) failed" }
      docker cp "${SdkContainer}:$stage/out/lib$($n.library).so" (Join-Path $Out "lib$($n.library).so")
      if (-not (Test-Path (Join-Path $Out "lib$($n.library).so"))) { throw "lib$($n.library).so was not produced" }
    }
  }
  'build' {
    & (Join-Path $PSScriptRoot 'build-aot-app.ps1') -App $App -FlutterSdk $FlutterSdk
  }
  default {
    Get-Content $PSCommandPath -TotalCount 22 | ForEach-Object { $_ -replace '^# ?', '' }
  }
}
