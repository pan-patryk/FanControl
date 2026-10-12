import Foundation

/// One validated temperature stream.
///
/// This is the only reading-plausibility filter in the app, and every consumer —
/// the control loop and the UI mirror alike — reads its output. Two copies, each
/// comparing a candidate against *its own* previous value, can disagree: a fast
/// sustained rise gets rejected forever by one while the other shows the new
/// number, and the control loop goes blind exactly during the transient it exists
/// to catch.
///
/// The policy is deliberately **asymmetric**:
///
/// * A rise is trusted immediately. Thermal protection exists to catch load
///   transients, and this machine really does step 20–31 °C between samples, so a
///   step limiter on the way up would blind the controller during exactly the event
///   it must react to.
/// * A drop-out is confirmed. A sensor that falls off the bus reports `0`, and a
///   `0` taken as a real temperature commands the fans to 0 %. A reading outside the
///   physical bounds, or a large *downward* jump, is held at the last good value
///   until it has been seen twice in a row.
struct SensorGate {
    let sensor: TemperatureSensor
    /// Largest believable downward step, in °C. Upward steps are always believed.
    static let maxPlausibleStep: Double = 25
    /// How many consecutive confirmations a suspicious drop needs.
    static let dropConfirmations = 2

    private(set) var lastGood: Double?
    private var pending: (value: Double, count: Int)?

    init(sensor: TemperatureSensor) {
        self.sensor = sensor
    }

    /// Physically plausible bounds. Readings outside them are sensor faults, not data.
    /// `Auto` is the max of two silicon streams, so it lives in the silicon window.
    var bounds: ClosedRange<Double> {
        switch sensor {
        case .cpu, .gpu, .hottest: return 10...115
        case .battery: return 5...70
        }
    }

    /// Feed one raw reading, get back the temperature to control with — or `nil`
    /// when nothing trustworthy exists yet.
    mutating func accept(_ raw: Double?) -> Double? {
        guard let candidate = raw, candidate.isFinite, bounds.contains(candidate) else {
            // Absent / NaN / out-of-bounds: hold the last good value and count it as
            // a drop-out candidate. `nil` only when we never had a reading at all.
            return noteDropOut(raw: raw)
        }
        if let lastGood, lastGood - candidate > Self.maxPlausibleStep {
            // Large downward jump: could be a real cooldown, could be a dead sensor.
            return noteDropOut(raw: candidate)
        }
        pending = nil
        lastGood = candidate
        return candidate
    }

    /// A drop-out is only acted on once it has been seen `dropConfirmations` times,
    /// so a single bad sample can never command the fans.
    private mutating func noteDropOut(raw: Double?) -> Double? {
        if let pending {
            if pending.count + 1 >= Self.dropConfirmations {
                // Confirmed: the sensor really has left its previous range. Accept
                // the new value if it is in bounds, otherwise report "no data".
                self.pending = nil
                if let raw, raw.isFinite, bounds.contains(raw) {
                    lastGood = raw
                    return raw
                }
                lastGood = nil
                return nil
            }
            self.pending = (pending.value, pending.count + 1)
        } else {
            self.pending = (raw ?? -1, 1)
        }
        return lastGood
    }

    mutating func reset() {
        lastGood = nil
        pending = nil
    }
}
