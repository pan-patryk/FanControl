import SwiftUI
import Charts
import AppKit
import Combine

// MARK: - Curve Editor (the XY graph)
//
// x = temperature (°C), y = fan speed (%).
//   • left-drag a knot → move it (pure SwiftUI DragGesture)
//   • tap empty space  → add a knot there
//   • RIGHT-CLICK a knot → delete it (passive NSEvent monitor — no hit-test
//     interference with the drag gesture; the click is converted into the
//     chart's own window-content space, never a guessed screen space)
//   • the orange dot shows where the machine sits on the curve right now
//   • edits land in an unsaved draft; a green tick and a red cross beside the
//     profile selector commit or revert it in one click
//
// Anti-flicker: the chart is an Equatable subview whose inputs are (knots,
// dragging id, *smoothed* operating point). Per-second sensor noise that
// doesn't move the dot a visible step produces zero re-plots.

struct CurveEditorView: View {
    @ObservedObject var viewModel: FanViewModel
    var compact: Bool = false

    /// Axis scale follows the selected sensor (silicon 30–110°, battery 5–60°).
    private var xDomain: ClosedRange<Double> {
        FanCurve.xDomain(for: curve.sensor)
    }

    /// Live position of the knot being dragged, held in LOCAL state and
    /// committed to the view model only on release. (Publishing on every mouse
    /// event re-rendered the whole panel 60×/s — the "jumps of view" you saw.)
    @State private var dragLive: (id: UUID, x: Double, y: Double)? = nil
    /// Smoothed operating point (glides in small steps, see blendDot).
    @State private var dot: (x: Double, y: Double)? = nil
    /// Plot area in SCREEN coordinates, for the right-click monitor.
    @State private var plotScreenRect: CGRect = .zero
    @State private var rightClickMonitor: Any? = nil
    /// "New profile…" — shows the inline naming row. Inline, not an alert: this
    /// view lives in a `MenuBarExtra(.window)` panel under `.accessory` activation,
    /// where an alert raised from a `Menu` item has no key window to attach to.
    @State private var promptingNewProfile = false
    @State private var newProfileName: String = ""
    @FocusState private var newProfileFieldFocused: Bool

    /// The operating dot's own clock — a *shared* one, exactly like the settings
    /// window's history clock. An instance `Timer.publish(…).autoconnect()`
    /// property schedules a brand-new timer every time SwiftUI re-creates this
    /// struct (which happens on every panel re-render), so old timers piled up
    /// with nobody draining them. One static timer, one subscription per editor.
    ///
    /// It has to be a timer rather than "whatever re-renders the panel", because
    /// the dot is read from canonical control state (`viewModel.currentCurvePoint`)
    /// which is deliberately *not* published — that is what keeps the closed panel
    /// from re-laying-out at 1 Hz. 1 s matches the control loop's cadence so the
    /// dot moves in real time while the editor is open.
    private static let dotClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var curve: FanCurve {
        viewModel.activeCurve ?? FanCurve.balanced
    }

    private var sortedPoints: [CurvePoint] {
        curve.points.sorted { $0.x < $1.x }
    }

