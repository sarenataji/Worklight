#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
TARGET="$HOME/Applications/Worklight.app"
if pgrep -x Worklight >/dev/null; then
  echo 'Quit Worklight from its menu before updating, then run this script again.'
  exit 1
fi
mkdir -p "$HOME/Applications"
if [ -e "$TARGET" ]; then
  ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)
  if [ "$ID" != 'dev.worklight.mac' ]; then
    echo "A different application exists at $TARGET; installation stopped."
    exit 1
  fi
fi
ditto dist/Worklight.app "$TARGET"
open "$TARGET"
echo "Installed $TARGET"
