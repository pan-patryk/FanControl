import Foundation

/// The single % formula, used by every writer and every reader.
///
/// There is exactly one conversion between rpm and "percent of a fan's range", in
/// both directions. Any second formula — scaling by `maxSpeed` instead of the usable
/// `minSpeed…maxSpeed` span, or omitting the `minSpeed` offset — makes a row's label
/// disagree with its own slider, and makes a fan's value after an engine write not
/// match what the engine commanded.
enum FanPercentage {
    /// rpm for a fraction (0…1) of a fan's *usable* range.
    static func rpm(fan: FanJSON, fraction: Double) -> Int {
        let f = min(max(fraction, 0), 1)
        let range = Double(max(fan.maxSpeed - fan.minSpeed, 0))
        return Int((Double(fan.minSpeed) + f * range).rounded())
    }

    /// fraction (0…1) implied by an rpm inside a fan's usable range.
    static func fraction(of fan: FanJSON, rpm: Int) -> Double {
        let range = fan.maxSpeed - fan.minSpeed
        guard range > 0 else { return 0 }
        return min(max(Double(rpm - fan.minSpeed) / Double(range), 0), 1)
    }

    /// 0…100 of the SMC's own commanded target, for the history series.
    static func targetPercent(of fan: FanJSON) -> Double? {
        guard fan.maxSpeed > fan.minSpeed else { return nil }
        return min(max(fraction(of: fan, rpm: fan.targetSpeed) * 100, 0), 100)
    }
}
