import Foundation

// MARK: - Fan response presets
//
// A preset is *only* a tuple of filter settings: the five fan-response knobs
// collapsed into a single tap. Nothing else.
//
// Applying one must never change which engine is in control and must never write the
// SMC, so a preset is a pure assignment into the five knobs — see
// `FanViewModel.apply(_:)`.

enum FanResponsePreset: String, CaseIterable, Codable {
    case calm
    case balanced
    case aggressive
    case immediate

    var displayName: String {
        switch self {
        case .calm: return L10n.text("Calm")
        case .balanced: return L10n.text("Balanced")
        case .aggressive: return L10n.text("Aggressive")
        case .immediate: return L10n.text("Immediate")
        }
    }

    /// Maximum commanded rise, in percent of the fan's range per second.
    var rise: Double {
        switch self { case .calm: return 2; case .balanced: return 6; case .aggressive: return 10; case .immediate: return 100 }
    }
    /// Maximum commanded fall, in percent of the fan's range per second.
    var fall: Double {
        switch self { case .calm: return 1; case .balanced: return 3; case .aggressive: return 6; case .immediate: return 100 }
    }
    /// °C a temperature must fall before the controller believes it cooled.
    var hysteresis: Double {
        switch self { case .calm: return 8; case .balanced: return 5; case .aggressive: return 3; case .immediate: return 0 }
    }
    /// Seconds a lower demand must hold before the fans are allowed down.
    var confirmation: Double {
        switch self { case .calm: return 20; case .balanced: return 8; case .aggressive: return 3; case .immediate: return 0 }
    }
    /// Smallest commanded change worth writing to the SMC.
    ///
    /// `immediate` is deliberately 0 (write everything). Because `matches(_:)`
    /// checks this value too, no two presets can be confusable — the checkmark
    /// cannot get "stuck off".
    var minChange: Double {
        switch self { case .immediate: return 0; default: return 4 }
    }
}
