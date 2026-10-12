import Foundation

// Profiles: one named bundle of curve id + sampling sensor + the five response
// knobs (see `Models/FanProfile.swift`). Applying one moves all three together.
//
// While a profile is selected it also *absorbs* the response edits the user makes
// (`writeKnobsToActiveProfile`). That is what gives "Restore default profiles"
// something to put back: the built-ins carry the tuning in use, are allowed to
// drift from it, and can be returned to factory values.

extension FanViewModel {

    // MARK: - What is selected

    var activeProfile: FanProfile? { profiles.first { $0.id == activeProfileID } }
    var activeProfileName: String? { activeProfile?.name }

    /// Built-in profiles are factory-owned: they can be restored but not deleted.
    var activeProfileIsRemovable: Bool { activeProfile.map { !$0.isDefault } ?? false }

    // MARK: - Apply / create / delete

    /// Sensor, curve and response knobs move together — the point of a profile.
    /// The sensor is set first: built-in shapes are derived per sensor, so the
    /// curve id only resolves to the profile's shape once the axis is set.
    /// Switching profiles rejects an unsaved draft: the editor's save/discard
    /// control is the only commit point for curve edits.
    func applyProfile(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        curveDraft = nil
        isApplyingProfile = true
        defer { isApplyingProfile = false }
        curveSensor = profile.sensor
        activeCurveID = profile.curveID
        maximumCommandRiseRatePercentPerSecond = profile.rise
        maximumCommandFallRatePercentPerSecond = profile.fall
        coolingTemperatureHysteresis = profile.hysteresis
        minimumCommandChangePercent = profile.minChange
        coolingConfirmationSeconds = profile.confirmation
        activeProfileID = profile.id
        if debugLogging {
            print(String(format: "[profile] apply %@ → curve %@ sensor %@",
                         profile.id, profile.curveID, profile.sensor.rawValue))
        }
    }

    /// Snapshot the *current* configuration as a new named profile, straight
    /// from the profile menu. The name falls back to a unique one.
    @discardableResult
    func createProfile(named requested: String? = nil) -> FanProfile {
        // "Saves the curve, sensor and response settings you are using now" — so
        // an unsaved draft is committed first: the snapshot must describe what is
        // on screen, not what is stored.
        if curveDraft != nil { saveCurveDraft() }
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = FanProfile(
            id: FanProfile.newUserProfileID(),
            name: (trimmed?.isEmpty == false) ? trimmed! : uniqueProfileName(),
            isDefault: false,
            curveID: activeCurveID,
            sensor: curveSensor,
            rise: maximumCommandRiseRatePercentPerSecond,
            fall: maximumCommandFallRatePercentPerSecond,
            hysteresis: coolingTemperatureHysteresis,
            minChange: minimumCommandChangePercent,
            confirmation: coolingConfirmationSeconds
        )
        profiles.append(profile)
        activeProfileID = profile.id
        flushProfileSave()   // an explicit user action: persist immediately
        return profile
    }

    /// "Profile 2", "Profile 3", … — a profile name may not shadow one that
    /// already exists, or the menu reads as two of the same thing.
    func uniqueProfileName(basedOn base: String = "Profile") -> String {
        let taken = Set(profiles.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Remove a user profile. Built-ins are factory-owned and never removed;
    /// the curve the profile pointed at is left alone (it is still a curve).
    func deleteProfile(_ id: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }), !profiles[idx].isDefault else { return }
        profiles.remove(at: idx)
        if activeProfileID == id { activeProfileID = "" }
        flushProfileSave()
    }

    /// Settings → "Restore default profiles": put the four built-ins back to
    /// their factory curve / sensor / response values. Profiles the user made
    /// are untouched, which is the whole point of the confirmation prompt.
    func restoreDefaultProfiles() {
        let factory = FanProfile.factoryDefaults()
        var restored = profiles
        for i in restored.indices where restored[i].isDefault {
            if let fresh = factory.first(where: { $0.id == restored[i].id }) { restored[i] = fresh }
        }
        for fresh in factory where !restored.contains(where: { $0.id == fresh.id }) { restored.append(fresh) }
        profiles = restored
        flushProfileSave()
        // A restored built-in that is currently selected must show its values
        // again — otherwise the restore is invisible until it is re-applied.
        if let active = profiles.first(where: { $0.id == activeProfileID }), active.isDefault {
            applyProfile(active.id)
        }
    }

