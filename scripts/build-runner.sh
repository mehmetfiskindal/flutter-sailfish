#!/bin/sh
# Builds the runner for the aarch64 Sailfish target inside the SDK build engine.
#
#   build-runner.sh <embedder source dir> <dir with libflutter_engine.so> <output file>
#
# Run as user mersdk in the build engine container (flutter-sailfish.ps1 runner does this).
# sb2 only sees $HOME and /tmp, so the inputs are copied there first. The engine library is
# only needed at link time; at run time the runner finds it in /usr/libexec/flutter-sailfish
# (rpath), where the runtime package installs it.
set -e
TARGET=${SFOS_TARGET:-SailfishOS-5.1.0.11-aarch64}
SRC=$1
LIBDIR=$2
OUT=$3
[ -n "$SRC" ] && [ -n "$LIBDIR" ] && [ -n "$OUT" ] || { echo "usage: $0 <embedder dir> <engine lib dir> <output>" >&2; exit 2; }

WORK=$HOME/runner-build
rm -rf "$WORK" && mkdir -p "$WORK/build"
cp -r "$SRC" "$WORK/embedder"
cp -r "$LIBDIR" "$WORK/lib"

cd "$WORK/build"
ENGINE_LIB_DIR="$WORK/lib" sb2 -t "$TARGET" -R qmake "$WORK/embedder/flutter-runner.pro" 2>&1 | tail -3
ENGINE_LIB_DIR="$WORK/lib" sb2 -t "$TARGET" make -j4 2>&1 | tail -5
mkdir -p "$(dirname "$OUT")"
cp flutter-sailfish-runner "$OUT"
file "$OUT"
