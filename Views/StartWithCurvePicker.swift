import SwiftUI

// MARK: - "Start with" curve setting
//
// Which curve the app selects when it starts, instead of the last-used one.
// Shown in the panel's Settings section and in the settings window: the same
// list, the same binding, one definition (both hosts must agree on what a
// "curve" is — presets are shapes derived from the sensor, saved entries are
// the user's own curves).
struct StartWithCurvePicker: View {
    @ObservedObject var viewModel: FanViewModel

    var body: some View {
        HStack(spacing: DS.s2) {
            Text("Start with")
                .font(DS.ui(11, .medium))
                .foregroundColor(DS.secondary)
            Spacer(minLength: DS.s2)
            Picker("", selection: $viewModel.startupCurveID) {
                Text("Last used").tag("")
                ForEach(FanCurve.presets(for: viewModel.curveSensor)) { preset in
                    Text(preset.name).tag(preset.id)
                }
                ForEach(viewModel.userCurves) { curve in
                    Text(curve.name).tag(curve.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            .help(L10n.text("Which curve the app selects when it starts. Leave it on Last used to keep what you had."))
        }
    }
}
