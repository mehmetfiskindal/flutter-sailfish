#!/bin/sh
# Builds a native plugin for the aarch64 Sailfish target inside the Sailfish SDK build engine.
#
#   build-native-plugin.sh <plugin source dir> <output .so>
#
# Run it as user mersdk inside the build engine container. sb2 only sees $HOME and /tmp,
# so the sources are copied there first. Every *.cc file in the plugin directory is compiled
# together with Flutter's standard codec from embedder/third_party/flutter_client_wrapper.
set -e
TARGET=${SFOS_TARGET:-SailfishOS-5.1.0.11-aarch64}
REPO=${REPO:?set REPO to the repository root as seen from the container}
SRC=$1
OUT=$2

WORK=$HOME/plugin-build
rm -rf "$WORK" && mkdir -p "$WORK"
cp -r "$SRC" "$WORK/plugin"
cp -r "$REPO/embedder/third_party/flutter_client_wrapper" "$WORK/cw"
cp -r "$REPO/embedder/include" "$WORK/include"

cd "$WORK"
sb2 -t "$TARGET" g++ -std=gnu++17 -O2 -fPIC -shared -fvisibility=hidden -Wall -Wno-pessimizing-move \
  -I"$WORK/cw/include" -I"$WORK/cw" -I"$WORK/include" \
  "$WORK"/plugin/*.cc "$WORK/cw/standard_codec.cc" "$WORK/cw/reply_manager.cc" \
  -o "$WORK/plugin.so"
cp "$WORK/plugin.so" "$OUT"
file "$OUT"
