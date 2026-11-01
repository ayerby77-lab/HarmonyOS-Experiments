#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVECO="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}"
export NODE_HOME="$DEVECO/tools/node"
export JAVA_HOME="$DEVECO/jbr/Contents/Home"
export DEVECO_SDK_HOME="$DEVECO/sdk"
export HVIGOR_USER_HOME="$ROOT/.hvigor-cache"
export NODE_PATH="$ROOT/.hvigor-tools"
export PATH="$NODE_HOME/bin:$JAVA_HOME/bin:$PATH"
for required in "$NODE_HOME/bin/node" "$JAVA_HOME/bin/java" "$DEVECO/tools/hvigor/hvigor/bin/hvigor.js"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing tool: $required. Set DEVECO_STUDIO_HOME to DevEco Studio Contents directory." >&2
    exit 1
  fi
done
mkdir -p "$NODE_PATH/@ohos"
ln -sfn "$DEVECO/tools/hvigor/hvigor" "$NODE_PATH/@ohos/hvigor"
ln -sfn "$DEVECO/tools/hvigor/hvigor-ohos-plugin" "$NODE_PATH/@ohos/hvigor-ohos-plugin"
cd "$ROOT"
exec "$NODE_HOME/bin/node" "$DEVECO/tools/hvigor/hvigor/bin/hvigor.js" "$@"
