import SwiftUI
import Combine

// MARK: - Main Content View
//
// Stock macOS dark layout: header with status pills, then cards in reading
// order — history, setup, fans, fan control, fan response, footer
// controls. All chrome comes from the DS design system.

struct ContentView: View {
    @ObservedObject var viewModel: FanViewModel

    /// Clock driving the history chart's right edge. Ten seconds is coarse enough
    /// that the chart re-lays-out 6×/minute instead of once per sensor poll, and
    /// fine enough that the trace never looks frozen (see `TempHistoryChartView.now`).
    @State private var chartClock = Date()
    private static let clock: Publishers.Autoconnect<Timer.TimerPublisher> =
        Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            let compactLayout = geometry.size.height < 900
            let padding: CGFloat = compactLayout ? 14 : 20

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, padding)
                    .padding(.top, DS.s4)
                    .padding(.bottom, DS.s4)

                Divider()

                ScrollView {
                    LazyVStack(spacing: DS.s4) {
                        TempHistoryChartView(history: viewModel.tempHistory,
                                             compactLayout: compactLayout,
                                             now: chartClock)
                            .equatable()

                        if !viewModel.canWrite {
                            setupCard
                        }

                        if viewModel.canWrite, let error = viewModel.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(DS.ui(12))
                                .foregroundColor(DS.error)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if viewModel.fans.isEmpty {
                            HStack(spacing: DS.s2) {
                                ProgressView().controlSize(.small)
                                Text("Reading SMC registers…")
                                    .font(DS.ui(12))
                                    .foregroundColor(DS.secondary)
                            }
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                            .background(DS.cardFill)
                            .clipShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
                                    .stroke(DS.cardLine, lineWidth: 1)
                            )
                        } else {
                            Card("Fans", icon: "fan.fill", tint: DS.fan) {
                                VStack(spacing: DS.s3) {
                                    ForEach(viewModel.fans) { fan in
                                        FanRow(
                                            fan: fan,
                                            viewModel: viewModel,
                                            compactLayout: compactLayout
                                        )
                                        .equatable()
                                        if fan.id != viewModel.fans.last?.id {
                                            Divider()
                                        }
                                    }

                                    if viewModel.canWrite && viewModel.fans.count > 1 {
                                        Divider()
                                        Toggle("Sync all fans together", isOn: $viewModel.linkedFans)
                                            .font(DS.ui(12))
                                    }
                                }
                            }
                        }

                        if viewModel.canWrite && !viewModel.fans.isEmpty {
                            // Same rule as the menu panel: one authority picker, and
                            // only the editor for the engine that holds the fans.
                            // Showing an editor for an engine that cannot write makes
                            // two controls look live at once.
                            Card("Fan control", icon: "chart.xyaxis.line", tint: DS.accent) {
                                VStack(alignment: .leading, spacing: DS.s3) {
                                    Picker("", selection: $viewModel.controlMode) {
                                        ForEach(ControlMode.allCases) { mode in
                                            Text(mode.shortLabel).tag(mode)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.segmented)
                                    .frame(maxWidth: 320)

                                    switch viewModel.controlMode {
                                    case .macOS:
                                        HStack(alignment: .top, spacing: DS.s3) {
                                            Image(systemName: "leaf.fill")
                                                .foregroundColor(DS.accent)
                                            Text("Running stock macOS temperature settings. FanCurve is reading sensors for the graphs and history, but thermalmonitord decides how fast the fans spin.")
                                                .font(DS.ui(11))
                                                .foregroundColor(DS.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    case .curve:
                                        CurveEditorView(viewModel: viewModel)
                                            .padding(DS.s2)
                                    }

                                    if let ownership = viewModel.ownershipText() {
                                        Label(ownership, systemImage: "pin.fill")
                                            .font(DS.ui(11))
                                            .foregroundColor(DS.warn)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        // The limiter knobs, in the window too — they are the only
                        // way to change how fast the engine moves the fans.
                        if viewModel.controlMode == .curve {
                            Card("Fan response", icon: "waveform.path", tint: DS.accent) {
                                FanResponseSettingsView(viewModel: viewModel)
                            }
                        }

                        // Startup curve: which curve the app comes up with. Without
                        // it, a saved custom curve has to be re-selected every launch.
                        StartWithCurvePicker(viewModel: viewModel)
                            .padding(.vertical, DS.s1)
                        RestoreDefaultProfilesButton(viewModel: viewModel)

                        if viewModel.canWrite && !viewModel.fans.isEmpty {
                            // Registration is verified by re-reading
                            // `SMAppService.status` inside the setter, so a
                            // rejected registration can't leave the switch on.
                            Toggle("Start at login (background)", isOn: Binding(
                                get: { viewModel.isAutoStart },
                                set: { viewModel.setAutoStart($0) }
                            ))
                            .font(DS.ui(12))
                        }
                    }
                    .padding(.horizontal, padding)
                    .padding(.vertical, DS.s4)
                }
            }
        }
        .onReceive(Self.clock) { chartClock = $0 }
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity, alignment: .top)
        .background(DS.window)
        .background(WindowAccessor { window in
            // This accessor must not replace the delegate SwiftUI installed for the
            // Settings scene. It owns the window's min size and nothing else — the
            // `onAppear`/`onDisappear` pair above is the only thing that reports
            // visibility, and a stolen delegate would leave the gate stuck open,
            // re-laying out a hidden 360×600 panel once per second.
            window.minSize = NSSize(width: 620, height: 700)
        })
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: DS.s2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FanCurve — \(headerTitle)")
                    .font(.system(size: 17, weight: .bold))
                Text(viewModel.controlState.detail)
                    .font(DS.ui(11))
                    .foregroundColor(DS.secondary)
                    .lineLimit(1)
            }
            Spacer()
            StatusPill(label: serviceText, tint: serviceTint)
            StatusPill(
                label: viewModel.isOnACPower ? "AC power" : "On battery",
                tint: viewModel.isOnACPower ? DS.tertiary : DS.warn
            )
        }
    }

    private var serviceTint: Color {
        if !viewModel.canWrite { return DS.warn }
        if viewModel.controlServiceActive || viewModel.isAuthorized { return DS.fan }
        return DS.tertiary
    }

    private var serviceText: String {
        if !viewModel.canWrite { return "Setup required" }
        if viewModel.controlServiceActive { return "Control service live" }
        return "Helper authorized"
    }

    /// Title + detail + pin count, from one source of truth — the same
    /// `controlState` the menu panel's header reads, so the two surfaces cannot
    /// disagree about who owns the fans.
    private var headerTitle: String {
        viewModel.controlState.title
    }

    // MARK: - One-time setup card

    private var setupCard: some View {
        Card("Fan control setup", icon: "lock.shield", tint: DS.warn) {
            VStack(alignment: .leading, spacing: DS.s3) {
                Text("FanCurve controls fans through a small background service with admin rights. Install it once — after that, nothing ever asks for a password again, and rebuilding the app never breaks it.")
                    .font(DS.ui(12))
                    .foregroundColor(DS.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(DS.ui(12, .medium))
                        .foregroundColor(DS.error)
                }

                HStack(spacing: DS.s3) {
                    Button("Install Control Service…") {
                        withAnimation { viewModel.installControlService() }
                    }
                    .dsProminent()

                    Button("Use bundled helper instead") {
                        withAnimation { viewModel.authorize() }
                    }
                    .dsSmall()
                }
            }
        }
    }
}

// MARK: - Window Accessor and Delegate for Menu Bar Mode
struct WindowAccessor: NSViewRepresentable {
    var onWindowBind: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindowBind(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