    // MARK: - Keeping the selection honest

    /// The selected profile stores the response values you are actually using.
    /// Called from the five knob `didSet`s; a no-op while nothing is selected.
    func writeKnobsToActiveProfile() {
        guard !isLoadingProfileState, !isApplyingProfile,
              let idx = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        let current = profiles[idx]
        guard current.rise != maximumCommandRiseRatePercentPerSecond
            || current.fall != maximumCommandFallRatePercentPerSecond
            || current.hysteresis != coolingTemperatureHysteresis
            || current.minChange != minimumCommandChangePercent
            || current.confirmation != coolingConfirmationSeconds else { return }
        profiles[idx].rise = maximumCommandRiseRatePercentPerSecond
        profiles[idx].fall = maximumCommandFallRatePercentPerSecond
        profiles[idx].hysteresis = coolingTemperatureHysteresis
        profiles[idx].minChange = minimumCommandChangePercent
        profiles[idx].confirmation = coolingConfirmationSeconds
    }

    /// A *different* curve or sensor is now selected, so the selected profile no
    /// longer describes what is on screen — stop claiming one is active.
    func clearActiveProfileIfChanged() {
        guard !isApplyingProfile, !isLoadingProfileState, !isLoadingCurveState,
              let profile = activeProfile else { return }
        if profile.curveID != activeCurveID || profile.sensor != curveSensor {
            activeProfileID = ""
        }
    }

    /// The active curve was forked (editing a built-in shape): the profile keeps
    /// following it, because those are the knots it was created from.
    func retargetActiveProfile(curveID: String) {
        guard !isApplyingProfile, !isLoadingCurveState,
              let idx = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        if profiles[idx].curveID != curveID { profiles[idx].curveID = curveID }
    }

    /// The sampling sensor changed: the profile follows it, for the same reason
    /// `retargetActiveProfile(curveID:)` does. With the profile menu as the only
    /// selector, a change that cleared the selection would leave the user looking at
    /// a curve they could no longer get back to.
    func retargetActiveProfileSensor(_ sensor: TemperatureSensor) {
        guard !isApplyingProfile, !isLoadingCurveState,
              let idx = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        if profiles[idx].sensor != sensor { profiles[idx].sensor = sensor }
    }

    // MARK: - Profile persistence

    func saveProfiles() {
        guard !isLoadingProfileState else { return }
        // Coalesced like the curve blob: a knob slider fires this on every
        // drag event, and `cfprefsd` should not see one write per pixel.
        profileSaveTask?.cancel()
        profileSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { self.flushProfileSave() }
        }
    }

    /// Immediate write (menu close / quit / sleep / explicit profile action).
    func flushProfileSave() {
        profileSaveTask?.cancel()
        if let encoded = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(encoded, forKey: Keys.profiles)
        }
    }

    func loadProfiles() {
        isLoadingProfileState = true
        defer { isLoadingProfileState = false }
        var stored: [FanProfile] = []
        if let data = UserDefaults.standard.data(forKey: Keys.profiles),
           let decoded = try? JSONDecoder().decode([FanProfile].self, from: data) {
            stored = decoded
        }
        profiles = FanProfile.merged(stored: stored)
        // A selection that no longer resolves (profile deleted, id retired)
        // clears itself rather than pointing at nothing.
        if let id = UserDefaults.standard.string(forKey: Keys.activeProfile),
           profiles.contains(where: { $0.id == id }) {
            activeProfileID = id
        } else {
            activeProfileID = ""
        }
        if debugLogging {
            print(String(format: "[profile] restore: %d profiles, active=%@",
                         profiles.count, activeProfileID.isEmpty ? "-" : activeProfileID))
        }
    }
}
