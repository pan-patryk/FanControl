#!/bin/bash
# Model-layer harness: compiles the Foundation-only sources and runs the checks.
# Deliberately independent of the app build (no codegen, no signing) so it stays a
# two-second regression net for curve / sensor / history behaviour.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macosx${MACOS_DEPLOYMENT_TARGET:-13.0}"
BIN="$(mktemp -d)/model-harness"

xcrun swiftc -O -target "$TARGET" -sdk "$SDK" \
    tools/model-harness/main.swift \
    Models/TemperatureSensor.swift \
    Models/TempRecord.swift \
    Models/FanCurve.swift \
    Models/FanResponsePreset.swift \
    Models/FanProfile.swift \
    Core/SensorGate.swift \
    Core/CommandFilter.swift \
    Core/Localization.swift \
    -o "$BIN" || exit 1

"$BIN"
