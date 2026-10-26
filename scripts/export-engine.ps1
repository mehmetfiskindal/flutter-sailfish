# Collects what the Sailfish build needs from the engine build into dist\aot\engine:
#   libflutter_engine.so   the arm64 release engine           (from the engine build container)
#   gen_snapshot           x64 Linux tool that targets arm64  (from the engine build container)
#   icudtl.dat             ICU data, from Flutter's artifacts for the pinned engine version
#   LICENSE.engine         the engine's license text, which must ship with libflutter_engine.so
#
# The engine itself is built as described in docs\engine-build.md (container "flutter-engine-build").
param(
  [string]$Container = 'flutter-engine-build',
  [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\aot\engine'),
  [string]$EngineOut = '/work/flutter/engine/src/out/linux_release_arm64',
  [string]$EngineLicense = '/work/flutter/engine/src/flutter/sky/packages/sky_engine/LICENSE'
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force $OutDir | Out-Null

docker cp "${Container}:$EngineOut/libflutter_engine.so" (Join-Path $OutDir 'libflutter_engine.so')
docker cp "${Container}:$EngineOut/clang_x64/gen_snapshot" (Join-Path $OutDir 'gen_snapshot')
# The engine's aggregated license text (it covers the third-party code inside the engine); it
# has to accompany any package that contains libflutter_engine.so.
docker cp "${Container}:$EngineLicense" (Join-Path $OutDir 'LICENSE.engine')
foreach ($f in 'libflutter_engine.so', 'gen_snapshot', 'LICENSE.engine') {
  if (-not (Test-Path (Join-Path $OutDir $f))) { throw "$f was not exported; is the engine built in $Container?" }
}

# icudtl.dat: the engine version is pinned in engine\flutter_engine.lock.
$lock = Get-Content (Join-Path $root 'engine\flutter_engine.lock') | Where-Object { $_ -match '^engine_version=' }
$version = ($lock -split '=')[1].Trim()
$zip = Join-Path $env:TEMP "flutter-artifacts-$version.zip"
$url = "https://storage.googleapis.com/flutter_infra_release/flutter/$version/linux-arm64/artifacts.zip"
Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
  [IO.Compression.ZipFileExtensions]::ExtractToFile($archive.GetEntry('icudtl.dat'), (Join-Path $OutDir 'icudtl.dat'), $true)
} finally {
  $archive.Dispose()
}
Get-ChildItem $OutDir | Select-Object Name, Length
