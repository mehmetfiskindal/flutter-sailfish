#!/bin/bash
# Builds the Flutter engine (release, linux-arm64) and the arm64 gen_snapshot inside an Ubuntu
# 24.04 container, from the Flutter commit pinned in engine/flutter_engine.lock.
#
# This is the sequence of commands used for the pinned version, collected into one script; the
# script itself has not been run from an empty container yet. Expect about 30 GB of sources,
# roughly 60 GB of disk in total, and an hour or more of compiling. 8 GB of RAM is enough with
# JOBS=6 (the final link is the memory hungry step).
#
# Usage (see docs/building.md):
#   docker volume create flutter-engine-src
#   docker run -d --name flutter-engine-build -v flutter-engine-src:/work ubuntu:24.04 sleep infinity
#   docker cp engine/flutter_engine.lock flutter-engine-build:/work/flutter_engine.lock
#   docker cp scripts/build-engine.sh   flutter-engine-build:/work/build-engine.sh
#   docker exec -d flutter-engine-build bash -c "bash /work/build-engine.sh > /work/build.log 2>&1"
#   docker exec flutter-engine-build tail -n 3 /work/build.log      # progress; ends with ENGINE_BUILD_DONE
set -e
export DEBIAN_FRONTEND=noninteractive
LOCK=${LOCK:-/work/flutter_engine.lock}
JOBS=${JOBS:-6}

COMMIT=$(sed -n 's/^flutter_commit=//p' "$LOCK")
[ -n "$COMMIT" ] || { echo "no flutter_commit in $LOCK" >&2; exit 1; }
echo "Flutter commit: $COMMIT"

apt-get update -qq
apt-get install -y -qq git curl python3 python3-venv xz-utils unzip file pkg-config \
  ca-certificates build-essential lsb-release sudo > /dev/null
git config --global --add safe.directory '*'

cd /work
[ -d depot_tools ] || git clone -q https://chromium.googlesource.com/chromium/tools/depot_tools.git
[ -d flutter ] || git clone -q --branch stable --single-branch https://github.com/flutter/flutter.git flutter
cd flutter
git checkout -q "$COMMIT"
cat > .gclient <<'EOF'
solutions = [
  {
    "custom_deps": {},
    "deps_file": "DEPS",
    "managed": False,
    "name": ".",
    "safesync_url": "",
    "url": "https://github.com/flutter/flutter.git",
  },
]
EOF

export PATH=/work/depot_tools:$PATH
export DEPOT_TOOLS_UPDATE=0
gclient sync -D --no-history -j8

cd engine/src
python3 flutter/tools/gn --linux --linux-cpu arm64 --runtime-mode release --embedder-for-target \
  --disable-desktop-embeddings --no-lto --no-rbe --no-goma --no-enable-unittests --no-build-glfw-shell
cd out/linux_release_arm64
/work/flutter/third_party/ninja/ninja -j"$JOBS" libflutter_engine.so clang_x64/gen_snapshot
ls -l libflutter_engine.so clang_x64/gen_snapshot
echo ENGINE_BUILD_DONE
