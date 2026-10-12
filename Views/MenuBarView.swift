import SwiftUI
import AppKit

// MARK: - Menu-bar panel
//
// Presented as a `.window`-style MenuBarExtra: a real panel, not an NSMenu.
// The reason is behavioural — in a classic menu, *every* item selection
// (apply a curve, set a fan, drag a slider) dismisses the whole menu, so tuning
// means reopen-tap-reopen forever. In a panel, none of the actions close it:
// sliders stay draggable, toggles stay put, and only clicking outside (or
// Escape) dismisses it.

struct MenuBarView: View {
    @ObservedObject var viewModel: FanViewModel

    // Accordion open/closed state. Fan control starts open — it is the tuning
    // surface; the rest stay tucked away until asked, so the 24 h charts and the
    // per-fan sliders cost no layout until their section is expanded.
    @State private var showCurves = true
    @State private var showFans = false
    @State private var showTuning = false
    @State private var showSensors = false
    @State private var showSettings = false
    /// Natural height of the panel's content (measured from inside the scroll
    /// view), so the panel can adopt it instead of a fixed frame.
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s2) {
                header

                Divider()

                if !viewModel.canWrite {
                    HStack(spacing: DS.s3) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(DS.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fan control not installed")
                                .font(DS.ui(12, .semibold))
                            Text("One-time admin install — then it never asks again.")
                                .font(DS.ui(11))
                                .foregroundColor(DS.secondary)
                        }
                        Spacer()
                        Button("Install") {
                            viewModel.installControlService()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(DS.s3)
                    .background(
                        RoundedRectangle(cornerRadius: DS.radius)
                            .fill(DS.warn.opacity(0.12))
                    )
                }

                section("Sensors (24 h)", systemImage: "thermometer.medium", isExpanded: $showSensors) {
                    sensors24h
                }
                section("Fan control", systemImage: "chart.xyaxis.line", isExpanded: $showCurves) {
                    // Which engine owns the fans. One picker, one piece of state: two
                    // mutually-exclusive switches would be `didSet` hooks resetting
                    // each other, so turning one on could silently turn the other off
                    // mid-edit.
                    Picker("", selection: $viewModel.controlMode) {
                        ForEach(ControlMode.allCases) { mode in
                            Text(mode.shortLabel).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    switch viewModel.controlMode {
                    case .macOS:
                        controlModeNote(
                            icon: "leaf.fill",
                            title: "Running stock macOS temperature settings",
                            text: "FanCurve is not commanding the fans — thermalmonitord decides their speed, and nothing here changes that. Choose Curve to take over.")
                    case .curve:
                        CurveEditorView(viewModel: viewModel, compact: true)
                    }

                    // "Pinned" means *the user* pinned it, from the app's own pin set.
                    // The SMC's `mode == 1` is true for every engine-driven fan, so it
                    // cannot distinguish a pin from a curve command.
                    if let ownership = viewModel.ownershipText() {
                        Label(ownership, systemImage: "pin.fill")
                            .font(DS.ui(10))
                            .foregroundColor(DS.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                section("Fans", systemImage: "fan.fill", isExpanded: $showFans) {
                    fans
                }
                // The five response knobs are the command limiter's parameters, so they
                // only exist while something is commanding. Under macOS mode there is
                // nothing to tune.
                if viewModel.controlMode != .macOS {
                    section("Tuning", systemImage: "waveform.path", isExpanded: $showTuning) {
                        tuning
                    }
                }
                section("Settings", systemImage: "gearshape", isExpanded: $showSettings) {
                    settings
                }

                Divider()

                HStack {
                    Spacer()
                    Button("Quit") { viewModel.terminate() }
                        .buttonStyle(.borderless)
                        .foregroundColor(.red)
                        .font(DS.ui(12, .medium))
                }
            }
            .padding(DS.s3)
            // `.fixedSize(vertical:)` makes the measured height the content's own
            // natural height — independent of the scroll view's viewport, which is
            // what lets the panel below size itself to it.
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: PanelContentHeightKey.self, value: geo.size.height)
                }
            )
        }
        // Adaptive sizing: the panel adopts its content's height (collapsed
        // sections leave no dead space) and only caps where the screen cannot
        // show more; beyond the cap the ScrollView scrolls.
        .onPreferenceChange(PanelContentHeightKey.self) { naturalHeight = $0 }
        .frame(width: 360, height: panelHeight)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: panelHeight)
        .clipped()
        .background(DS.window)
        .onAppear { viewModel.setMenuOpen(true) }
        .onDisappear { viewModel.setMenuOpen(false) }
    }

    /// Adopt the content's measured height, capped to what the current screen
    /// can actually show below the menu bar. The floor keeps a just-opened
    /// panel readable until the first measurement lands.
    private var panelHeight: CGFloat {
        let cap = maxPanelHeight
        guard naturalHeight > 0 else { return Swift.min(320, cap) }
        return Swift.min(naturalHeight, cap)
    }

    /// Screen-safe cap: what the current display can show below the menu bar.
    private var maxPanelHeight: CGFloat {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 700
        return Swift.min(600, Swift.max(320, visible - 40))
    }

    /// The natural height of the panel's content, reported from inside the
    /// scroll view so the panel can size itself to it.
    private struct PanelContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    // MARK: - Header: who has control, and the thermal picture

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            // Control-state readout, deliberately NOT clickable: tapping the header
            // must never open the settings window. Nothing in the panel opens it —
            // the window is reachable when the app is an ordinary app instead
            // (accessory mode off: the app menu's Settings…, or ⌘,).
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.controlState.title)
                    .font(DS.ui(13, .semibold))
                    .foregroundColor(statusTint)
                Text(viewModel.controlState.detail)
                    .font(DS.ui(10))
                    .foregroundColor(DS.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(viewModel.fans) { fan in
                HStack(spacing: DS.s2) {
                    Text(fan.name)
                        .font(DS.ui(11, .medium))
                        .frame(width: 40, alignment: .leading)
                    Text("\(fan.currentSpeed) rpm")
                        .font(DS.mono(11))
                        .foregroundColor(fanTint(fan))
                    Spacer()
                }
            }

            HStack(spacing: DS.s2) {
                Text("CPU \(Gauge.temp(viewModel.cpuTemp))   GPU \(Gauge.temp(viewModel.gpuTemp))   BAT \(Gauge.temp(viewModel.batteryTemp))")
                    .font(DS.mono(11))
                    .foregroundColor(DS.secondary)
                Spacer()
            }

            Text(batteryCaption)
                .font(DS.ui(10, .medium))
                .foregroundColor(viewModel.isOnACPower ? DS.tertiary : DS.warn)
        }
    }

    private var batteryCaption: String {
        if viewModel.isOnACPower { return "AC power" }
        return viewModel.reduceFansOnBattery
            ? "On battery — demand reduced 25%"
            : "On battery — no derating"
    }

    private var statusTint: Color {
        if !viewModel.canWrite { return DS.warn }
        if viewModel.controlServiceActive || viewModel.isAuthorized { return DS.fan }
        return DS.text
    }

    /// 0…1 through the fan's **usable** range (`minSpeed…maxSpeed`), the same
    /// definition every slider and the engine use. Dividing by `maxSpeed` would make a
    /// fan sitting at its minimum look already spun down.
    private func fanRatio(_ fan: FanJSON) -> Double {
        FanPercentage.fraction(of: fan, rpm: fan.currentSpeed)
    }

    private func fanTint(_ fan: FanJSON) -> Color {
        let ratio = fanRatio(fan)
        if ratio > 0.8 { return DS.warn }
        if ratio > 0.35 { return DS.fan }
        return DS.tertiary
    }

    // MARK: - Accordion section

    /// The "nothing to tune here" card: what the chosen mode actually does, in its own
    /// words, instead of leaving a graph of an inactive engine on screen.
    private func controlModeNote(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: DS.s3) {
            Image(systemName: icon)
                .font(DS.ui(13))
                .foregroundColor(DS.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.ui(11, .semibold))
                Text(text)
                    .font(DS.ui(10))
                    .foregroundColor(DS.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.s3)
        .background(RoundedRectangle(cornerRadius: DS.radius).fill(DS.accent.opacity(0.10)))
    }

    private func section(
        _ title: String,
        systemImage: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        // Smooth accordion: route the toggle through a spring so expand/collapse
        // eases instead of snapping.
        let animated = Binding(
            get: { isExpanded.wrappedValue },
            set: { newValue in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    isExpanded.wrappedValue = newValue
                }
            }
        )
        return DisclosureGroup(isExpanded: animated) {
            content()
                .padding(.leading, DS.s4)
                .padding(.top, DS.s1)
        } label: {
            HStack(spacing: DS.s2) {
                Image(systemName: systemImage)
                    .font(DS.ui(10, .semibold))
                    .foregroundColor(DS.accent)
                Text(title)
                    .font(DS.ui(12, .semibold))
            }
        }
    }

    // MARK: - Fans (per-fan manual control + all-fans override)

    private var fans: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            ForEach(viewModel.fans) { fan in
                // Ownership comes from the app's own pin set, never from the SMC
                // `mode` byte: an engine-driven fan is in forced mode by definition, so
                // the mode byte would read every curve command as a manual override.
                let pinned = viewModel.isPinned(fan.id)
                VStack(alignment: .leading, spacing: DS.s1) {
                    HStack(spacing: DS.s2) {
                        Button("Auto") {
                            viewModel.changeFanMode(fanId: fan.id, mode: 0)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        // Bright + green while macOS owns the fan; amber while the
                        // user pinned it (tap Auto to release).
                        .tint(pinned ? Color.secondary : DS.fan)
                        Text("\(fan.name) — \(fan.currentSpeed) rpm")
                            .font(DS.mono(11))
                            .foregroundColor(pinned ? DS.warn : DS.text)
                        Spacer()
                        if pinned {
                            Text("pinned")
                                .font(DS.ui(9, .medium))
                                .foregroundColor(DS.warn)
                        }
                    }
                    FanRPMSlider(fan: fan, pinned: pinned, viewModel: viewModel)
                        .opacity(pinned ? 0.75 : 1)
                }
            }
            // Bright when on, dim when off — the state reads at a glance.
            Toggle("Sync all fans together", isOn: $viewModel.linkedFans)
                .font(DS.ui(11))
                .tint(DS.fan)
                .opacity(viewModel.linkedFans ? 1 : 0.45)

            AllFansSlider(viewModel: viewModel)
            HStack(spacing: DS.s2) {
                ForEach([0.20, 0.40, 0.50, 0.80, 1.00], id: \.self) { pct in
                    Button("\(Int(pct * 100))%") {
                        // An explicit user command: it pins the fans, so the engine
                        // cannot overwrite it on the next tick.
                        viewModel.setAllToPercentage(pct, source: .userAllFans)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
    }

    // MARK: - Tuning (command limiter knobs)

    /// The command limiter's knobs, in one shared view (`FanResponseSettingsView`)
    /// that the settings window also uses.
    private var tuning: some View {
        FanResponseSettingsView(viewModel: viewModel, compact: true)
    }

    // MARK: - 24 h sensor history: a real, minimal graph

    private var sensors24h: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            // `.equatable()`: each chart decimates the whole history, so the panel's
            // per-second poll must not re-run that scan unless a record landed.
            ForEach(Array([(sensor: "CPU", color: Color.orange, key: \TempRecord.cpu),
                           (sensor: "GPU", color: Color.purple, key: \TempRecord.gpu),
                           (sensor: "BAT", color: Color.cyan, key: \TempRecord.battery)]), id: \.sensor) { series in
                SensorHistoryChart(history: viewModel.tempHistory, sensor: series.sensor,
                                   color: series.color, value: series.key)
                    .equatable()
            }
        }
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            // The binding reads `SMAppService.status` back after every attempt, so a
            // rejected registration cannot show up as a success.
            Toggle("Start at login (background)", isOn: Binding(
                get: { viewModel.isAutoStart },
                set: { viewModel.setAutoStart($0) }
            ))
            .font(DS.ui(12))
            Toggle("Run in accessory mode", isOn: $viewModel.runInAccessoryMode)
                .font(DS.ui(12))
            Toggle("Show RPM in menu bar", isOn: $viewModel.showsRPMInMenuBar)
                .font(DS.ui(12))

            Divider()
            StartWithCurvePicker(viewModel: viewModel)
            RestoreDefaultProfilesButton(viewModel: viewModel)

            // Which build this actually is. `CFBundleVersion` carries a stamp of the
            // source tree, so a fresh build and a stale installed copy can be told
            // apart without opening Terminal.
            Divider()
            Text(Self.buildStamp)
                .font(DS.mono(10))
                .foregroundColor(DS.tertiary)
                .textSelection(.enabled)
        }
    }

    /// "FanCurve 1.0.0 (202610091317)" — short version plus the build stamp, with the
    /// control-service state on the same line, since that is the other thing that
    /// survives a rebuild and can therefore be stale.
    static var buildStamp: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        return "FanCurve \(version) (\(build))"
    }
}
