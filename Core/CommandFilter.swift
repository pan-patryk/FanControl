import Foundation

/// The command-side limiter: one pipeline, one set of semantics.
///
/// Four stages, in order — temperature hysteresis → demand deadband + cooling
/// confirmation → slew-rate limiter (time-based, not tick-based) → emergency bypass.
/// Every tuning knob in the UI maps onto exactly one of these stages, and every
/// engine decision goes through all of them, so a slider always means the same thing.
/// A second, weaker copy of the pipeline anywhere else would make the knobs
/// ambiguous depending on which mode happened to be active.
struct CommandFilter {
    // Tunables, mirrored from the persisted "fan response" settings.
    /// Percent-of-range per second, on the way up.
    var riseRate: Double = 6
    /// Percent-of-range per second, on the way down.
    var fallRate: Double = 3
    /// °C a falling temperature must give back before demand is allowed to drop.
    var hysteresisC: Double = 5
    /// % demand change ignored outright.
    var minChangePercent: Double = 4
    /// Seconds a lower demand must hold before it is granted.
    var confirmationSeconds: Double = 8

    /// Safety limit: a command at or above this bypasses the limiter, because the
    /// whole point of the controller is to react to a thermal excursion.
    static let emergencyBypassPercent = 95.0
    /// Below this the engines hand the fans back to macOS.
    static let releaseToAutoPercent = 0.5

    // Accumulated state.
    private var heldTemperature: [TemperatureSensor: Double] = [:]
    private var commandedPercent: Double?
    private var lastEvaluation: Date?
    private var pendingLowerTarget: Double?
    private var pendingSince: Date?

    mutating func reset() {
        heldTemperature.removeAll()
        commandedPercent = nil
        lastEvaluation = nil
        pendingLowerTarget = nil
        pendingSince = nil
    }

    /// Temperature hysteresis, applied **once** per sensor for the whole pipeline.
    ///
    /// Rises pass straight through (a hotter sensor is always believed); a fall only
    /// counts once it exceeds `hysteresisC`, so sensor noise near a knot cannot make
    /// the fans saw back and forth.
    mutating func temperature(_ measured: Double, sensor: TemperatureSensor) -> Double {
        guard let held = heldTemperature[sensor] else {
            heldTemperature[sensor] = measured
            return measured
        }
        if measured >= held || measured <= held - max(hysteresisC, 0) {
            heldTemperature[sensor] = measured
            return measured
        }
        return held
    }

    /// Maps a desired demand (0…100 % of the usable fan range) to the command that
    /// may actually be issued this tick.
    mutating func percent(desired: Double, now: Date) -> Double {
        let target = min(max(desired, 0), 100)
        defer { lastEvaluation = now }

        guard let previous = commandedPercent else {
            // First demand is applied immediately: the conservative choice.
            commandedPercent = target
            clearPending()
            return target
        }

        // Never slow down a safety request.
        if target >= Self.emergencyBypassPercent {
            commandedPercent = target
            clearPending()
            return target
        }

        let change = target - previous
        var settled = previous

        if change >= 0 {
            // A renewed demand cancels a pending cooling release.
            clearPending()
            if change >= max(minChangePercent, 0) { settled = target }
        } else {
            // Falling demand must be both big enough and sustained.
            if let pending = pendingLowerTarget, target > pending {
                // The recovery reversed itself before being granted: restart the clock.
                pendingLowerTarget = target
                pendingSince = now
            }
            if abs(change) >= max(minChangePercent, 0) {
                if max(confirmationSeconds, 0) <= 0 {
                    settled = target
                    clearPending()
                } else if pendingLowerTarget == nil {
                    pendingLowerTarget = target
                    pendingSince = now
                } else if let since = pendingSince, now.timeIntervalSince(since) >= confirmationSeconds {
                    // The demand has held: grant it AND keep the confirmed level.
                    // Clearing it here would re-arm the confirmation
                    // clock on every intermediate step the limiter produced, so the
                    // effective fall rate became `fall / (1 + confirmationSeconds)` —
                    // 3 %/s with the defaults measures as 0.34 %/s, and the "Calm"
                    // preset as 0.05 %/s. Rise is unaffected, which is why it reads
                    // as "cooling is just slow" rather than as a bug. The confirmed
                    // level stays until the demand rises again (`target > pending`
                    // above restarts the clock) or the limiter catches up
                    // (`change >= 0` clears it).
                    settled = min(pendingLowerTarget ?? target, target)
                }
            }
        }

        // Slew-rate limit, in percent-of-range per **second**.
        //
        // The ramp is integrated over *elapsed time*, not applied per tick, so a
        // stalled or fast tick cannot change the physics. A per-tick factor would
        // make the effective ramp depend on the polling interval.
        let elapsed = max(now.timeIntervalSince(lastEvaluation ?? now), 0.01)
        let delta = settled - previous
        let maximumChange = max(delta >= 0 ? riseRate : fallRate, 0.1) * elapsed
        let limited = previous + min(max(delta, -maximumChange), maximumChange)

        commandedPercent = limited
        return limited
    }

    private mutating func clearPending() {
        pendingLowerTarget = nil
        pendingSince = nil
    }
}
