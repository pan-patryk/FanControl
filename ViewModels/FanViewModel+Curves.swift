import Foundation

// The curve list: built-in shapes plus the entries the user saved.
//
// Built-in shapes (Silent / Balanced / Performance / Full throttle) are *derived*
// per sensor from `FanCurve.presets(for:)` and are never stored. What IS stored is
// the list of user curves under `customCurves` — the user can save the curve they
// are looking at as a new named entry, keep several, apply any of them from the
// picker, and delete the ones they no longer want.
//
// Because a shape is not an entry, curve edits land in an in-memory draft that
// overlays the curve it was forked from — a saved entry or a built-in shape. The
// draft becomes a saved entry only through the editor's save/discard control (or
// when a profile is created from the current state). That is what keeps "editing
// Balanced" from clobbering anything, and what gives an edit an explicit undo:
// discard.

extension FanViewModel {

    // MARK: - What is on screen

    /// The curve the editor shows and the engine samples. An unsaved draft
    /// overlays whatever is selected, so tuning is live; the draft becomes real
    /// only through the editor's save control. A saved entry first (it carries
    /// its own sensor), then a derived preset shape.
    var activeCurve: FanCurve? {
        if let draft = curveDraft { return draft }
        if let saved = userCurves.first(where: { $0.id == activeCurveID }) { return saved }
        return FanCurve.presets(for: curveSensor).first { $0.id == activeCurveID }
    }

    /// The curve a draft was forked from: the saved entry it overlays, or the
    /// derived preset shape. Recomputed rather than stored — the draft carries
    /// the source id, and a stored copy could drift from the real base.
    var curveDraftBase: FanCurve? {
        guard let draft = curveDraft else { return nil }
        if let saved = userCurves.first(where: { $0.id == draft.id }) { return saved }
        return FanCurve.presets(for: curveSensor).first { $0.id == draft.id }
    }

    /// True when the draft differs from the curve it overlays. An edit that
    /// returns the knots to the saved state clears the draft, so the save/discard
    /// control only exists while there is something real to decide.
    var curveDraftIsDirty: Bool {
        guard let draft = curveDraft, let base = curveDraftBase else { return false }
        return draft.sensor != base.sensor || draft.points != base.points
    }

    // MARK: - Editing

    /// The draft is the only writable curve while it exists: built-in shapes and
    /// saved entries are both edited through it, so "editing Balanced" and
    /// "editing my curve" go through one path. Nothing reaches the saved list
    /// here — that happens only on an explicit save.
    @discardableResult
    func ensureCurveDraft() -> FanCurve {
        if let draft = curveDraft { return draft }
        let source = activeCurve ?? FanCurve.balanced
        var draft = source.sanitized()
        draft.id = source.id      // the draft overlays its source
        curveDraft = draft
        return draft
    }

    /// Write a (copied, mutated) draft back. Sanitised, then compared against the
    /// curve it overlays: an edit that reproduces the saved state clears the
    /// draft, so a no-op drag never leaves the curve marked unsaved.
    func writeCurveDraft(_ draft: FanCurve) {
        let clean = draft.sanitized()
        curveDraft = clean
        if !curveDraftIsDirty { curveDraft = nil }
    }

