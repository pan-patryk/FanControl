import AppKit
import Foundation
import IOKit.ps

// The 1 Hz sampling loop: timer cadence, App Nap policy, one SMC read per tick,
// and the single per-tick path that validates → controls → records → mirrors.
//
// Two rules hold it together:
//   * Thermal protection is independent of window visibility. The loop runs while
//     an engine can command a fan, even with nothing on screen.
//   * The published mirrors are only written while something is actually looking,
//     and only on a real difference.

extension FanViewModel {

    // MARK: - Engine restore

    /// Restore the engine the user left running.
    func restoreControlMode() {
        if let raw = UserDefaults.standard.string(forKey: Keys.mode),
           let mode = ControlMode(rawValue: raw) {
            controlMode = mode
        } else {
            controlMode = .macOS
        }
    }

    func loadPins() {
        userPinnedFanIDs = Set(UserDefaults.standard.array(forKey: Keys.pins) as? [Int] ?? [])
    }

    // MARK: - Polling

    func startPolling() {
        timer?.invalidate()
        let interval = pollingInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            // A tick cannot fire while the process is suspended, so a tick arriving
            // while the sleep flag is still set is itself the wake signal — even a
            // dark wake runs the main run loop. This is what makes the NSWorkspace
            // notifications a fast path rather than a correctness requirement.
            if self.isAsleep || self.needsWakeReconcile {
                self.reconcileAfterWake(reason: "tick")
            }
            self.updateStatus()
        }
        // `.common` so menu tracking / window resizing cannot starve the loop:
        // a `.default`-only timer stalls exactly when the UI is busy.
        RunLoop.main.add(timer, forMode: .common)
        timer.tolerance = interval * 0.2
        self.timer = timer
        updateStatus()
    }

    var pollingInterval: TimeInterval {
        // While an engine can command a fan this stays at 1 Hz even with nothing on
        // screen — thermal protection does not get to depend on the app being in
        // front.
        //
        // In macOS mode, though, the app commands *nothing*: it is a passive reader
        // feeding a graph nobody is looking at. 1 Hz there means ~37 SMC key probes
        // (≈70 kernel round-trips) per second forever, which is enough to make macOS
        // post "FanCurve is using a lot of energy". 5 s still out-runs the 30 s
        // history sample and the 10 s menu-bar label refresh, so nothing visible is
        // lost.
        controlMode != .macOS || wantsLiveUI ? 1.0 : 5.0
    }

    /// Re-arm the timer when the cadence class changes (mode switch, panel
    /// open/close). Cheap no-op while the interval is unchanged.
    func applyCadence() {
        applyActivityAssertion()
        guard let timer, timer.isValid else { startPolling(); return }
        if abs(timer.timeInterval - pollingInterval) > 0.01 { startPolling() }
    }

    /// The App Nap assertion is held only while it is justified.
    ///
    /// `beginActivity` keeps the process at full CPU priority and suppresses timer
    /// coalescing — and `automaticTerminationDisabled` additionally tells macOS the
    /// app may never be terminated. Holding both unconditionally, for an app that
    /// spends most of its life idle in the menu bar, is a documented energy
    /// anti-pattern and is what the system's "using a lot of energy" notice reacts to.
    func applyActivityAssertion() {
        let needsAssertion = controlMode != .macOS || wantsLiveUI
        if needsAssertion {
            guard activityToken == nil else { return }
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Fan control loop is commanding the fans")
        } else if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    func updateStatus() {
        // Bound the in-flight window. A read that has been "in flight" this long is
        // wedged (an IOKit call that hung across a wake is the known case), so the
        // guard must be handed back and the next tick must try again — otherwise an
        // unrecoverable tick freezes the temperatures, and the only way to see live
        // data is to reopen the panel, which publishes stale state.
        if let since = pollInFlightSince, Date().timeIntervalSince(since) > 5 {
            if debugLogging { print("[poll] read in flight > 5 s — re-arming the guard") }
            isStatusUpdateInProgress = false
            pollInFlightSince = nil
        }
        guard !isStatusUpdateInProgress, !isQuitting else { return }
        isStatusUpdateInProgress = true
        pollInFlightSince = Date()
        smcQueue.async { [weak self] in
            guard let self else { return }
            let status = SystemStatusReader.read()
            DispatchQueue.main.async {
                // Clear the guard *before* doing anything that can re-enter
                // `updateStatus()`. A write that schedules a poll must not have that
                // poll dropped because the flag is still set.
                self.isStatusUpdateInProgress = false
                self.pollInFlightSince = nil
                self.ingest(status)
            }
        }
    }

    /// The single per-tick path: validate → control → record → mirror.
    func ingest(_ status: SystemStatusJSON) {
        let now = Date()
        rawStatus = status
        filterControlTemperatures(from: status)
        updatePowerSource()
        reassertPinsAfterWake()
        evaluateControlLoop(now: now)
        // Recording is independent of the UI: the retained 24 h history must keep
        // filling on days the menu is never opened.
        recordHistoryIfNeeded(now: now)
        if isUIVisible { publishUI(from: status) }
        applyCadence()
        // Label policy is visibility-independent: at most every 10 s, and only on a
        // change worth a status-item re-layout.
        refreshMenuBarTitle()
        refreshMenuBarIcon()
    }

    /// Mirrors canonical state into the published properties the views observe.
    /// Diffed, so an unchanged reading triggers no SwiftUI invalidation.
    func publishUI(from status: SystemStatusJSON) {
        if status.fans != fans { fans = status.fans }
        let cpu = controlTemperature(for: .cpu)
        let gpu = controlTemperature(for: .gpu)
        let battery = controlTemperature(for: .battery)
        if cpu != cpuTemp { cpuTemp = cpu }
        if gpu != gpuTemp { gpuTemp = gpu }
        if battery != batteryTemp { batteryTemp = battery }
        // Comparing 2800 records per publish is itself a per-second cost; the mirror
        // only needs to know whether the tail moved.
        if tempHistory.count != historyBuffer.count || tempHistory.last?.id != historyBuffer.last?.id {
            tempHistory = historyBuffer
        }
    }

    /// Validated temperature for a sensor — the canonical control value. Views use
    /// this instead of the published mirror so the chart dot and the header agree
    /// with what the controller is doing.
    func controlTemperature(for sensor: TemperatureSensor) -> Double? {
        controlTemps[sensor]
    }

    // MARK: - Sensor validation

    /// Validates readings once per sensor, for everything downstream.
    ///
    /// There is exactly one gate per sensor: a second filter that compares a
    /// candidate against *its own* previous value can reject a fast sustained rise
    /// forever, and the control loop is then blind exactly during the transient it
    /// exists to catch. `SensorGate` is fail-safe in the other direction: rises are
    /// trusted, only drop-outs are confirmed.
    func filterControlTemperatures(from status: SystemStatusJSON) {
        let raw: [TemperatureSensor: Double?] = [
            .cpu: status.cpuTemp, .gpu: status.gpuTemp, .battery: status.batteryTemp
        ]
        for (sensor, value) in raw {
            var gate = sensorGates[sensor] ?? SensorGate(sensor: sensor)
            if let accepted = gate.accept(value) { controlTemps[sensor] = accepted }
            sensorGates[sensor] = gate
        }
        // Auto = the hotter of the two *validated* load streams. thermalmonitord
        // mixes every sensor it has into one fan decision; the app-side equivalent is
        // max(CPU, GPU). One missing sensor degrades to the other; both missing means
        // "no reading" and the engine waits instead of guessing.
        let hottest = [controlTemps[.cpu], controlTemps[.gpu]].compactMap { $0 }.max()
        controlTemps[.hottest] = hottest
    }

    // MARK: - Power source

    /// Which power source the machine is drawing from, from IOKit's documented
    /// accessor: `IOPSGetProvidingPowerSourceType` returns one of
    /// `kIOPMACPowerKey` ("AC Power"), `kIOPMBatteryPowerKey` ("Battery Power") or
    /// `kIOPMUPSPowerKey` ("UPS Power") for the snapshot. UPS counts as AC — a
    /// per-source `kIOPSPowerSourceStateKey` reading reports a UPS-backed Mac as
    /// "Off Line", which reads as battery and derates the fans while the machine is
    /// on unlimited power.
    ///
    /// IOKit only posts power-source change notifications when percent/time
    /// remaining changes, so this is polled — but at 5 s, not once per second,
    /// because each `IOPSCopyPowerSourcesInfo()` builds a whole CF snapshot.
    func updatePowerSource(now: Date = Date()) {
        if let last = lastPowerSourceCheck, now.timeIntervalSince(last) < 5 { return }
        lastPowerSourceCheck = now
        var onAC = true
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            // `Get`-family CF function: the snapshot owns the string, so this must be
            // `takeUnretainedValue()`. A `takeRetainedValue()` here would over-release
            // the object on every poll (crash in the 1 Hz loop).
            let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
            if let type { onAC = (type != kIOPMBatteryPowerKey) }
        }
        if isOnACPower != onAC { isOnACPower = onAC }
    }

    // MARK: - Visibility reporting

    /// Called from `MenuBarView.onAppear`/`onDisappear`, backed by the panel's real
    /// window visibility (see `menuPanelIsVisible`).
    func setMenuOpen(_ open: Bool) {
        if isMenuOpen != open { isMenuOpen = open }
        if debugLogging { print("[menu] \(open ? "open" : "closed")") }
        if open, let status = rawStatus { publishUI(from: status) }
        if !open { flushCurveSave(); flushProfileSave() }
        applyCadence()
    }

    func setWindowOpen(_ open: Bool) {
        if isWindowOpen != open { isWindowOpen = open }
        if debugLogging { print("[window] \(open ? "open" : "closed")") }
        applyCadence()
        if open {
            // The helper's setuid bit can be lost (rebuilt/reinstalled bundle)
            // — re-verify while the user can actually see the card.
            checkAuthorization()
            if let status = rawStatus { publishUI(from: status) }
        } else if runInAccessoryMode {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}
