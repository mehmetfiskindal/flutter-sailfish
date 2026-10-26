# flutter-sailfish: small wrapper around the flutter tool for the Sailfish OS target.
#
#   flutter-sailfish.ps1 plugins -App <dir>                  generate the Dart plugin registration
#                                                            for an app that has run "flutter pub get"
#   flutter-sailfish.ps1 native  -App <dir> -Out <plugins>   build the plugins' native C++ code
#                                                            (needs "plugins" first)
#   flutter-sailfish.ps1 permissions -App <dir> -Out <file> check the Sailjail permissions that
#                                                            plugins and the app ask for and write
#                                                            them to a file (one per line)
#   flutter-sailfish.ps1 build   -App <dir>                  build an AOT bundle: plugins, native
#                                                            plugins, permissions, kernel, assets,
#                                                            libapp.so
#   flutter-sailfish.ps1 runner  [-Out <file>]               build the runner for aarch64
#   flutter-sailfish.ps1 package [-Out <dir>]                build the runtime and app RPMs
#
# Order for a fresh checkout: build the engine (docs\engine-build.md), scripts\export-engine.ps1,
# then "runner", "build -App <dir>" and "package". See docs\building.md.
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
#           sailjailPermissions: [Internet]     # optional, added to the app's desktop entry
param(
  [Parameter(Position = 0)][ValidateSet('plugins', 'native', 'permissions', 'build', 'runner', 'package', 'help')][string]$Command = 'help',
  [string]$App = '.',
  [string]$Out,
  [string]$FlutterSdk = 'C:\src\flutter-sdk',
  [string]$SdkContainer,
  [string]$SdkTarget = 'SailfishOS-5.1.0.11-aarch64',
  [string]$EngineDir
)
$ErrorActionPreference = 'Continue'

