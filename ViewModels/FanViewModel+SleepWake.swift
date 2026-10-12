import AppKit
import Foundation

// Sleep and wake, handled as a state machine rather than as a notification callback.
//
// Three facts drive the design:
//   * The SMC keeps a forced mode and target until something overwrites them —
//     measured: mode `[1,1]` outlives the process. A curve that goes to sleep
//     without releasing its fans leaves them at the last commanded speed all night.
//   * A run-loop timer cannot fire while the process is suspended, and it fires the
//     moment the machine is awake again. So the *tick itself* is the wake detector.
//   * `NSWorkspace.didWakeNotification` is not delivered on dark wakes (system
//     awake, display off). Maintenance sleep → dark wake cycles every few minutes
//     overnight (`pmset -g log`), so the notifications are a fast path and the
//     polling tick is the correctness path.

extension FanViewModel {

    func observeSleepNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.isAsleep = true
                self.needsWakeReconcile = true
                // Hand the SMC back to macOS before the machine sleeps. Pins go back
                // too; their rpm is captured first and re-armed on wake (see
                // `reassertPinsAfterWake`).
                self.releaseForSleep()
                self.flushCurveSave()
                self.flushProfileSave()
                self.historyStore?.synchronize()
                // The polling timer is deliberately NOT invalidated: it is the wake
                // detector, and the notifications above are not load-bearing.
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                // Fast path when the notification actually arrives (full wakes).
                // Every other wake — dark wakes, and any cycle where the
                // notification is not delivered — is caught by the polling tick.
                guard let self else { return }
                self.reconcileAfterWake(reason: "didWake")
            },
        ]
    }

    func gatesResetForWake() {
        for sensor in TemperatureSensor.allCases { sensorGates[sensor]?.reset() }
    }

    /// Bring the whole control surface back from sleep. Idempotent: the tick, the
    /// `didWake` notification and a spurious notification all funnel through here.
    func reconcileAfterWake(reason: String) {
        guard isAsleep || needsWakeReconcile else { return }
        isAsleep = false
        needsWakeReconcile = false
        if debugLogging { print("[wake] reconcile (\(reason))") }
        SystemStatusReader.invalidateCache()
        lastPowerSourceCheck = nil
        // A wake can be hours wide: drop the held temperatures and slew position so
        // the first command after wake is not a jump across the whole range.
        commandFilter.reset()
        lastCommandedPercent = nil
        gatesResetForWake()
        // The validated temperatures must go too. `sensorGates` are reset above,
        // so the next `accept()` answers from scratch — but `controlTemps` still
        // holds the pre-sleep reading, and a failed first post-wake read leaves
        // it un-updated (`accept` returns nil and only *accepted* values write).
        // The curve would then command from a temperature hours old.
        controlTemps.removeAll()
        // The SMC's fan state across sleep is unknown — thermalmonitord re-asserts
        // automatic control on wake, and the firmware may have kept or cleared the
        // forced targets. The write bookkeeping must not be trusted to dedupe against
        // it, or the first post-wake command whose rpm happens to match the pre-sleep
        // value is *skipped*, and the app reports "curve in control" while the SMC is
        // running macOS's own speed.
        //
        // The rpm to re-assert pins with comes from `sleepPinnedRPM`, captured when
        // the machine went to sleep: the sleep release itself zeroes
        // `lastWrittenTargets` (mode 0 writes -1 on success), so the write memory is
        // empty by the time we wake — reading pins from it would re-arm nothing.
        // `lastWrittenTargets` is only the fallback for a reconcile that saw no sleep
        // release (an aborted sleep where the pins were never handed back).
        var pins: [Int: Int] = [:]
        for fanId in userPinnedFanIDs {
            if let rpm = sleepPinnedRPM[fanId] ?? lastWrittenTargets[fanId], rpm >= 0 { pins[fanId] = rpm }
        }
        wakePinsToReassert = pins
        sleepPinnedRPM.removeAll()
        forgetAllWrites()
        // The privileged channel may have changed shape across sleep (launchd
        // restarts the root daemon on any crash, and an XPC interruption during a
        // wake cycle can leave `canWrite == false` while the daemon is alive).
        checkControlService()
        scheduleControlServiceRecheck()
        updateStatus()
        startPolling()
    }

    /// Hand every fan the app was holding back to macOS before the machine sleeps.
    /// Silent on purpose: the user is not looking at a panel at 3 a.m., and
    /// maintenance sleep cycles fire every few minutes — the engage/disengage
    /// notifications would otherwise buzz all night.
    func releaseForSleep() {
        if wasEngineApplied {
            releaseOwnedFans()
            wasEngineApplied = false
        }
        lastCommandedPercent = nil
        setCurrentCommanded(nil)
        sleepPinnedRPM = [:]
        for fanId in userPinnedFanIDs {
            if let rpm = lastWrittenTargets[fanId], rpm >= 0 { sleepPinnedRPM[fanId] = rpm }
        }
        for fanId in sleepPinnedRPM.keys {
            setFanMode(fanId: fanId, mode: 0)
        }
    }

    /// One-shot per wake: re-arm the fans the user pinned, from the rpm remembered
    /// when the machine went to sleep. thermalmonitord re-asserts automatic control
    /// on wake, and the engines never touch pinned fans, so without this a pin is
    /// silently gone after every wake until the user re-pins.
    func reassertPinsAfterWake() {
        guard !wakePinsToReassert.isEmpty else { return }
        // The privileged channel may not be up yet on the first post-wake read
        // (the daemon re-ping is still in flight). Keep the pending pins and try
        // again on a later tick — a pin is user intent, and it should land as soon
        // as a channel exists.
        guard canWrite else { return }

        defer { wakePinsToReassert.removeAll() }
        for (fanId, rpm) in wakePinsToReassert {
            guard userPinnedFanIDs.contains(fanId) else { continue }
            guard let fan = controlFans.first(where: { $0.id == fanId }) else { continue }
            // Only write when the SMC really lost the pin: if the forced target
            // survived the sleep, the read-back matches the memory and nothing is
            // written — this also keeps dark-wake cycles write-free when nothing
            // changed. The SMC's mode byte is used here as a one-shot hardware
            // reconciliation, not as the live pin signal.
            guard fan.mode != 1 || fan.targetSpeed != rpm else {
                lastWrittenTargets[fanId] = rpm
                if debugLogging { print("[wake] pin \(fanId) still held at \(rpm) rpm — no write") }
                continue
            }
            if debugLogging { print("[wake] re-assert pin \(fanId) → \(rpm) rpm (read-back mode=\(fan.mode) target=\(fan.targetSpeed))") }
            setFanMode(fanId: fanId, mode: 1, speed: rpm, force: true)
        }
    }
}
