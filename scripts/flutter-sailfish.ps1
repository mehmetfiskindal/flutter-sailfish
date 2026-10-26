# flutter-sailfish: small wrapper around the flutter tool for the Sailfish OS target.
#
#   flutter-sailfish.ps1 plugins -App <dir>   generate the plugin registration for an app
#                                             that has already run "flutter pub get"
#   flutter-sailfish.ps1 build   -App <dir>   build an AOT bundle (runs "plugins" itself)
#
# The flutter tool does not know the Sailfish platform, so the plugin registration it would
# write for Linux, Android and so on is produced here by scripts\sailfish_plugins.dart.
# A plugin is picked up when its pubspec.yaml declares a Dart implementation for the
# "sailfish" platform, or failing that for "linux":
#
#   flutter:
#     plugin:
#       platforms:
#         sailfish:
#           dartPluginClass: MyPluginSailfish
param(
  [Parameter(Position = 0)][ValidateSet('plugins', 'build', 'help')][string]$Command = 'help',
  [string]$App = '.',
  [string]$FlutterSdk = 'C:\src\flutter-sdk'
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
  'build' {
    & (Join-Path $PSScriptRoot 'build-aot-app.ps1') -App $App -FlutterSdk $FlutterSdk
  }
  default {
    Get-Content $PSCommandPath -TotalCount 19 | ForEach-Object { $_ -replace '^# ?', '' }
  }
}
