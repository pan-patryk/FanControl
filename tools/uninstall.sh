#!/bin/bash
#
# Remove every privilege and every trace this app has installed.
#
# What the app actually holds, and where:
#
#   1. A root launchd daemon.  This is the real privilege: a setuid-root-free way to
#      write the SMC. It lives outside the bundle so a rebuild can't break it, which
#      also means removing the app does NOT remove it. The daemon is identified
#      by /Library/fancurve/fancurve-helper and the com.local.fancurve.app.helper
#      launchd label.
#   2. A setuid helper inside the bundle, if "Use bundled helper instead" was ever
#      clicked (chown root:wheel + chmod +s on Contents/MacOS/fancurve-helper).
#   3. A login item registered through SMAppService.
#   4. Saved state: a UserDefaults domain and an Application Support history file.
#
# No TCC privacy permission is involved — the app requests no camera, microphone,
# screen recording, accessibility, contacts or full-disk access. `sudo tccutil` is
# therefore not part of this; the daemon above is the whole attack surface.
#
# Usage:
#   sudo ./tools/uninstall.sh            # remove privileges + app + state
#   sudo ./tools/uninstall.sh --keep-logs # leave the unified-log record alone (default)
#   ./tools/uninstall.sh --privileges-only # drop the daemon, keep the app and settings
#
set -euo pipefail

# The identifiers the app is installed under, so one pass cleans everything it
# owns: the bundle id (the app identity) and the daemon label. The source, the
# bundle id and the install paths all share the `fancurve` name, so these two
# lines cover every privilege the app can hold. Add a line here if the identity
# ever changes.
IDENTIFIERS=(
    "com.local.fancurve.app"
    "com.local.fancurve.app.helper"
)
DAEMON_DIRS=(/Library/fancurve)
APP_NAMES=(FanCurve)
STATE_DIRS=("FanCurve")

PRIVILEGES_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --privileges-only) PRIVILEGES_ONLY=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root: it removes a launchd daemon from /Library." >&2
    echo "    sudo ./tools/uninstall.sh" >&2
    exit 1
fi

echo "== 1. stop and remove the launchd jobs =="
# bootout unloads the job (and kills the process). It is idempotent: a label that is
# not loaded is not an error worth stopping for.
for id in "${IDENTIFIERS[@]}"; do
    if launchctl bootout "system/$id" 2>/dev/null; then
        echo "   booted out system/$id"
    fi
done

echo "== 2. remove the installed daemon binaries and plists =="
for dir in "${DAEMON_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        rm -rf "$dir"
        echo "   removed $dir"
    fi
done
for id in "${IDENTIFIERS[@]}"; do
    plist="/Library/LaunchDaemons/$id.plist"
    if [ -f "$plist" ]; then
        rm -f "$plist"
        echo "   removed $plist"
    fi
done
# Any setuid helper left behind in a bundle we are about to delete, or in a bundle that
# was already deleted. A stray setuid-root binary is the worst thing to leave behind.
echo "== 3. remove any setuid helper =="
for base in /Applications "$HOME/Applications"; do
    [ -d "$base" ] || continue
    # -maxdepth is a global option and must precede the expression.
    find "$base" -maxdepth 4 -name 'fancurve-helper' \
        2>/dev/null | while read -r h; do
        if [ -u "$h" ]; then
            chmod u-s "$h"
            echo "   cleared setuid bit on $h"
        fi
    done
done

if [ "$PRIVILEGES_ONLY" -eq 1 ]; then
    echo
    echo "Privileges removed. The app and its settings were left in place."
    exit 0
fi

echo "== 4. unregister the login item =="
# SMAppService registration is per-user and lives in the loginitems database; `sfltool`
# and the Login Items pane are the only supported readers, and there is no CLI
# de-registration. Removing the app bundle plus its domain is what actually clears it:
# launchd drops a job whose program path no longer exists.
for name in "${APP_NAMES[@]}"; do
    for base in /Applications "$HOME/Applications"; do
        if [ -d "$base/$name.app" ]; then
            rm -rf "$base/$name.app"
            echo "   removed $base/$name.app"
        fi
    done
done

echo "== 5. remove saved state =="
for id in "${IDENTIFIERS[@]}"; do
    for user_home in "$HOME" /Users/*; do
        [ -d "$user_home" ] || continue
        pref="$user_home/Library/Preferences/$id.plist"
        if [ -f "$pref" ]; then
            rm -f "$pref"
            echo "   removed $pref"
        fi
    done
done
# The preferences daemon caches each domain in memory; without this the deleted files
# come back on the next `defaults read`.
defaults delete com.local.fancurve.app 2>/dev/null || true
killall cfprefsd 2>/dev/null || true

for name in "${STATE_DIRS[@]}"; do
    for user_home in "$HOME" /Users/*; do
        [ -d "$user_home" ] || continue
        d="$user_home/Library/Application Support/$name"
        if [ -d "$d" ]; then
            rm -rf "$d"
            echo "   removed $d"
        fi
    done
done

echo
echo "Done. Verify with:"
echo "   ls /Library/fancurve /Library/LaunchDaemons | grep -i -E 'fan|curve'"
echo "   ps aux | grep -i 'fancurve' | grep -v grep"
echo "   launchctl list | grep -i -E 'fan|curve'"
