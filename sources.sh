# sources.sh — the file lists for the two build targets, in exactly one place.
#
# `build.sh` (script path) and `tools/typecheck.sh` must compile the same set of
# files, and the `fancurve-helper` target in `project.yml` (Xcode path) must list the
# same helper sources. They have drifted before, which is how a file can typecheck
# and still not be in the shipped binary.
#
# Sourced with `.` — keep this a plain data file, no side effects.

HELPER_SOURCES=(
    Core/SMC.swift
    Core/SMC+Values.swift
    Core/SMC+FanOwnership.swift
    Core/SMC+Unlock.swift
    Models/FanJSON.swift
    Shared/FanCurveHelperProtocol.swift
    Helper/main.swift
)

APP_SOURCES=(
    Core/*.swift
    Models/*.swift
    ViewModels/*.swift
    Views/*.swift
    App/FanCurveApp.swift
    Shared/FanCurveHelperProtocol.swift
)