    /// First free name in the saved list: "Balanced", "Balanced 2", "Balanced 3", …
    /// Built-in names count as taken too — the profile list shows shapes and saved
    /// entries side by side, and a saved entry that shadows a shape's name reads as
    /// two of the same thing (the shapes cannot be deleted, so the saved copy must
    /// not collide with one).
    func uniqueCurveName(basedOn name: String) -> String {
        let taken = Set(userCurves.map(\.name) + FanCurve.presets.map(\.name))
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    /// Move the sampling sensor of the curve the user is looking at. If a saved
    /// curve is active, its knots are rescaled into the new axis so the *shape*
    /// the user drew is preserved instead of landing outside the domain, where it
    /// reads as a flat line; the built-ins re-derive for the new sensor by
    /// themselves, so when a preset is active only the sampling choice changes.
    /// An unsaved draft is rejected first: the editor's save/discard control is
    /// the only commit point for curve edits.
    func setCurveSensor(_ sensor: TemperatureSensor) {
        guard sensor != curveSensor else { return }
        if debugLogging { print("[curve] sensor \(curveSensor.rawValue) → \(sensor.rawValue)") }
        curveDraft = nil
        if let idx = userCurves.firstIndex(where: { $0.id == activeCurveID }) {
            var curve = userCurves[idx]
            let from = FanCurve.xDomain(for: curve.sensor)
            let to = FanCurve.xDomain(for: sensor)
            if curve.sensor != sensor {
                let fromSpan = max(from.upperBound - from.lowerBound, 0.0001)
                let toSpan = max(to.upperBound - to.lowerBound, 0.0001)
                for i in curve.points.indices {
                    let rel = (curve.points[i].x - from.lowerBound) / fromSpan
                    curve.points[i].x = to.lowerBound + rel * toSpan
                }
                curve.sensor = sensor
                userCurves[idx] = curve.sanitized()
            }
            curveSensor = sensor
            retargetActiveProfileSensor(sensor)
            return
        }
        curveSensor = sensor
        retargetActiveProfileSensor(sensor)
    }

    func updateCurvePoint(_ point: CurvePoint) {
        var draft = ensureCurveDraft()
        guard let i = draft.points.firstIndex(where: { $0.id == point.id }) else { return }
        draft.points[i] = point
        writeCurveDraft(draft)
    }

    /// Tap on empty space: add a knot. A knot within a *relative* distance of an
    /// existing one moves that neighbour instead. An absolute tolerance would feel
    /// completely different on each sensor — 3° is a fifth of the battery axis and a
    /// fortieth of the silicon axis.
    func addCurvePoint(x: Double, y: Double) {
        var draft = ensureCurveDraft()
        let tolerance = proximityTolerance(for: draft.sensor)
        if let near = draft.points.firstIndex(where: { abs($0.x - x) <= tolerance }) {
            draft.points[near].y = Self.clamp(y, 0, 100)
        } else {
            draft.points.append(CurvePoint(x: x, y: y))
        }
        writeCurveDraft(draft)
    }

    func proximityTolerance(for sensor: TemperatureSensor) -> Double {
        let domain = FanCurve.xDomain(for: sensor)
        return max(1.5, (domain.upperBound - domain.lowerBound) / 20)
    }

    /// Delete a knot from the draft. Creating the draft on demand means built-in
    /// shapes are draftable too — a shape is frozen only once it is saved.
    func deleteCurvePoint(_ id: UUID) {
        var draft = ensureCurveDraft()
        guard draft.points.count > 2 else {
            reportWriteResult(success: false, message: L10n.text("a curve needs at least two knots"))
            return
        }
        draft.points.removeAll { $0.id == id }
        writeCurveDraft(draft)
    }

    // MARK: - Save / discard the draft

    /// The editor's commit point. A draft that overlays a saved entry is written
    /// back into that entry (any profile pointing at it keeps pointing at it). A
    /// draft forked from a built-in shape becomes a NEW named saved entry — the
    /// shape itself stays derived, never stored — and the active profile
    /// retargets to the fork.
    func saveCurveDraft() {
        guard let draft = curveDraft else { return }
        if let idx = userCurves.firstIndex(where: { $0.id == draft.id }) {
            userCurves[idx] = draft.sanitized()
            curveDraft = nil
            return
        }
        var fork = draft
        fork.id = FanCurve.newUserCurveID()
        fork.isBuiltIn = false
        fork.name = uniqueCurveName(basedOn: draft.name)
        userCurves.append(fork)
        activeCurveID = fork.id
        retargetActiveProfile(curveID: fork.id)
        curveDraft = nil
    }

    /// Reject the draft: the curve on screen goes back to its saved status. The
    /// engine re-samples the saved curve through the command filter, so the fans
    /// ramp smoothly instead of snapping.
    func discardCurveDraft() {
        curveDraft = nil
    }

    // MARK: - Curve persistence

    func saveCurves() {
        guard !isLoadingCurveState else { return }
        // Cheap keys write immediately; the (larger) curve blob is coalesced, because
        // dragging a knot fires this on EVERY mouse event.
        UserDefaults.standard.set(activeCurveID, forKey: Keys.activeCurveID)
        UserDefaults.standard.set(curveSensor.rawValue, forKey: Keys.curveSensor)
        curveSaveTask?.cancel()
        curveSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { self.flushCurveSave() }
        }
    }

    /// Immediate write (menu close / quit / discrete edits).
    func flushCurveSave() {
        curveSaveTask?.cancel()
        if let encoded = try? JSONEncoder().encode(userCurves) {
            UserDefaults.standard.set(encoded, forKey: Keys.curves)
        }
    }

    /// Restore the saved curve list, the selection, the sampling sensor and the
    /// start-up curve.
    ///
    /// Order matters, and the two flags in this function are what make it safe.
    /// Assigning to the curve list fires its `didSet` → `saveCurves()`, which writes
    /// `activeCurveID` and `curveSensor` *immediately* (only the blob is coalesced).
    /// Restoring the selection *after* that assignment would overwrite the persisted
    /// value with the property's default — so the blob would survive and the pointer
    /// into it would not, and a saved custom curve would come back as "Balanced" on
    /// every launch.
    func loadCurves() {
        isLoadingCurveState = true
        defer { isLoadingCurveState = false }
        var saved: [FanCurve] = []
        if let data = UserDefaults.standard.data(forKey: Keys.curves),
           let decoded = try? JSONDecoder().decode([FanCurve].self, from: data) {
            // Built-ins are never stored; anything claiming to be one in a blob is
            // stale state, dropped rather than re-derived twice.
            saved = decoded.filter { !$0.isBuiltIn }
        }
        userCurves = saved.map { $0.sanitized() }
        if let id = UserDefaults.standard.string(forKey: Keys.activeCurveID),
           FanCurve.presets.contains(where: { $0.id == id })
            || userCurves.contains(where: { $0.id == id }) {
            activeCurveID = id
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.curveSensor),
           let sensor = TemperatureSensor(rawValue: raw) {
            curveSensor = sensor
        }
        // "Start with": the curve the app should come up with, regardless of what was
        // last selected. An id that no longer resolves (a deleted curve, an unknown
        // shape) is ignored rather than silently breaking the selection.
        if let startup = UserDefaults.standard.string(forKey: Keys.startupCurveID), !startup.isEmpty,
           userCurves.contains(where: { $0.id == startup })
            || FanCurve.presets.contains(where: { $0.id == startup }) {
            activeCurveID = startup
        }
        // Invariant: while a *saved* curve is selected, the chart, the sampling
        // picker and the engine agree on its sensor. (A saved curve carries its own
        // sensor because it is stored; the built-ins are derived from `curveSensor`
        // and can never disagree.)
        if let curve = userCurves.first(where: { $0.id == activeCurveID }), curve.sensor != curveSensor {
            curveSensor = curve.sensor
        }
        if debugLogging {
            print(String(format: "[curve] restore: %d saved, active=%@ sensor=%@ startup=%@",
                         userCurves.count, activeCurveID, curveSensor.rawValue,
                         UserDefaults.standard.string(forKey: Keys.startupCurveID) ?? "-"))
        }
    }
}
