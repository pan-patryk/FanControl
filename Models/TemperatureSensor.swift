import Foundation

/// One temperature sensor the app can read and key decisions off.
///
/// The raw values are the strings persisted in `UserDefaults` (`curveSensor`) and in
/// saved history records, so they are load-bearing for stored state: renaming a case
/// or its raw value silently resets every saved curve's sampling choice and every
/// `history.jsonl` series.
enum TemperatureSensor: String, Codable, CaseIterable, Identifiable, Hashable {
    case cpu = "CPU"
    case gpu = "GPU"
    case battery = "Battery"
    /// "Auto": the curve follows the hotter of the two load sensors (CPU, GPU).
    ///
    /// macOS's own thermal authority (thermalmonitord) blends *every* sensor it has
    /// into ONE fan decision — the user is never asked which sensor matters. Asking
    /// "CPU or GPU?" in the curve editor put that load on the user; this case is the
    /// app-side equivalent of Apple's blending: sample the hotter of the two silicon
    /// load sensors. Battery is deliberately NOT in the pool: its temperature is a
    /// proxy for charge/skin heat, not compute load, and it runs on a different axis
    /// (5–60 °C), so folding it in would make the curve react to charging instead of
    /// to work. Battery remains its own curve choice for machines where charge heat
    /// is the thing the user wants to follow.
    case hottest = "Auto"

    var id: String { rawValue }

    /// The temperature range that is physically plausible for this sensor, and the
    /// axis every curve and gate clamps to. The domain must be per-sensor: a single
    /// wide range shared with the silicon axes would let a battery knot be dragged to
    /// a temperature the battery never reaches, and the curve would then sample a
    /// flat tail forever.
    var domain: ClosedRange<Double> {
        switch self {
        case .cpu, .gpu, .hottest: return 30...110
        case .battery: return 5...60
        }
    }

    /// What the sensor is called in user-facing sentences.
    var descriptiveName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "battery"
        case .hottest: return "CPU/GPU"
        }
    }
}
