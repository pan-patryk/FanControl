import Foundation

// In-process equivalent of `fancurve-helper get`. SMC reads don't require root, so
// the menu bar UI queries the sensors directly instead of forking the
// privileged helper on every poll cycle.
//
// Cost matters here: this runs at 1 Hz inside the app, and every `getValue` is one
// or two `IOConnectCallStructMethod` round-trips. Probing 30 temperature keys where
// only ~16 exist on a given machine (verified with `fancurve-helper keys`: `TC0P`,
// `TG0D`, `Tw0P`, … are absent on this Apple Silicon Mac) costs ~70 kernel calls per
// second for numbers that never change — enough for macOS to report the app as using
// a lot of energy. Absent keys stay absent and fan geometry is constant per boot, so
// both are cached, with a reprobe interval to notice hardware changes.
enum SystemStatusReader {
    private static let cpuKeys = [
        "TC0P", "TC0D", "TC0F", "TC1C", "TCAD", "TCBD",
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0C", "Tp0g", "Tp0h", "Te0S"
    ]
    private static let gpuKeys = [
        "TG0D", "TG0H", "TG0P",
        "Tg05", "Tg0j", "Tg0g", "Tg01", "Tg0c"
    ]
    private static let batteryKeys = [
        "TB0T", "TB1T", "TB2T", "Tw0P", "Ts0P", "Th0H"
    ]

    /// Physically plausible silicon/battery die temperature window. Some Apple
    /// Silicon SMC keys transiently report tiny non-zero values.
    private static let validRange = 10.0...115.0

    // MARK: Caches

    /// Keys this machine does not have. Probed once; re-checked on the slow
    /// `reprobeInterval` so a key exposed by a firmware update or after a wake is
    /// not permanently ignored.
    private static var absentKeys: Set<String> = []
    private static var lastReprobe = Date.distantPast
    private static let reprobeInterval: TimeInterval = 600

    /// Fan geometry (`F<n>ID`, `F<n>Mn`, `F<n>Mx`) is fixed for a boot.
    private struct FanGeometry { let name: String; let minSpeed: Int; let maxSpeed: Int }
    private static var fanGeometry: [Int: FanGeometry] = [:]
    private static var cachedFanCount: Int? = nil

    /// Reset the caches (sleep/wake, or after the control service is reinstalled).
    static func invalidateCache() {
        absentKeys.removeAll()
        fanGeometry.removeAll()
        cachedFanCount = nil
        lastReprobe = .distantPast
    }

    /// One `SMC.getValue` that remembers when the answer is "no such key".
    private static func value(_ smc: SMC, _ key: String) -> Double? {
        if absentKeys.contains(key) {
            if Date().timeIntervalSince(lastReprobe) < reprobeInterval { return nil }
        }
        let result = smc.getValue(key)
        if result == nil { absentKeys.insert(key) }
        return result
    }

    static func read() -> SystemStatusJSON {
        let smc = SMC.shared
        let reprobeDue = Date().timeIntervalSince(lastReprobe) >= reprobeInterval
        if reprobeDue {
            absentKeys.removeAll()
            lastReprobe = Date()
        }

        guard let fanCountVal = value(smc, "FNum") else {
            return SystemStatusJSON(fans: [], cpuTemp: nil, gpuTemp: nil, batteryTemp: nil)
        }
        let fanCount = Int(fanCountVal)
        // A changed fan count means the geometry cache is stale (hardware swap,
        // or the first read after a failed one).
        if cachedFanCount != fanCount {
            fanGeometry.removeAll()
            cachedFanCount = fanCount
        }

        var fansList: [FanJSON] = []
        for i in 0..<fanCount {
            // `F<n>Mn`/`F<n>Mx` are constant per boot (verified: 2317 / 7826 rpm on
            // this machine, unchanged across hours) — re-reading them once a second
            // bought nothing. Re-read when reprobing so a fan replacement is seen.
            if reprobeDue { fanGeometry[i] = nil }
            let geometry = fanGeometry[i] ?? {
                let g = FanGeometry(
                    name: smc.getStringValue("F\(i)ID") ?? "Fan \(i)",
                    minSpeed: Int(value(smc, "F\(i)Mn") ?? 0),
                    maxSpeed: Int(value(smc, "F\(i)Mx") ?? 0)
                )
                fanGeometry[i] = g
                return g
            }()

            let current = Int(value(smc, "F\(i)Ac") ?? 0)
            let target = Int(value(smc, "F\(i)Tg") ?? 0)
            let mode = Int(value(smc, smc.fanModeKey(i)) ?? 0)

            fansList.append(FanJSON(
                id: i,
                name: geometry.name,
                currentSpeed: current,
                minSpeed: geometry.minSpeed,
                maxSpeed: geometry.maxSpeed,
                targetSpeed: target,
                mode: mode
            ))
        }

        return SystemStatusJSON(
            fans: fansList,
            // CPU keys describe several plausible CPU-adjacent sensors. Taking the
            // highest valid reading is conservative for thermal control and keeps the
            // result independent of which key happens to answer first.
            cpuTemp: maximumTemp(smc, keys: cpuKeys),
            gpuTemp: firstValidTemp(smc, keys: gpuKeys),
            batteryTemp: firstValidTemp(smc, keys: batteryKeys)
        )
    }

    private static func firstValidTemp(_ smc: SMC, keys: [String]) -> Double? {
        for key in keys {
            if let value = value(smc, key), value.isFinite, validRange.contains(value) {
                return value
            }
        }
        return nil
    }

    private static func maximumTemp(_ smc: SMC, keys: [String]) -> Double? {
        var best: Double? = nil
        for key in keys {
            guard let value = value(smc, key), value.isFinite, validRange.contains(value) else { continue }
            if best == nil || value > best! { best = value }
        }
        return best
    }
}
