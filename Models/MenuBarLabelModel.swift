import Combine

/// The menu-bar tray's own render state, owned by the view model and observed by the
/// tray label view.
///
/// Kept as a separate `ObservableObject` (not the view model) so per-second sensor
/// updates cannot invalidate the status item: only `showsRPM`/`rpmText`/`icon` move,
/// and `rpmText` changes at most every 10 s (30 s while the speed is steady) — the
/// throttles live in `FanViewModel.refreshMenuBarTitle`. Plain `ObservableObject` (no
/// macros) so it compiles with the Command Line Tools alone.
final class MenuBarLabelModel: ObservableObject {
    /// The tray icon: `fan` while macOS owns the fans, a curve glyph while an engine
    /// commands them, a warning when no privileged channel exists. Written from the
    /// control loop, diffed against the current value so it changes only when the
    /// mode or the channel actually changes.
    @Published var icon: String = "fanblades"
    /// Whether a live RPM readout is appended to the icon ("2314"). The icon never
    /// disappears — the label only gains/loses its number.
    @Published var showsRPM: Bool = false
    /// Short rpm readout appended to the icon.
    @Published var rpmText: String = ""
}
