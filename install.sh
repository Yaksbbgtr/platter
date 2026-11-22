#!/bin/bash
# Builds Platter, installs it to ~/Applications and restarts it cleanly.
# Replacing the app alone isn't enough: macOS keeps the old widget process, and may register the
# copies in build/ as well. Either one makes every widget update fail ("Bundle version did not match").
set -euo pipefail
cd "$(dirname "$0")"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DEST="$HOME/Applications/Platter.app"
APPEX=Contents/PlugIns/PlatterWidget.appex

# --no-build installs the app that is already in build/.
[ "${1:-}" = "--no-build" ] || ./build.sh

pkill -x Platter || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Platter >/dev/null || break; sleep 0.3; done
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/Platter.app "$DEST"

# Only the installed copy may be registered.
for copy in "$PWD/build/Platter.app" "$PWD/build/DerivedData/Build/Products/Release/Platter.app"; do
  pluginkit -r "$copy/$APPEX" 2>/dev/null || true
  "$LSREGISTER" -u "$copy" >/dev/null 2>&1 || true
  rm -rf "$copy"      # merely running a leftover copy registers it again
done
"$LSREGISTER" -f "$DEST"
pluginkit -a "$DEST/$APPEX"

pkill -x PlatterWidget || true    # the old widget process
sleep 1
killall chronod 2>/dev/null || true   # macOS's widget service; it restarts itself and re-reads the widget
sleep 2
open -g "$DEST"
echo "Installed: $DEST"