# The Sailfish SDK's build engine runs as a Docker container named
# sailfish-sdk-build-engine[_<user>]; use the running one unless -SdkContainer is given.
function Resolve-SdkContainer {
  if ($script:SdkContainer) { return }
  $found = @(docker ps --filter 'name=sailfish-sdk-build-engine' --format '{{.Names}}')
  if ($found.Count -eq 0) { throw 'no running sailfish-sdk-build-engine container; start the Sailfish SDK or pass -SdkContainer' }
  $script:SdkContainer = $found[0]
}
if ($Command -in 'native', 'permissions', 'runner', 'package') { Resolve-SdkContainer }

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
  'permissions' {
    if (-not $Out) { throw 'permissions needs -Out <file to write the permission list to>' }
    $report = Join-Path (Resolve-Path $App) '.dart_tool\sailfish\plugins.json'
    if (-not (Test-Path $report)) { throw "$report not found; run the plugins command first." }
    $json = Get-Content $report -Raw | ConvertFrom-Json
    $wanted = @($json.sailjail_permissions | Where-Object { $_ })

    # Sailjail refuses to start an app that names a permission it does not know, so check the
    # names against the permission files of the SDK target.
    $listing = docker exec -u mersdk $SdkContainer sh -c "ls /srv/mer/targets/$SdkTarget/etc/sailjail/permissions"
    $valid = @($listing | Where-Object { $_ -like '*.permission' } | ForEach-Object { $_ -replace '\.permission$', '' })
    # Permissions that the runtime package itself installs (packaging\sailjail-permissions).
    $own = Join-Path (Split-Path -Parent $PSScriptRoot) 'packaging\sailjail-permissions'
    if (Test-Path $own) { $valid += @(Get-ChildItem $own -Filter '*.permission' | ForEach-Object { $_.BaseName }) }
    if ($valid.Count -eq 0) { Write-Warning 'could not read the Sailjail permission names; not validating' }
    $unknown = if ($valid.Count -gt 0) { @($wanted | Where-Object { $_ -notin $valid }) } else { @() }
    if ($unknown.Count -gt 0) {
      throw "unknown Sailjail permission(s): $($unknown -join ', '). Known: $($valid -join ', ')"
    }
    # Written without a BOM, one name per line; an empty file means "no permissions".
    [IO.File]::WriteAllText($Out, (($wanted | ForEach-Object { "$_`n" }) -join ''), (New-Object Text.UTF8Encoding $false))
    foreach ($p in $wanted) {
      Write-Host ("flutter-sailfish: permission {0} <- {1}" -f $p, (@($json.sailjail_permission_sources.$p) -join ', '))
    }
    if ($wanted.Count -eq 0) { Write-Host 'flutter-sailfish: no Sailjail permissions requested' }
  }
  'runner' {
    # Builds the runner for aarch64. Needs dist\aot\engine\libflutter_engine.so
    # (scripts\export-engine.ps1) or -EngineDir with that file.
    $repo = Split-Path -Parent $PSScriptRoot
    $libDir = if ($EngineDir) { $EngineDir } else { Join-Path $repo 'dist\aot\engine' }
    $lib = Join-Path $libDir 'libflutter_engine.so'
    if (-not (Test-Path $lib)) { throw "$lib not found; run scripts\export-engine.ps1 first." }
    if (-not $Out) { $Out = Join-Path $repo 'dist\aot\app\flutter-sailfish-runner' }
    $stage = '/home/mersdk/runner-stage'
    docker exec -u root $SdkContainer sh -c "rm -rf $stage && mkdir -p $stage/lib && chown -R mersdk $stage" | Out-Null
    docker cp (Join-Path $repo 'embedder') "${SdkContainer}:$stage/embedder"
    docker cp $lib "${SdkContainer}:$stage/lib/libflutter_engine.so"
    docker cp (Join-Path $PSScriptRoot 'build-runner.sh') "${SdkContainer}:$stage/build-runner.sh"
    docker exec -u mersdk -e "SFOS_TARGET=$SdkTarget" $SdkContainer `
      sh "$stage/build-runner.sh" "$stage/embedder" "$stage/lib" "$stage/flutter-sailfish-runner"
    if ($LASTEXITCODE -ne 0) { throw 'building the runner failed' }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Out) | Out-Null
    docker cp "${SdkContainer}:$stage/flutter-sailfish-runner" $Out
    Write-Host "flutter-sailfish: runner written to $Out"
  }
  'package' {
    # Builds the runtime and app RPMs from dist\aot\app (the output of "build" and "runner")
    # into dist\rpm, or -Out.
    $repo = Split-Path -Parent $PSScriptRoot
    $dist = Join-Path $repo 'dist\aot\app'
    $engine = Join-Path $repo 'dist\aot\engine'
    foreach ($f in 'libflutter_engine.so', 'icudtl.dat') {
      if (Test-Path (Join-Path $engine $f)) { Copy-Item (Join-Path $engine $f) $dist -Force }
    }
    # License texts that go into the packages (/usr/share/licenses/<package>/).
    $licenses = Join-Path $dist 'licenses'
    if (Test-Path $licenses) { Remove-Item $licenses -Recurse -Force }
    New-Item -ItemType Directory -Force $licenses | Out-Null
    Copy-Item (Join-Path $repo 'LICENSE') (Join-Path $licenses 'LICENSE')
    Copy-Item (Join-Path $repo 'THIRD_PARTY_NOTICES.md') $licenses
    Copy-Item (Join-Path $repo 'embedder\third_party\flutter_engine\LICENSE') (Join-Path $licenses 'LICENSE.flutter')
    $engineLicense = Join-Path $engine 'LICENSE.engine'
    if (-not (Test-Path $engineLicense)) { throw "$engineLicense missing; run scripts\export-engine.ps1 first." }
    Copy-Item $engineLicense $licenses
    foreach ($f in 'flutter-sailfish-runner', 'libflutter_engine.so', 'icudtl.dat', 'libapp.so', 'flutter_assets') {
      if (-not (Test-Path (Join-Path $dist $f))) { throw "$f missing in $dist; run runner, export-engine and build first." }
    }
    if (-not $Out) { $Out = Join-Path $repo 'dist\rpm' }
    $stage = '/home/mersdk/package-stage'
    docker exec -u root $SdkContainer sh -c "rm -rf $stage && mkdir -p $stage/dist/aot $stage/scripts && chown -R mersdk $stage" | Out-Null
    docker cp $dist "${SdkContainer}:$stage/dist/aot/app"
    docker cp (Join-Path $repo 'packaging') "${SdkContainer}:$stage/packaging"
    docker cp (Join-Path $PSScriptRoot 'build-rpm.sh') "${SdkContainer}:$stage/scripts/build-rpm.sh"
    docker exec -u mersdk -e "REPO=$stage" -e "SFOS_TARGET=$SdkTarget" $SdkContainer sh "$stage/scripts/build-rpm.sh"
    if ($LASTEXITCODE -ne 0) { throw 'building the RPMs failed' }
    New-Item -ItemType Directory -Force $Out | Out-Null
    $rpms = @(docker exec -u mersdk $SdkContainer sh -c 'ls /home/mersdk/rpmtop/RPMS/aarch64')
    foreach ($rpm in $rpms) {
      docker cp "${SdkContainer}:/home/mersdk/rpmtop/RPMS/aarch64/$rpm" (Join-Path $Out $rpm)
      Write-Host "flutter-sailfish: $(Join-Path $Out $rpm)"
    }
  }
  'build' {
    & (Join-Path $PSScriptRoot 'build-aot-app.ps1') -App $App -FlutterSdk $FlutterSdk
  }
  default {
    Get-Content $PSCommandPath -TotalCount 36 | ForEach-Object { $_ -replace '^# ?', '' }
  }
}
