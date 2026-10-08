#!/bin/sh
# Copies OpenTreadmill.app to /Applications and removes the quarantine flag (the build is not notarized).
# Run from the unzipped release folder or from the source tree after `make`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
app="$here/OpenTreadmill.app"
[ -d "$app" ] || app="$here/../build/OpenTreadmill.app"
if [ ! -d "$app" ]; then
    echo "OpenTreadmill.app not found next to this script or in build/" >&2
    exit 1
fi
osascript -e 'tell application id "io.github.anegoda1995.opentreadmill" to quit' >/dev/null 2>&1 || true
# A running copy saves the walk in progress on quit; wait for it, or `open` below fails.
i=0
while pgrep -x OpenTreadmill >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
    sleep 0.5
    i=$((i + 1))
done
rm -rf /Applications/OpenTreadmill.app
cp -R "$app" /Applications/
xattr -dr com.apple.quarantine /Applications/OpenTreadmill.app 2>/dev/null || true
echo "Installed /Applications/OpenTreadmill.app"
open /Applications/OpenTreadmill.app
