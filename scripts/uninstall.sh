#!/bin/sh
# Removes OpenTreadmill.app and resets its Bluetooth permission. Your workout history in
# ~/Library/Application Support/OpenTreadmill stays unless you pass --purge.
set -eu
id=io.github.anegoda1995.opentreadmill
osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
rm -rf /Applications/OpenTreadmill.app
tccutil reset BluetoothAlways "$id" >/dev/null 2>&1 || true
if [ "${1:-}" = "--purge" ]; then
    rm -rf "$HOME/Library/Application Support/OpenTreadmill"
    defaults delete "$id" >/dev/null 2>&1 || true
    echo "Removed the app, its settings and its workout history"
else
    echo "Removed the app. History kept in ~/Library/Application Support/OpenTreadmill (use --purge to delete it)"
fi
