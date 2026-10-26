#!/bin/sh
# Builds a native plugin for the aarch64 Sailfish target inside the Sailfish SDK build engine.
#
#   build-native-plugin.sh <plugin source dir> <output .so>
#
# Run it as user mersdk inside the build engine container (flutter-sailfish.ps1 does this).
# sb2 only sees $HOME and /tmp, so everything is copied there first. Every *.cc file in the
# plugin directory is compiled together with Flutter's standard codec.
#
# Where the client wrapper and the plugin header come from:
#   WRAPPER_DIR         embedder/third_party/flutter_client_wrapper
#   PLUGIN_INCLUDE_DIR  embedder/include
# or, instead of both, REPO = the repository root as seen from the container.
set -e
TARGET=${SFOS_TARGET:-SailfishOS-5.1.0.11-aarch64}
SRC=$1
OUT=$2
[ -n "$SRC" ] && [ -n "$OUT" ] || { echo "usage: $0 <plugin source dir> <output .so>" >&2; exit 2; }
if [ -z "$WRAPPER_DIR" ] || [ -z "$PLUGIN_INCLUDE_DIR" ]; then
  : "${REPO:?set WRAPPER_DIR and PLUGIN_INCLUDE_DIR, or REPO}"
  WRAPPER_DIR=${WRAPPER_DIR:-$REPO/embedder/third_party/flutter_client_wrapper}
  PLUGIN_INCLUDE_DIR=${PLUGIN_INCLUDE_DIR:-$REPO/embedder/include}
fi

WORK=$HOME/plugin-build
rm -rf "$WORK" && mkdir -p "$WORK"
cp -r "$SRC" "$WORK/plugin"
cp -r "$WRAPPER_DIR" "$WORK/cw"
cp -r "$PLUGIN_INCLUDE_DIR" "$WORK/include"

cd "$WORK"
sb2 -t "$TARGET" g++ -std=gnu++17 -O2 -fPIC -shared -fvisibility=hidden -Wall -Wno-pessimizing-move \
  -I"$WORK/cw/include" -I"$WORK/cw" -I"$WORK/include" -I"$WORK/plugin" \
  "$WORK"/plugin/*.cc "$WORK/cw/standard_codec.cc" "$WORK/cw/reply_manager.cc" \
  -o "$WORK/plugin.so"
mkdir -p "$(dirname "$OUT")"
cp "$WORK/plugin.so" "$OUT"
file "$OUT"
