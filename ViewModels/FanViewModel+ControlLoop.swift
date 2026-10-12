import Foundation
import UserNotifications

// The engine: turn a validated temperature into a fan command, and only notify the
// user about a demand that is worth interrupting them for.
//
// One pipeline, one tail. Every knob in the tuning UI feeds the same
// `CommandFilter`, and every decision ends in the same `command(to:now:sensorLabel:)`
// call, so a slider always means the same thing regardless of which mode is active.

extension FanViewModel {

    // MARK: - Engine switching

    /// The one place engine switching has side effects. Turning an engine off hands
    /// *its* fans back to macOS without disturbing the user's pins.
    func engineTransition(from previous: ControlMode, to next: ControlMode) {
        guard previous != next else { return }
        commandFilter.reset()
        lastCommandedPercent = nil
        if previous != .macOS, wasEngineApplied { releaseOwnedFans() }
        wasEngineApplied = false
        currentCommandedPercent = nil
        switch next {
        case .macOS:
            notifyEngineDisengaged()
        case .curve:
            evaluateControlLoop(now: Date(), reason: "mode")
        }
    }

    /// Copy the tuning knobs into the limiter. Deliberately does **not** reset
    /// accumulated filter state: re-tuning mid-run should change the rates, not throw
    /// away the held temperatures and slew position (that is where a write storm
    /// comes from).
    func syncCommandFilter() {
        commandFilter.riseRate = max(maximumCommandRiseRatePercentPerSecond, 0.1)
        commandFilter.fallRate = max(maximumCommandFallRatePercentPerSecond, 0.1)
        commandFilter.hysteresisC = max(coolingTemperatureHysteresis, 0)
        commandFilter.minChangePercent = max(minimumCommandChangePercent, 0)
        commandFilter.confirmationSeconds = max(coolingConfirmationSeconds, 0)
    }

    func loadResponseSettings() {
        let defaults = UserDefaults.standard
        for (key, assign) in [
            (Keys.rise, { (v: Double) in self.maximumCommandRiseRatePercentPerSecond = v }),
            (Keys.fall, { (v: Double) in self.maximumCommandFallRatePercentPerSecond = v }),
            (Keys.hysteresis, { (v: Double) in self.coolingTemperatureHysteresis = v }),
            (Keys.minChange, { (v: Double) in self.minimumCommandChangePercent = v }),
            (Keys.confirmation, { (v: Double) in self.coolingConfirmationSeconds = v }),
        ] {
            guard defaults.object(forKey: key) != nil else { continue }
            assign(defaults.double(forKey: key))
        }
    }

    // MARK: - The loop

    func evaluateControlLoop(now: Date, reason: String = "poll") {
        switch controlMode {
        case .curve: evaluateCurves(now: now)
        case .macOS: releaseIfHeld()
        }
    }

    /// macOS owns the fans again (engine switched off, or demand fell to zero).
    func releaseIfHeld() {
        guard wasEngineApplied else { return }
        releaseOwnedFans()
        notifyEngineDisengaged()
        wasEngineApplied = false
        lastCommandedPercent = nil
        setCurrentCommanded(nil)
    }

    func evaluateCurves(now: Date) {
        guard let curve = activeCurve else {
            if wasEngineApplied { notifyEngineDisengaged() }
            wasEngineApplied = false
            setCurrentCommanded(nil)
            return
        }
        guard let reading = controlTemps[curve.sensor] else {
            // No valid reading yet — command nothing rather than sampling a frozen
            // or absent temperature. Treating a missing reading as "target 0" hands
            // the fans to macOS on every tick, so a curve that has never seen a
            // sample can never start.
            releaseIfHeld()
            return
        }
        let temp = commandFilter.temperature(reading, sensor: curve.sensor)
        var target = curve.sample(temp: temp)
        if reduceFansOnBattery && !isOnACPower { target *= 0.75 }
        // "Auto" is a sampling choice, not a sensor name — notifications and debug
        // lines say which hardware the demand came from.
        let sensorLabel = curve.sensor == .hottest ? curve.sensor.descriptiveName : curve.sensor.rawValue
        command(to: Self.clamp(target, 0, 100), now: now, sensorLabel: sensorLabel)
    }

