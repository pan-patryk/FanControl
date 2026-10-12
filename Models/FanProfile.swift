import Foundation

// MARK: - Profiles
//
// A profile is one named bundle of what the app applies together: the curve
// (which shape or saved entry to sample, and on which sensor) plus the five
// fan-response knobs of `CommandFilter`. Applying a profile moves all of them
// at once, so "Silent" means silent *curve* and quiet *response*, not a curve
// with whatever response settings were left over.
//
// The curve itself is NOT duplicated here: the profile stores the curve's id
// and the sensor, and the knots live in the normal curve store (`userCurves`
// for saved entries, `FanCurve.presets(for:)` for built-in shapes). That keeps
// one owner per knot list — the editor, the engine and the profile can never
// disagree about what the curve is — and it is why editing a built-in shape
// still forks a saved entry rather than writing into a profile.
//
// The four built-in profiles are *restorable*: their stored values are user
// state (tuning edits flow into the selected profile), so Settings can put
// them back to their factory values without touching profiles the user made.

struct FanProfile: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Built-in profiles are factory-owned: they cannot be removed, and
    /// `restoreDefaultProfiles()` resets them. User profiles are neither.
    var isDefault: Bool
    /// Curve this profile selects: a built-in shape id ("silent", …) or a
    /// saved entry id ("user-…", "profile-…").
    var curveID: String
    var sensor: TemperatureSensor

    // The five `CommandFilter` knobs, in the same units the sliders show.
    var rise: Double        // %/s on the way up
    var fall: Double        // %/s on the way down
    var hysteresis: Double  // °C a falling temperature must give back
    var minChange: Double   // % demand change ignored outright
    var confirmation: Double // seconds a lower demand must hold

    /// Prefix for user-made ids, mirroring `FanCurve.newUserCurveID` so a
    /// persisted blob identifies its origin at a glance.
    static let newUserProfileIDPrefix = "profile-"

    static func newUserProfileID() -> String { newUserProfileIDPrefix + UUID().uuidString }

    /// The four built-in profiles, with factory values. The curve ids are the
    /// built-in shape ids (derived per sensor, never stored) and the response
    /// values mirror the four `FanResponsePreset`s, so "Restore defaults"
    /// returns exactly what a fresh install ships with.
    static func factoryDefaults() -> [FanProfile] {
        [
            FanProfile(id: "default-silent", name: "Silent", isDefault: true,
                       curveID: FanCurve.silent.id, sensor: .cpu,
                       rise: FanResponsePreset.calm.rise, fall: FanResponsePreset.calm.fall,
                       hysteresis: FanResponsePreset.calm.hysteresis,
                       minChange: FanResponsePreset.calm.minChange,
                       confirmation: FanResponsePreset.calm.confirmation),
            FanProfile(id: "default-balanced", name: "Balanced", isDefault: true,
                       curveID: FanCurve.balanced.id, sensor: .cpu,
                       rise: FanResponsePreset.balanced.rise, fall: FanResponsePreset.balanced.fall,
                       hysteresis: FanResponsePreset.balanced.hysteresis,
                       minChange: FanResponsePreset.balanced.minChange,
                       confirmation: FanResponsePreset.balanced.confirmation),
            FanProfile(id: "default-performance", name: "Performance", isDefault: true,
                       curveID: FanCurve.performance.id, sensor: .cpu,
                       rise: FanResponsePreset.aggressive.rise, fall: FanResponsePreset.aggressive.fall,
                       hysteresis: FanResponsePreset.aggressive.hysteresis,
                       minChange: FanResponsePreset.aggressive.minChange,
                       confirmation: FanResponsePreset.aggressive.confirmation),
            FanProfile(id: "default-full", name: "Full throttle", isDefault: true,
                       curveID: FanCurve.fullThrottle.id, sensor: .cpu,
                       rise: FanResponsePreset.immediate.rise, fall: FanResponsePreset.immediate.fall,
                       hysteresis: FanResponsePreset.immediate.hysteresis,
                       minChange: FanResponsePreset.immediate.minChange,
                       confirmation: FanResponsePreset.immediate.confirmation),
        ]
    }

    /// Merge a stored list with the factory list, so an upgrade can add a new
    /// built-in profile while keeping the values the user tuned the existing
    /// ones to. A stored built-in whose id is not factory-made any more (renamed or
    /// retired) is dropped rather than kept as a user
    /// profile pretending to be a default.
    static func merged(stored: [FanProfile]) -> [FanProfile] {
        let factory = factoryDefaults()
        var out: [FanProfile] = []
        for builtIn in factory {
            if let kept = stored.first(where: { $0.id == builtIn.id }) {
                var profile = kept
                profile.isDefault = true
                profile.name = builtIn.name   // the factory owns the name
                out.append(profile)
            } else {
                out.append(builtIn)
            }
        }
        out.append(contentsOf: stored.filter { profile in
            !profile.isDefault && !factory.contains { $0.id == profile.id }
        })
        return out
    }
}
