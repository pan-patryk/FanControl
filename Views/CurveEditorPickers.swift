import SwiftUI
import AppKit

// Presentation for the curve editor's pickers: the sampling-sensor buttons, their
// labels / glyphs / help text, and the glyph each built-in shape carries.
//
// These are pure functions of a `TemperatureSensor` or a curve id, which is why they
// are here rather than interleaved with the gesture code in `CurveEditorView`. The
// "Auto" case deserves its own wording: it is a *sampling choice* (the hotter of
// CPU/GPU), not a sensor name, so the button label and the help text have to say so.

extension CurveEditorView {

    // MARK: - Curve entry actions

    struct SensorChoice: Identifiable {
        let sensor: TemperatureSensor
        var id: TemperatureSensor { sensor }
    }

    /// Auto first: it is the sampling choice that answers "CPU or GPU?" for the
    /// user instead of asking them.
    var sensorChoices: [SensorChoice] {
        [.hottest, .cpu, .gpu, .battery].map(SensorChoice.init)
    }

    func sensorButton(_ choice: SensorChoice) -> some View {
        let selected = (viewModel.activeCurve?.sensor ?? viewModel.curveSensor) == choice.sensor
        return Button {
            viewModel.setCurveSensor(choice.sensor)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sensorSymbol(choice.sensor))
                    .font(DS.ui(10, .semibold))
                Text(sensorLabel(choice.sensor))
                    .font(DS.ui(10, .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.radius)
                    .fill(selected ? DS.cardFill : Color.clear)
            )
        }
        .buttonStyle(.borderless)
        .help(sensorHelp(choice.sensor))
    }

    /// The button's own word. "Auto" is the sampling choice (the hotter of
    /// CPU/GPU), not a sensor name — the help text below spells that out.
    func sensorLabel(_ sensor: TemperatureSensor) -> String {
        switch sensor {
        case .hottest: return "Auto"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        }
    }

    func sensorSymbol(_ sensor: TemperatureSensor) -> String {
        switch sensor {
        case .hottest: return "flame.fill"
        case .cpu: return "cpu"
        case .gpu: return "gauge.with.needle"
        case .battery: return "battery.100.bolt"
        }
    }

    func sensorHelp(_ sensor: TemperatureSensor) -> String {
        switch sensor {
        case .hottest: return L10n.text("Auto — the curve follows the hotter of CPU / GPU")
        case .cpu: return L10n.text("The curve follows the CPU temperature")
        case .gpu: return L10n.text("The curve follows the GPU temperature")
        case .battery: return L10n.text("The curve follows the battery temperature — charge heat, on its own cooler axis")
        }
    }

}
