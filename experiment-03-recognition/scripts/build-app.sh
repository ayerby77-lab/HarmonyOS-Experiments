#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEVECO_ROOT=${DEVECO_ROOT:-/Applications/DevEco-Studio.app/Contents}
export JAVA_HOME="$DEVECO_ROOT/jbr/Contents/Home"
export DEVECO_SDK_HOME="$DEVECO_ROOT/sdk"
export PATH="$JAVA_HOME/bin:$DEVECO_ROOT/tools/node/bin:$PATH"
cd "$PROJECT_DIR/app"
exec "$DEVECO_ROOT/tools/hvigor/bin/hvigorw" --mode module -p product=default -p module=entry@default assembleHap --no-daemon