    /// What the chart draws: the saved knots, with the one being dragged
    /// replaced by its live position (smooth 60 fps feedback without touching
    /// the view model until release).
    private var displayPoints: [CurvePoint] {
        guard let live = dragLive else { return sortedPoints }
        return sortedPoints.map { point in
            point.id == live.id ? CurvePoint(id: live.id, x: live.x, y: live.y) : point
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            // Row 1: the profile selector. The curve picker that used to sit beside it
            // is gone: a profile already names a curve, a sensor and the five response
            // knobs, so the two controls showed the same four words with different
            // meanings. Selecting, adding and removing all happen here. The
            // save/discard pair sits beside the menu: after choosing a profile the
            // decision visibly applies to the curve that profile points at.
            HStack(spacing: DS.s2) {
                Text("Profile:")
                    .font(DS.ui(11, .medium))
                    .foregroundColor(DS.secondary)
                profileMenu
                draftButtons
                Spacer(minLength: DS.s2)
            }

            // Naming happens inline, not in an alert. This view lives in a
            // `MenuBarExtra(.window)` panel under `.accessory` activation: choosing
            // "New profile…" ends the `NSMenu`'s tracking session, the panel loses key
            // status, and the alert is then presented by a window that is going away —
            // so the app looked like it had hidden itself. An inline row has no window
            // to lose.
            if promptingNewProfile {
                HStack(spacing: DS.s2) {
                    TextField("Name for new profile", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.ui(11))
                        .focused($newProfileFieldFocused)
                        .onSubmit(commitNewProfile)
                    Button("Save") { commitNewProfile() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Cancel") { cancelNewProfile() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundColor(DS.secondary)
                }
                .onAppear { newProfileFieldFocused = true }
                Text("Saves the curve, sensor and response settings you are using now.")
                    .font(DS.ui(10))
                    .foregroundColor(DS.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Row 2: what the curve samples. Labelled buttons instead of bare icons —
            // four glyphs with no names read as decoration, and the row is the one
            // thing a first-time user has to decode.
            HStack(spacing: DS.s2) {
                Text("Mode:")
                    .font(DS.ui(11, .medium))
                    .foregroundColor(DS.secondary)
                ForEach(sensorChoices) { choice in
                    sensorButton(choice)
                }
            }

            // The curve's own name field, save and delete row is gone: the profile
            // menu above now owns naming, and a saved curve is reachable only through
            // the profile that points at it.

            chart
                .frame(height: compact ? 180 : 260)

            pointChips

            HStack {
                // Deliberately not a toggle: which engine owns the fans is decided in
                // exactly one place, the mode picker. A second switch here would be a
                // second writer to the same authority.
                Label(viewModel.controlMode == .curve ? "Curve is applied" : "Not applied — choose Curve above",
                      systemImage: viewModel.controlMode == .curve ? "checkmark.circle.fill" : "circle")
                    .font(DS.ui(11, .medium))
                    .foregroundColor(viewModel.controlMode == .curve ? DS.fan : DS.tertiary)
                Spacer(minLength: 0)
                if let d = dot {
                    Text("\(Int(d.x.rounded()))°C → \(Int(d.y.rounded()))%")
                        .font(DS.ui(11, .medium))
                        .foregroundColor(.orange)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(Self.dotClock) { _ in blendDot() }
        .onAppear {
            blendDot()
            installRightClickMonitor()
        }
        .onDisappear {
            if let m = rightClickMonitor { NSEvent.removeMonitor(m) }
            rightClickMonitor = nil
        }
    }

    // MARK: - Profiles

    /// An empty name is not a rejection: `createProfile` falls back to a unique
    /// name, so the common case (just press Save) does the obvious thing.
    private func commitNewProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.createProfile(named: name.isEmpty ? nil : name)
        cancelNewProfile()
    }

    private func cancelNewProfile() {
        newProfileName = ""
        promptingNewProfile = false
        newProfileFieldFocused = false
    }

    /// The profile selector. A menu (not a `Picker`) because it also carries the
    /// two actions the request asked for: create a new profile (named in the
    /// alert above) and remove the selected one. Built-in profiles are factory-
    /// owned, so removal only appears for the user's own.
    private var profileMenu: some View {
        Menu {
            // "None" is a real state — a fork of a built-in shape, or a profile
            // removal, leaves the curve on screen belonging to no profile. Listing it
            // and checkmarking it means the menu only ever shows states it can put you
            // in, instead of a label that reads "None" with nothing to select.
            Button {
                viewModel.activeProfileID = ""
            } label: {
                if viewModel.activeProfileID.isEmpty {
                    Label("No profile", systemImage: "circle.slash")
                } else {
                    Text("No profile")
                }
            }
            Divider()
            ForEach(viewModel.profiles) { profile in
                Button {
                    viewModel.applyProfile(profile.id)
                } label: {
                    if profile.id == viewModel.activeProfileID {
                        Label(profile.name,
                              systemImage: profile.isDefault ? "square.stack.3d.up" : "bookmark.fill")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button("New profile…") { promptingNewProfile = true }
            if viewModel.activeProfileIsRemovable {
                Button("Remove profile", role: .destructive) {
                    viewModel.deleteProfile(viewModel.activeProfileID)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                    .font(DS.ui(10, .semibold))
                    .foregroundColor(viewModel.activeProfileName == nil ? DS.tertiary : DS.accent)
                Text(viewModel.activeProfileName ?? "None")
                    .font(DS.ui(11, .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(DS.ui(8))
                    .foregroundColor(DS.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(L10n.text("Profiles bundle the curve, the sensor and the response settings"))
    }

    // MARK: - Chart

    private var chart: some View {
        CurveLineChart(
            points: displayPoints,
            draggingID: dragLive?.id,
            dot: dot,
            xDomain: xDomain,
            onDrag: { data, moved in
                // A stationary press must not move the knot — only real travel
                // starts a drag (this was the click-jump). This closure writes local
                // @State only; the view model is touched once, on release — so it
                // does not need (and must not weakly capture) the view model.
                guard moved else { return }
                if let live = dragLive {
                    dragLive = (live.id, data.x, data.y)
                } else if let hit = hitTest(data) {
                    dragLive = (hit, data.x, data.y)
                }
            },
            onEnd: { [weak viewModel] data, moved in
                defer { dragLive = nil }
                guard let viewModel else { return }
                if let live = dragLive {
                    // One commit at release: one model change, one save, one
                    // panel re-render.
                    viewModel.updateCurvePoint(CurvePoint(id: live.id, x: live.x, y: live.y))
                } else if !moved, hitTest(data) == nil {
                    viewModel.addCurvePoint(x: data.x, y: data.y)
                }
            },
        )
        .equatable()
        .onPreferenceChange(PlotRectKey.self) { plotScreenRect = $0 }
    }

    // MARK: - Unsaved-draft control

    /// The editor's only commit point, beside the profile selector so it is
    /// obvious which curve the decision applies to: a green tick saves the draft
    /// (into the profile's curve, or as a new named entry forked from a
    /// built-in shape), a red cross discards it and returns to the saved
    /// status. One click each, no menu. Sized to the row's own type scale so
    /// appearing can never change the row's height. Visible only while the
    /// curve on screen differs from its saved state.
    private var draftButtons: some View {
        Group {
            if viewModel.curveDraft != nil {
                HStack(spacing: 3) {
                    Button {
                        viewModel.saveCurveDraft()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(DS.ui(11, .semibold))
                            .foregroundColor(DS.fan)
                            .padding(3)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("Save the curve changes"))

                    Button {
                        viewModel.discardCurveDraft()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(DS.ui(11, .semibold))
                            .foregroundColor(DS.error)
                            .padding(3)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("Discard the curve changes"))
                }
            }
        }
    }

    // MARK: - Input helpers

    /// Data-space hit test for the right-click monitor.
    ///
    /// Tolerances are a fraction of the **axis**, not fixed degrees: 5° is a
    /// sixteenth of the silicon axis but a quarter of the battery axis, so an absolute
    /// tolerance would be precise on CPU and sloppy on Battery.
    private func hitTest(_ data: CGPoint) -> UUID? {
        let span = xDomain.upperBound - xDomain.lowerBound
        let xTolerance = Swift.max(1.5, span / 16)
        var best: (id: UUID, score: Double)? = nil
        for point in sortedPoints {
            let dx = abs(point.x - data.x) / xTolerance
            let dy = abs(point.y - data.y) / 12
            let score = dx * dx + dy * dy
            guard score <= 1, score < (best?.score ?? .infinity) else { continue }
            best = (point.id, score)
        }
        return best?.id
    }

    /// Passive right-click monitor: observes rightMouseUp app-wide, and acts
    /// only when the click lands inside the plot rect. Passive monitors never
    /// participate in hit-testing, so they cannot steal the left-button drag.
    private func installRightClickMonitor() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak viewModel] event in
            guard let viewModel,
                  let window = event.window,
                  let content = window.contentView,
                  plotScreenRect.width > 0,
                  plotScreenRect.height > 0 else { return nil }
            // AppKit measures Y from the BOTTOM, SwiftUI's `.global` from the TOP.
            // Convert through the event's own window content view rather than assuming
            // the primary screen's height and a borderless window — an external display
            // or a titled settings window would otherwise make the containment test
            // never match, and right-click would silently do nothing.
            let inContent = content.convert(event.locationInWindow, from: nil)
            let click = CGPoint(x: inContent.x, y: content.bounds.height - inContent.y)
            guard plotScreenRect.contains(click) else { return nil }

            // Plot rect → data values (linear over the fixed domains).
            let relX = (click.x - plotScreenRect.minX) / plotScreenRect.width
            let relY = (click.y - plotScreenRect.minY) / plotScreenRect.height
            let dataX = xDomain.lowerBound + relX * (xDomain.upperBound - xDomain.lowerBound)
            let dataY = 100 * (1 - relY)
            if let id = hitTest(CGPoint(x: dataX, y: dataY)) {
                viewModel.deleteCurvePoint(id)
            }
            return nil // consume; no context menu from the chart
        }
    }

    // MARK: - Operating dot (smoothed)

    /// Glide halfway to the live operating point each tick, snapping once the gap is
    /// below visual resolution. No quantization of the target: rounding to 0.5 °C /
    /// 0.5 % steps puts a real 0.3 °C move in the same bucket, so `dot` never changes
    /// and the marker looks frozen until the panel is reopened.
    private func blendDot() {
        // Nothing is looking: the editor still exists (a closed `.window` panel keeps
        // its view tree), so without this gate the hidden panel would take a layout
        // pass every time the dot moves. The dot re-syncs from onAppear when the
        // panel opens again.
        guard viewModel.isUIVisible else { return }
        guard let live = viewModel.currentCurvePoint else {
            if dot != nil { dot = nil }
            return
        }
        if let current = dot {
            let snap: Double = 0.05
            let dx = live.x - current.x
            let dy = live.y - current.y
            let next = (
                abs(dx) <= snap ? live.x : current.x + dx * 0.5,
                abs(dy) <= snap ? live.y : current.y + dy * 0.5
            )
            // No assignment when nothing visibly moved: a steady temperature must
            // not repaint the panel once per second.
            guard abs(next.0 - current.x) >= 0.01 || abs(next.1 - current.y) >= 0.01 else { return }
            dot = next
        } else {
            dot = live
        }
    }

    // MARK: - Knot chips (drag to reshape; × to delete)

    var pointChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.s2) {
                ForEach(sortedPoints) { point in
                    HStack(spacing: 3) {
                        Text("\(Int(point.x))° → \(Int(point.y))%")
                            .font(DS.ui(10, .medium))
                            .monospacedDigit()
                        Button {
                            viewModel.deleteCurvePoint(point.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(DS.tertiary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DS.cardFill))
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: 336, alignment: .leading)
    }
}