    /// The single tail of the control loop: limiter → write-if-moved → release-if-zero.
    func command(to desiredPercent: Double, now: Date, sensorLabel: String) {
        let commanded = commandFilter.percent(desired: desiredPercent, now: now)
        if debugLogging {
            print(String(format: "[loop] %@ mode=%@ desired=%.1f%% commanded=%.1f%% canWrite=%@ pins=%d",
                         sensorLabel, controlMode.rawValue, desiredPercent, commanded,
                         canWrite ? "yes" : "NO", userPinnedFanIDs.count))
        }
        let previous = lastCommandedPercent
        let moved = previous == nil || abs(commanded - previous!) >= 0.05
        lastCommandedPercent = commanded
        setCurrentCommanded(commanded)

        if commanded > CommandFilter.releaseToAutoPercent {
            guard moved else { return }
            setAllToPercentage(commanded / 100.0, source: .engine)
            if !wasEngineApplied {
                notifyEngineEngaged(sensorName: sensorLabel, percent: commanded)
                wasEngineApplied = true
            }
        } else if wasEngineApplied {
            releaseOwnedFans()
            notifyEngineDisengaged()
            wasEngineApplied = false
        }
    }

    /// Publishes the commanded percentage for the readouts, but only when it moved
    /// by a whole percent: the limiter emits a continuous float every second and
    /// assigning it verbatim would invalidate views over a value nobody can read.
    func setCurrentCommanded(_ value: Double?) {
        guard let value else {
            if currentCommandedPercent != nil { currentCommandedPercent = nil }
            return
        }
        if let old = currentCommandedPercent, abs(value - old) < 1.0 { return }
        currentCommandedPercent = value
    }

    // MARK: - Notifications
    //
    // Rate-limited: an engine idling just above the release threshold crosses the
    // demand boundary repeatedly, and every crossing would post a banner.

    func canNotify(now: Date = Date()) -> Bool {
        if let last = lastNotificationDate, now.timeIntervalSince(last) < notificationCooldown { return false }
        lastNotificationDate = now
        return true
    }

    func notifyEngineEngaged(sensorName: String, percent: Double) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        notifiedEngaged = percent >= Self.notifiableDemandPercent
        guard notifiedEngaged, canNotify() else { return }
        let content = UNMutableNotificationContent()
        content.title = "FanCurve"
        content.body = "\(sensorName) demand: fans → \(Int(percent.rounded()))%"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func notifyEngineDisengaged() {
        defer { notifiedEngaged = false }
        guard notifiedEngaged, Bundle.main.bundleIdentifier != nil, canNotify() else { return }
        let content = UNMutableNotificationContent()
        content.title = "FanCurve"
        content.body = "Cooling demand gone — fans returned to automatic control."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Fan-response presets

    /// Applying a preset changes *only* the five limiter knobs. It never enables an
    /// engine and never resets a fan.
    func apply(_ preset: FanResponsePreset) {
        maximumCommandRiseRatePercentPerSecond = preset.rise
        maximumCommandFallRatePercentPerSecond = preset.fall
        coolingTemperatureHysteresis = preset.hysteresis
        coolingConfirmationSeconds = preset.confirmation
        minimumCommandChangePercent = preset.minChange
    }

    /// Checks all five knobs, so the checkmark can never be left unmatched by a knob
    /// the preset wrote but the comparison ignored.
    func matches(_ preset: FanResponsePreset) -> Bool {
        abs(maximumCommandRiseRatePercentPerSecond - preset.rise) < 0.01
            && abs(maximumCommandFallRatePercentPerSecond - preset.fall) < 0.01
            && abs(coolingTemperatureHysteresis - preset.hysteresis) < 0.01
            && abs(coolingConfirmationSeconds - preset.confirmation) < 0.01
            && abs(minimumCommandChangePercent - preset.minChange) < 0.01
    }
}
