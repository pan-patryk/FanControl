#!/bin/bash
#
# One-command dev flow: kill any running/stale copies, build, install, launch.
# Guarantees the app you end up with is exactly the current source.
#
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Stopping running copies"
pkill -x FanCurve 2>/dev/null || true
pkill -f "DerivedData/FanCurve" 2>/dev/null || true
sleep 1

echo "==> Building"
./build.sh > /tmp/fancurve-build.log 2>&1 || {
    echo "Build failed — last 20 lines:"
    tail -20 /tmp/fancurve-build.log
    exit 1
}

echo "==> Installing to /Applications"
rm -rf /Applications/FanCurve.app
cp -R FanCurve.app /Applications/

echo "==> Launching"
open /Applications/FanCurve.app
echo "Done. (full build log: /tmp/fancurve-build.log)"
