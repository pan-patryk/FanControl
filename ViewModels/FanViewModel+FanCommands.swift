import Foundation

// Every fan write in the app goes through `setFanMode`. The rest of the class
// states *intent* — pin this, hold that, release everything — and this file turns
// intent into one command on one channel, with one error surface.
//
// Pins are the load-bearing concept: `userPinnedFanIDs` is the set of fans the
// engine is forbidden to touch, and only `.user*` command sources add to it.

extension FanViewModel {

    /// Write a fan's mode and (for forced mode) its target rpm.
    /// - Parameters:
    ///   - mode: `0` = hand the fan back to `thermalmonitord`, `1` = force `speed`.
    ///   - force: bypass the redundant-write filter. User actions pass `true`,
    ///     because the dedupe is an optimisation and must not swallow a click.
    func setFanMode(fanId: Int, mode: Int, speed: Int? = nil, force: Bool = false,
                    completion: ((Bool, String) -> Void)? = nil) {
        if debugLogging { print("[write] fan \(fanId) mode=\(mode) speed=\(speed.map(String.init) ?? "auto")") }
        guard canWrite else {
            if debugLogging { print("[skip] fan \(fanId): no privileged channel (controlServiceActive=\(controlServiceActive) isAuthorized=\(isAuthorized))") }
            reportWriteResult(success: false, message: L10n.text("no privileged helper is installed"))
            completion?(false, Self.helperUnauthorizedMessage)
            return
        }
        let written = mode == 1 ? (speed ?? 0) : -1
        if !force, lastWrittenTargets[fanId] == written {
            if debugLogging { print("[skip] fan \(fanId): unchanged (\(written) rpm already written)") }
            completion?(true, "unchanged"); return
        }

        if let proxy = controlProxy() {
            proxy.setFan(fanId: fanId, mode: mode, speed: speed ?? 0) { [weak self] ok, message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if ok { self.lastWrittenTargets[fanId] = written }
                    self.reportWriteResult(success: ok, message: message)
                    completion?(ok, message)
                }
            }
            return
        }
        // Fallback: the setuid helper, forked per command. Only reached when the
        // daemon is not live — `controlProxy()` returns nil — so the app cannot be
        // holding two half-configured channels at once.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var args = ["set", "\(fanId)", "\(mode)"]
            if mode == 1, let speed { args.append("\(speed)") }
            let (status, output) = self.runHelper(args)
            DispatchQueue.main.async {
                if status == 0 { self.lastWrittenTargets[fanId] = written }
                self.reportHelperResult(status, output: output)
                completion?(status == 0, output)
            }
        }
    }

    /// Pick a fan's mode. Choosing **Manual holds the fan where it is** rather than
    /// driving it to its physical minimum: touching a picker must never cut cooling.
    func changeFanMode(fanId: Int, mode: Int) {
        for id in affectedFans(fanId) {
            if mode == 1 {
                let fan = controlFans.first(where: { $0.id == id })
                let hold = max(fan?.currentSpeed ?? fan?.minSpeed ?? 0, fan?.minSpeed ?? 0)
                userPinnedFanIDs.insert(id)
                setFanMode(fanId: id, mode: 1, speed: hold, force: true)
            } else {
                userPinnedFanIDs.remove(id)
                setFanMode(fanId: id, mode: 0)
            }
        }
    }

    /// Slider release on one fan: an explicit user pin.
    func changeFanSpeed(fanId: Int, speed: Int) {
        for id in affectedFans(fanId) {
            let fan = controlFans.first(where: { $0.id == id })
            let bounded = Self.clamp(speed, fan?.minSpeed ?? speed, fan?.maxSpeed ?? speed)
            userPinnedFanIDs.insert(id)
            setFanMode(fanId: id, mode: 1, speed: bounded, force: true)
        }
    }

    /// "Sync all fans together" applies to every user-initiated fan command.
    func affectedFans(_ fanId: Int) -> [Int] {
        linkedFans ? controlFans.map(\.id) : [fanId]
    }

    /// Percentage commands, with the source that decides whether it is a pin.
    /// - Parameters:
    ///   - fractionOfRange: 0…1 of the fan's *usable* range (`minSpeed…maxSpeed`),
    ///     not a percentage — the name is historical and the callers pass
    ///     0.2 / 0.4 / draft/100. Scaling a 0…100 value here would make every
    ///     engine command 100× too small (a 30 % demand becomes 0.3 %, i.e. the
    ///     fan minimum).
    ///   - source: `.engine` skips user pins; `.userAllFans` pins every fan it
    ///     writes, so a later engine tick cannot silently take the value back and
    ///     make a button look like it worked for one second.
    func setAllToPercentage(_ fractionOfRange: Double, source: CommandSource = .engine) {
        let fraction = Self.clamp(fractionOfRange, 0, 1)
        if debugLogging { print(String(format: "[write] %d fans → %.1f%% of range source=%@", controlFans.count, fraction * 100, "\(source)")) }
        for fan in controlFans {
            if source == .engine, userPinnedFanIDs.contains(fan.id) { continue }
            let target = FanPercentage.rpm(fan: fan, fraction: fraction)
            if source == .userAllFans { userPinnedFanIDs.insert(fan.id) }
            setFanMode(fanId: fan.id, mode: 1, speed: target, force: source == .userAllFans)
        }
    }

    /// Hand the fans an engine owns back to macOS, leaving user pins alone. This is
    /// the only release path: picking *macOS* in the mode picker is how the user
    /// hands control back.
    func releaseOwnedFans() {
        for fan in controlFans where !userPinnedFanIDs.contains(fan.id) {
            setFanMode(fanId: fan.id, mode: 0)
        }
    }

    /// Forget the write bookkeeping without touching the hardware, so the next
    /// command is issued even when its value matches what was last written.
    func forgetAllWrites() {
        for fan in controlFans { lastWrittenTargets[fan.id] = -1 }
    }
}
