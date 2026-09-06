#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h}"
APP="$ROOT_DIR/Dist/Tool Switch Rail.app"
if [[ ! -d "$APP" ]]; then
  echo "尚未构建，先运行 build.command..."
  "$ROOT_DIR/build.command"
fi
open "$APP"
