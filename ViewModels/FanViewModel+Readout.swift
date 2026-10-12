import Foundation

// Everything the UI *reads* about the control state, derived from the model's own
// intent rather than from the SMC's opinion. The SMC's `mode` byte is not a pin
// signal: engine-driven fans are in forced mode by definition, so reading
// `mode == 1` as user input would report every curve command back to the user as
// their own manual override.

extension FanViewModel {

    // MARK: - Header: who has control, and the thermal picture

    /// Honest control-state text, derived from `controlMode` + `userPinnedFanIDs`.
    var controlState: (title: String, detail: String) {
        let pins = userPinnedFanIDs.filter { id in fans.contains(where: { $0.id == id }) }
        // Only the app's own commanded value counts as "in control". The SMC's
        // target is thermalmonitord's output when the curve is NOT commanding
        // (armed-but-released, or just after a wake reconcile) — reading it as the
        // curve's demand would claim the curve was in control while the fans were
        // running macOS's own speed.
        let commanded = lastCommandedPercent ?? rawStatus.flatMap { highestTargetPercent(from: $0.fans) }

        switch controlMode {
        case .macOS:
            if !pins.isEmpty {
                return (L10n.text("Manual override"),
                        L10n.format("%d fan(s) pinned by you — macOS runs the rest", pins.count))
            }
            return (L10n.text("macOS control"), L10n.text("running stock macOS temperature settings"))
        case .curve:
            let curve = activeCurve
            let temp = controlTemperature(for: curve?.sensor ?? .cpu)
            let detail: String
            if wasEngineApplied, let pct = commanded, let temp {
                detail = L10n.format("%d%% at %d°C — curve in control", Int(pct.rounded()), Int(temp.rounded()))
            } else if let temp {
                detail = L10n.format("curve armed at %d°C — macOS owns the fans", Int(temp.rounded()))
            } else {
                detail = L10n.text("curve armed — waiting for a valid reading")
            }
            // The header names what the user selected: the profile while one is
            // active, otherwise the curve it is sampling (a forked built-in shape,
            // or "No profile"). Both hosts read this, so the panel and the window
            // cannot disagree about the name.
            let title = activeProfileName ?? curve?.name ?? L10n.text("Curve")
            return (title,
                    pins.isEmpty ? detail : detail + " · " + L10n.format("%d pinned", pins.count))
        }
    }

    /// A single "how owned is this fan" answer for the UI, so no section can tell
    /// the user their engine-driven fans are pinned by them.
    func ownershipText() -> String? {
        let pins = userPinnedFanIDs.filter { id in fans.contains(where: { $0.id == id }) }
        guard !pins.isEmpty else { return nil }
        return L10n.format("%d fan(s) pinned by you — the engine leaves them alone. Press Auto on a fan to release it.", pins.count)
    }

    /// Live operating point for the chart marker, from the **validated control**
    /// temperature — not the published mirror — so the dot is correct whether or
    /// not the window is open.
    var currentCurvePoint: (x: Double, y: Double)? {
        guard let curve = activeCurve, let temp = controlTemperature(for: curve.sensor) else { return nil }
        return (temp, curve.sample(temp: temp))
    }

    // MARK: - Menu-bar icon state

    /// The tray icon reflects who owns the fans right now — the one live cue the
    /// user gets without opening the panel. A warning means no privileged channel:
    /// reads still work, every *command* is refused, so the curve is armed but
    /// cannot write.
    var menuBarIcon: String {
        guard canWrite else { return "exclamationmark.triangle" }
        switch controlMode {
        case .macOS: return "fanblades"
        case .curve: return "chart.line.uptrend.xyaxis"
        }
    }

    // MARK: - Visibility gate

    /// Something is actually on screen. `menuPanelIsVisible` only looks at the
    /// menu-bar panel, so with ONLY the settings window open (panel closed) the
    /// mirror gate would stay shut — the window would show frozen fans, temperatures
    /// and history while the user was staring at it. Views that animate from
    /// canonical (unpublished) state — the curve editor's operating dot — gate on
    /// this too, so a hidden panel does no per-second work at all.
    var isUIVisible: Bool { wantsLiveUI && (isWindowOpen || menuPanelIsVisible) }
}
