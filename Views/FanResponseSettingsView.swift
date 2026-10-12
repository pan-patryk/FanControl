import SwiftUI

// MARK: - Fan response (command limiter) settings
//
// The curve turns temperature into a fan %, and this is the one place that bounds how
// fast that % may move. It lives in its own view because both hosts need it: the menu
// panel's "Tuning" section and the settings window.

/// The five knobs of `CommandFilter`, plus the response presets.
struct FanResponseSettingsView: View {
    @ObservedObject var viewModel: FanViewModel
    /// Panel variant drops the card chrome and the "now commanding" readout is shorter.
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            explainer

            presetRow

            VStack(alignment: .leading, spacing: DS.s2) {
                // All five knobs, because all five are live: every engine decision
                // goes through the whole `CommandFilter` pipeline, so hiding a stage
                // would only make it unconfigurable.
                slider("Rise rate", $viewModel.maximumCommandRiseRatePercentPerSecond,
                       0.5...100, 0.5, "%.1f %%/s")
                slider("Fall rate", $viewModel.maximumCommandFallRatePercentPerSecond,
                       0.5...100, 0.5, "%.1f %%/s")
                slider("Hysteresis", $viewModel.coolingTemperatureHysteresis,
                       0...20, 1, "%.0f °C")
                slider("Confirmation", $viewModel.coolingConfirmationSeconds,
                       0...60, 1, "%.0f s")
                slider("Min change", $viewModel.minimumCommandChangePercent,
                       0...20, 1, "%.0f %%")
            }

            // One global battery derating, applied to the demand after the curve is
            // sampled. It has to be a single visible switch: a derate buried in one
            // stage of the pipeline silently changes the outcome of every other knob.
            Toggle("Reduce demand 25% on battery", isOn: $viewModel.reduceFansOnBattery)
                .font(DS.ui(11))
                .tint(DS.warn)
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Curve → % → fans. Rise/Fall cap how fast that % can move per second; Min change ignores tiny moves. This stops fans fluttering.")
                .font(DS.ui(10))
                .foregroundColor(DS.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let pct = viewModel.currentCommandedPercent {
                Text("Now commanding \(Int(pct.rounded()))%")
                    .font(DS.mono(11))
                    .foregroundColor(viewModel.isCurveEngineEnabled ? DS.fan : DS.tertiary)
            } else {
                Text(viewModel.controlMode == .macOS
                     ? "macOS owns the fans — tuning has no effect until Curve is chosen"
                     : "Waiting for a valid reading…")
                    .font(DS.mono(11))
                    .foregroundColor(DS.tertiary)
            }
            if !compact {
                Text("Above \(Int(CommandFilter.emergencyBypassPercent))% demand the limits are bypassed — the fans go where the temperature asks, immediately.")
                    .font(DS.ui(10))
                    .foregroundColor(DS.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Presets are pure limiter tuples: they set the five knobs and nothing else —
    /// no engine switch, no SMC write.
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: DS.s1) {
            HStack(spacing: DS.s2) {
                ForEach(FanResponsePreset.allCases, id: \.self) { preset in
                    Button {
                        viewModel.apply(preset)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: viewModel.matches(preset) ? "checkmark.circle.fill" : "circle")
                                .font(DS.ui(10))
                                .foregroundColor(viewModel.matches(preset) ? DS.fan : DS.tertiary)
                            Text(preset.displayName)
                                .font(DS.ui(11))
                                .foregroundColor(viewModel.matches(preset) ? DS.text : DS.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !compact {
                Text("Presets only move the five sliders above. They do not change which sensor the curve follows or which fans are pinned.")
                    .font(DS.ui(10))
                    .foregroundColor(DS.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ step: Double, _ format: String) -> some View {
        LabeledRow(label: title, value: String(format: format, value.wrappedValue)) {
            Slider(value: value, in: range, step: step)
                .tint(DS.accent)
        }
    }
}
