import SwiftUI
import AppKit

// MARK: - Interactive fan controls
//
// The two sliders in the panel's Fans section. Both apply on *release*, not per drag
// tick: applying during the drag would invoke the helper on every pixel of movement.
// Both are user commands, so both register a pin — see `CommandSource.userAllFans`
// and `FanViewModel.changeFanSpeed`.

/// Per-fan RPM slider across the fan's physical range. While dragging, the label
/// shows the draft value.
struct FanRPMSlider: View {
    let fan: FanJSON
    var pinned: Bool = false
    @ObservedObject var viewModel: FanViewModel
    @State private var draft: Double?

    private var display: Double { draft ?? Double(fan.targetSpeed) }
    private var range: ClosedRange<Double> {
        let lo = Double(fan.minSpeed)
        return lo...max(Double(fan.maxSpeed), lo + 1)
    }

    var body: some View {
        HStack(spacing: DS.s3) {
            Slider(
                value: Binding(
                    get: { display },
                    set: { draft = $0 }
                ),
                in: range,
                step: 50,
                onEditingChanged: { editing in
                    if !editing, let target = draft {
                        viewModel.changeFanSpeed(fanId: fan.id, speed: Int(target))
                        draft = nil
                    }
                }
            )
            .tint(DS.fan)
            Text("\(pinned ? "⏸" : fan.name)  \(Int(display)) rpm")
                .font(DS.mono(11))
                .foregroundColor(DS.secondary)
                .frame(width: 130, alignment: .trailing)
        }
    }
}

/// All-fans percentage slider: drag to a target, release to apply.
///
/// Releasing is an explicit user command, so it registers a pin on every fan it
/// writes. Without a pin, the running engine takes the value back on the next tick
/// and the control appears broken.
struct AllFansSlider: View {
    @ObservedObject var viewModel: FanViewModel
    @State private var draft: Double = 50
    @State private var isEditing = false

    /// What the fans are actually set to, so after tuning a single fan the sync
    /// slider tracks that rather than a stale default. Releasing it applies the
    /// current value to all fans.
    private var trackedPercent: Double {
        // Same formula the engine writes with — `min + p·(max-min)` over the usable
        // range. `targetSpeed / maxSpeed` would report a fan held at its minimum as
        // ~30 % and make this slider disagree with the row beneath it.
        let pct = viewModel.fans.map { FanPercentage.targetPercent(of: $0) ?? 0 }
        return pct.isEmpty ? draft : pct.reduce(0, +) / Double(pct.count)
    }

    var body: some View {
        HStack(spacing: DS.s3) {
            Slider(
                value: Binding(
                    get: { isEditing ? draft : trackedPercent },
                    set: { draft = $0 }
                ),
                in: 0...100,
                step: 5,
                onEditingChanged: { editing in
                    isEditing = editing
                    if !editing {
                        viewModel.setAllToPercentage(draft / 100, source: .userAllFans)
                    }
                }
            )
            .tint(DS.fan)
            Text("All fans  \(Int(isEditing ? draft : trackedPercent))%")
                .font(DS.mono(11))
                .foregroundColor(DS.secondary)
                .frame(width: 110, alignment: .trailing)
        }
    }
}
