#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVECO="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}"
HDC="$DEVECO/sdk/default/openharmony/toolchains/hdc"
HAP="${1:-$ROOT/entry/build/default/outputs/default/entry-default-signed.hap}"
if [[ ! -f "$HAP" ]]; then
  echo "Configure signing in DevEco Studio (Project Structure > Signing Configs), build, then run this script with the signed HAP path." >&2
  exit 1
fi
TARGETS=()
while IFS= read -r target; do
  target="${target//$'\r'/}"
  [[ -z "$target" || "$target" == '[Empty]' ]] || TARGETS+=("$target")
done < <("$HDC" list targets)
if [[ ${#TARGETS[@]} -ne 1 ]]; then
  echo "Connect exactly one HarmonyOS emulator/device. Found: ${#TARGETS[@]}" >&2
  exit 1
fi
"$HDC" -t "${TARGETS[0]}" install -r "$HAP"
"$HDC" -t "${TARGETS[0]}" shell aa start -a EntryAbility -b com.example.musicappskeleton
