#!/bin/zsh
# Build, install into /Applications (keeping the previous copy in Dist/previous-install) and relaunch.
# Full log: build-and-install.log next to this file.
ROOT_DIR="${0:A:h}"
LOG="$ROOT_DIR/build-and-install.log"
APP="/Applications/Tool Switch Rail.app"
BACKUP="$ROOT_DIR/Dist/previous-install"
{
  echo "=== $(date) ==="
  set -e
  "$ROOT_DIR/build.command"
  echo "[install] backing up current app to $BACKUP"
  if [ -d "$APP" ]; then rm -rf "$BACKUP"; mkdir -p "$BACKUP" && cp -R "$APP" "$BACKUP/"; fi
  killall ToolSwitchRail 2>/dev/null || true
  rm -rf "$APP"
  cp -R "$ROOT_DIR/Dist/Tool Switch Rail.app" "/Applications/"
  /usr/bin/xattr -cr "$APP"
  /usr/bin/codesign --force --deep -s - -r='designated => identifier "app.toolswitchrail.mac"' "$APP"
  codesign --verify --deep --strict "$APP"
  open -a "$APP"
  echo "BUILD_AND_INSTALL_OK"
} 2>&1 | tee "$LOG"
