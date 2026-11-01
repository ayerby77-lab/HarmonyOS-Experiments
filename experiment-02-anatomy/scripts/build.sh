#!/bin/bash
set -eu
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVECO_DIR="${DEVECO_DIR:-/Applications/DevEco-Studio.app/Contents}"
export NODE_HOME="$DEVECO_DIR/tools/node"
export DEVECO_SDK_HOME="$DEVECO_DIR/sdk"
export JAVA_HOME="$DEVECO_DIR/jbr/Contents/Home"
export PATH="$NODE_HOME/bin:$PATH"
# Hvigor rejects Chinese characters in the project path; compile an isolated copy.
BUILD_DIR="$(mktemp -d /tmp/anatomy-learning-build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
python3 - "$PROJECT_DIR" "$BUILD_DIR" <<'PY'
import shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2], dirs_exist_ok=True,
    ignore=shutil.ignore_patterns('.git', '.omx', '.hvigor', 'build', 'dist', 'node_modules', 'oh_modules'))
PY
cd "$BUILD_DIR"
"$DEVECO_DIR/tools/hvigor/bin/hvigorw" --mode module -p product=default -p module=entry@default assembleHap --no-daemon
mkdir -p "$PROJECT_DIR/dist"
cp entry/build/default/outputs/default/*.hap "$PROJECT_DIR/dist/"
echo "HAP: $PROJECT_DIR/dist/"
