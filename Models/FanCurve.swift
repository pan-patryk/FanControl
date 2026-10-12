import Foundation

// MARK: - Temperature → Fan Speed Curve
//
// The "curve" engine: x = sensor temperature (°C), y = fan speed (%).
// A curve is a small set of knots, evaluated piecewise-linear. Presets are
// built-in shapes (re-derived from the sensor, never stored); what the user
// SAVES is a list of named entries, so the list grows only with curves the
// user actually wants to keep.
//
// A stored curve is an ordinary entry whatever its id, so nothing is
// special-cased at load time.

struct CurvePoint: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var x: Double   // temperature °C
    var y: Double   // fan speed %
}

struct FanCurve: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var isBuiltIn: Bool
    var sensor: TemperatureSensor
    var points: [CurvePoint]

    static let silent = FanCurve(
        id: "silent", name: "Silent", isBuiltIn: true, sensor: .cpu,
        points: [
            CurvePoint(x: 45, y: 0), CurvePoint(x: 60, y: 10),
            CurvePoint(x: 70, y: 20), CurvePoint(x: 80, y: 40),
            CurvePoint(x: 90, y: 70), CurvePoint(x: 98, y: 100)
        ]
    )

    static let balanced = FanCurve(
        id: "balanced", name: "Balanced", isBuiltIn: true, sensor: .cpu,
        points: [
            CurvePoint(x: 45, y: 10), CurvePoint(x: 55, y: 20),
            CurvePoint(x: 65, y: 35), CurvePoint(x: 75, y: 55),
            CurvePoint(x: 85, y: 80), CurvePoint(x: 95, y: 100)
        ]
    )

    static let performance = FanCurve(
        id: "performance", name: "Performance", isBuiltIn: true, sensor: .cpu,
        points: [
            CurvePoint(x: 45, y: 20), CurvePoint(x: 55, y: 35),
            CurvePoint(x: 65, y: 50), CurvePoint(x: 75, y: 70),
            CurvePoint(x: 85, y: 90), CurvePoint(x: 95, y: 100)
        ]
    )

    static let fullThrottle = FanCurve(
        id: "full", name: "Full throttle", isBuiltIn: true, sensor: .cpu,
        points: [CurvePoint(x: 30, y: 100), CurvePoint(x: 105, y: 100)]
    )

    /// X axis (°C) that makes sense for each sensor. Battery runs far cooler
    /// than silicon, so plotting it on a 30–110° axis would be a useless sliver.
    /// Delegates to the sensor: the axis is a property of the hardware, not of the
    /// curve drawn on it.
    static func xDomain(for sensor: TemperatureSensor) -> ClosedRange<Double> { sensor.domain }

    /// Knots sorted, clamped inside the sensor's axis, and never sharing or crossing
    /// an x. Dragging a knot past a neighbour must not silently re-wire the curve, so
    /// the order is fixed here rather than inferred at sample time. Pure, so it is
    /// covered by `tools/model-harness` rather than only by eyeballing the editor.
    func sanitized() -> FanCurve {
        var curve = self
        let axis = FanCurve.xDomain(for: sensor)
        let points = self.points.sorted { $0.x < $1.x }
        guard !points.isEmpty else { return curve }

        // The preferred 0.5 °C separation, shrunk only if the axis cannot physically
        // hold it — it can always hold `axisWidth / (count - 1)`, which is what keeps
        // the backward pass below from escaping the floor.
        let gap = min(0.5, (axis.upperBound - axis.lowerBound) / Double(max(points.count - 1, 1)))
        var knots = points
        for i in knots.indices {
            knots[i].y = min(max(knots[i].y, 0), 100)
            var x = min(max(knots[i].x, axis.lowerBound), axis.upperBound)
            if i > 0 { x = max(x, knots[i - 1].x + gap) }
            knots[i].x = x
        }
        // Tail pushed past the ceiling: walk *back* from it. Rescaling the set instead
        // (the earlier approach) clamped several knots straight onto `upperBound`, so
        // the curve silently lost knots and `sample()` had nothing to interpolate
        // between.
        if knots[knots.count - 1].x > axis.upperBound {
            knots[knots.count - 1].x = axis.upperBound
            for i in stride(from: knots.count - 2, through: 0, by: -1) {
                knots[i].x = Swift.min(knots[i].x, knots[i + 1].x - gap)
            }
        }
        curve.points = knots
        return curve
    }

    /// Knot shapes per preset per sensor: identical *character*, rescaled to
    /// each sensor's plausible temperature range.
    static func presetPoints(id: String, sensor: TemperatureSensor) -> [CurvePoint] {
        let battery = sensor == .battery
        switch id {
        case "silent":
            return battery
                ? [CurvePoint(x: 15, y: 0), CurvePoint(x: 25, y: 10), CurvePoint(x: 35, y: 25),
                   CurvePoint(x: 45, y: 60), CurvePoint(x: 55, y: 100)]
                : silent.points
        case "balanced":
            return battery
                ? [CurvePoint(x: 15, y: 10), CurvePoint(x: 25, y: 25), CurvePoint(x: 35, y: 45),
                   CurvePoint(x: 45, y: 70), CurvePoint(x: 55, y: 100)]
                : balanced.points
        case "performance":
            return battery
                ? [CurvePoint(x: 15, y: 25), CurvePoint(x: 25, y: 45), CurvePoint(x: 35, y: 65),
                   CurvePoint(x: 45, y: 85), CurvePoint(x: 55, y: 100)]
                : performance.points
        case "full":
            return battery
                ? [CurvePoint(x: 5, y: 100), CurvePoint(x: 60, y: 100)]
                : fullThrottle.points
        default:
            return battery
                ? [CurvePoint(x: 15, y: 0), CurvePoint(x: 55, y: 100)]
                : [CurvePoint(x: 30, y: 0), CurvePoint(x: 105, y: 100)]
        }
    }

    /// The four built-ins, shaped for the given sensor (same ids, sensor-appropriate knots).
    static func presets(for sensor: TemperatureSensor) -> [FanCurve] {
        [silent, balanced, performance, fullThrottle].map { base in
            var c = base
            c.sensor = sensor
            c.points = presetPoints(id: base.id, sensor: sensor)
            return c
        }
    }

    static let presets: [FanCurve] = [silent, balanced, performance, fullThrottle]

    /// A new id for a user-saved curve. Built-in ids stay short and stable ("silent",
    /// "balanced", …); user entries get a prefix that makes their origin obvious in
    /// any persisted blob or debug dump.
    static func newUserCurveID() -> String { "user-" + UUID().uuidString }

    /// Piecewise-linear sample, clamped to [0, 100]. Below the first knot the
    /// first knot's speed applies; above the last, the last knot's.
    func sample(temp: Double) -> Double {
        let pts = points.sorted { $0.x < $1.x }
        guard let first = pts.first else { return 0 }
        guard let last = pts.last else { return 0 }
        guard pts.count > 1 else { return clamp(first.y) }
        if temp <= first.x { return clamp(first.y) }
        if temp >= last.x { return clamp(last.y) }
        for pair in zip(pts, pts.dropFirst()) {
            if temp >= pair.0.x && temp <= pair.1.x {
                guard pair.1.x > pair.0.x else { return clamp(pair.1.y) }
                let t = (temp - pair.0.x) / (pair.1.x - pair.0.x)
                return clamp(pair.0.y + t * (pair.1.y - pair.0.y))
            }
        }
        return clamp(last.y)
    }

    private func clamp(_ y: Double) -> Double { min(max(y, 0), 100) }
}
