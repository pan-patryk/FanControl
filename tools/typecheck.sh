#!/bin/bash
# Fast type-check only (no codegen, no signing, no packaging).
#   tools/typecheck.sh          -> app + helper
#   tools/typecheck.sh app      -> app targets
#   tools/typecheck.sh helper   -> helper targets
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macosx${MACOS_DEPLOYMENT_TARGET:-13.0}"
WHAT="${1:-all}"
status=0

# Same lists the build uses — they live in sources.sh so a typecheck can never pass on
# a file the shipped binary does not contain.
# shellcheck source=../sources.sh
. "$(dirname "$0")/../sources.sh"

if [ "$WHAT" = all ] || [ "$WHAT" = app ]; then
    echo "--- typecheck app ---"
    swiftc -typecheck -parse-as-library -target "$TARGET" -sdk "$SDK" \
        -framework Cocoa -framework SwiftUI -framework IOKit "${APP_SOURCES[@]}" || status=1
fi
if [ "$WHAT" = all ] || [ "$WHAT" = helper ]; then
    echo "--- typecheck helper ---"
    swiftc -typecheck -target "$TARGET" -sdk "$SDK" "${HELPER_SOURCES[@]}" || status=1
fi
[ $status -eq 0 ] && echo "TYPECHECK OK"
exit $status
