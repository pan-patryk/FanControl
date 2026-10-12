import SwiftUI

// MARK: - Individual Fan Control Row
//
// One row per fan: animated indicator, name + live RPM, a duty meter, and
// the mode control. Manual mode reveals the slider, target and presets.

struct FanRow: View, Equatable {
    let fan: FanJSON
    // Plain closures instead of an @ObservedObject on the view model: observing
    // the view model here would re-render (and re-lay-out) every row on every
    // poll, regardless of whether this fan changed. With value inputs only,
    // Equatable lets SwiftUI prune unchanged rows from the layout pass.
    let onChangeMode: (Int) -> Void
    let onChangeSpeed: (Int) -> Void
    let compactLayout: Bool
    /// Whether the **user** pinned this fan. Not `fan.mode`: the SMC reports forced
    /// mode for every engine-driven fan, so `mode == 1` would make all six rows look
    /// like manual overrides and none of them like macOS control.
    let pinned: Bool

    @State private var sliderVal: Double = 0.0
    @State private var isEditingSlider: Bool = false

    init(fan: FanJSON, viewModel: FanViewModel, compactLayout: Bool = false) {
        self.fan = fan
        self.pinned = viewModel.isPinned(fan.id)
        // Captured by reference for the row's actions; deliberately not part of
        // the equality check below, which is what keeps unchanged rows quiet.
        self.onChangeMode = { mode in viewModel.changeFanMode(fanId: fan.id, mode: mode) }
        self.onChangeSpeed = { speed in viewModel.changeFanSpeed(fanId: fan.id, speed: speed) }
        self.compactLayout = compactLayout
        // Initial setup of state
        // Clamped into the usable range: `targetSpeed` can legitimately sit below
        // `minSpeed` (macOS idling the fan), and an out-of-range initial value makes
        // the slider render at 0 and then jump when first touched.
        _sliderVal = State(initialValue: FanRow.bounded(Double(fan.targetSpeed), fan: fan))
    }

    // Only the fan's data drives a redraw; the closures are excluded.
    static func == (lhs: FanRow, rhs: FanRow) -> Bool {
        lhs.fan == rhs.fan
            && lhs.compactLayout == rhs.compactLayout
            && lhs.pinned == rhs.pinned
    }

    static func bounded(_ rpm: Double, fan: FanJSON) -> Double {
        min(max(rpm, Double(fan.minSpeed)), Double(max(fan.maxSpeed, fan.minSpeed + 1)))
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.s3) {
            SpinningFanView(currentSpeed: Double(fan.currentSpeed), maxSpeed: Double(fan.maxSpeed))
                .frame(width: compactLayout ? 48 : 60, height: compactLayout ? 48 : 60)

            VStack(alignment: .leading, spacing: DS.s2) {
                HStack(alignment: .firstTextBaseline, spacing: DS.s3) {
                    Text(fan.name)
                        .font(DS.ui(compactLayout ? 12 : 13, .semibold))
                        .foregroundColor(DS.text)

                    HStack(spacing: DS.s2) {
                        Text("\(fan.currentSpeed)")
                            .font(DS.mono(compactLayout ? 15 : 17, .bold))
                            .foregroundColor(valueTint)
                        Text("rpm")
                            .font(DS.ui(10, .medium))
                            .foregroundColor(DS.tertiary)
                    }

                    Meter(value: currentRatio, height: 5, tint: valueTint)
                        .frame(width: compactLayout ? 80 : 120)

                    Text(percentText)
                        .font(DS.mono(11))
                        .foregroundColor(DS.secondary)
                        .frame(width: 44, alignment: .trailing)

                    Spacer(minLength: DS.s2)

                    Picker("", selection: Binding(
                        get: { pinned ? 1 : 0 },
                        set: { newMode in onChangeMode(newMode) }
                    )) {
                        Text("Auto").tag(0)
                        Text("Manual").tag(1)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .labelsHidden()
                    .frame(width: compactLayout ? 120 : 140)
                }

                if pinned {
                    targetControls
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if !compactLayout {
                    Text(ownershipLine)
                        .font(DS.ui(11))
                        .foregroundColor(DS.tertiary)
                }
            }
        }
        .padding(DS.s3)
        .background(DS.inset)
        .clipShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        // Keep slider synchronized with system status updates if user is not
        // actively dragging it.
        .onChange(of: fan.targetSpeed) { newTarget in
            // Follow the hardware while the user isn't dragging, but stay inside the
            // slider's own range — an out-of-range target pins the thumb to the left
            // end until the next edit.
            if !isEditingSlider {
                sliderVal = Self.bounded(Double(newTarget), fan: fan)
            }
        }
    }

    // MARK: - Manual target controls

    private var targetControls: some View {
        VStack(spacing: DS.s2) {
            HStack(spacing: DS.s3) {
                Slider(
                    value: Binding(get: { Self.bounded(sliderVal, fan: fan) },
                                   set: { sliderVal = $0 }),
                    in: Double(fan.minSpeed)...Double(max(fan.maxSpeed, fan.minSpeed + 1)),
                    step: 50.0,
                    onEditingChanged: { editing in
                        isEditingSlider = editing
                        if !editing {
                            onChangeSpeed(Int(sliderVal))
                        }
                    }
                )
                .tint(DS.fan)

                Text("\(Int(sliderVal)) rpm  ·  \(Int(speedPercentage))%")
                    .font(DS.mono(11))
                    .foregroundColor(DS.secondary)
                    .frame(minWidth: 110, alignment: .trailing)
            }

            HStack(spacing: DS.s2) {
                preset("Min") { Double(fan.minSpeed) }
                preset("20%") { getSpeedForPercentage(0.20) }
                preset("50%") { getSpeedForPercentage(0.50) }
                preset("80%") { getSpeedForPercentage(0.80) }
                preset("Max") { Double(fan.maxSpeed) }
            }
        }
    }

    private func preset(_ title: String, _ value: @escaping () -> Double) -> some View {
        Button(title) {
            let v = value()
            sliderVal = v
            onChangeSpeed(Int(v))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Metrics

    /// What owns this fan, in one line. Derived from the app's pin set, never from
    /// the SMC `mode` byte, which reads "manual" for every engine-driven fan.
    var ownershipLine: String {
        pinned
            ? "Pinned by you — the engines leave it alone. Press Auto to release."
            : "Not pinned — macOS thermal control runs it unless an engine is applied."
    }

    /// 0…1 through the usable range — the same definition the engine writes with.
    /// Dividing by `maxSpeed` would make a fan at its minimum read ~30 %.
    var currentRatio: Double {
        FanPercentage.fraction(of: fan, rpm: fan.currentSpeed)
    }

    var valueTint: Color {
        let ratio = currentRatio
        if ratio > 0.8 { return DS.warn }
        if ratio > 0.35 { return DS.fan }
        return DS.tertiary
    }

    var percentText: String {
        "\(Int((currentRatio * 100).rounded()))%"
    }

    /// Slider position as a percentage of the usable range, matching the same
    /// definition the label and the buttons use.

    var speedPercentage: Double {
        let range = Double(fan.maxSpeed - fan.minSpeed)
        guard range > 0 else { return 0 }
        return ((sliderVal - Double(fan.minSpeed)) / range) * 100.0
    }

    func getSpeedForPercentage(_ pct: Double) -> Double {
        let range = Double(fan.maxSpeed - fan.minSpeed)
        return Double(fan.minSpeed) + range * pct
    }
}
