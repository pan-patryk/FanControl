import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import IOKit.ps

// MARK: - Control plane
//
// One authority for who may write the fans, one authority for who the user has
// pinned. Engine selection is an explicit call from the UI controls that mean it;
// changing a tuning knob never switches engines.

/// Who owns the fans right now.
enum ControlMode: String, Codable, CaseIterable, Identifiable {
    /// `thermalmonitord` owns the fans; nothing is overridden.
    case macOS
    /// The XY curve owns every fan the user has not pinned.
    ///
    /// There is deliberately no third authority: a threshold rule ("if CPU passes
    /// 75 °C then 80 %") is a step function sampled from the same temperature→fan-%
    /// space the curve covers continuously, so two editors would describe one job.
    case curve

    var id: String { rawValue }

    /// Short label for the segmented control in the menu.
    var shortLabel: String {
        switch self {
        case .macOS: return "macOS"
        case .curve: return "Curve"
        }
    }
}

/// Set `FANCURVE_DEBUG=1` to trace the control loop on stderr: every commanded
/// percentage, every write and every reason a write was skipped. The loop is silent
/// by design in normal use, which makes a "the fans didn't move" report impossible
/// to diagnose without it.
let debugLogging = ProcessInfo.processInfo.environment["FANCURVE_DEBUG"] != nil

/// Where a fan command came from. Only `.user*` sources create a pin, and pins are
/// the only thing the engines are forbidden to touch.
enum CommandSource: Equatable {
    case engine
    case userAllFans
    case userFan
    case release
}

// MARK: - View Model

/// The thermal controller: samples sensors at 1 Hz, decides what the curve wants,
/// writes it through the privileged channel, and mirrors the result into the
/// view-facing state.
///
/// The behaviour is spread over `FanViewModel+*.swift` extensions; this file holds
/// the state and the lifecycle. Every stored property lives here, because Swift
/// forbids stored properties in extensions — that also makes the class's memory
/// footprint readable in one place.
final class FanViewModel: ObservableObject {

    /// All `UserDefaults` keys in one namespaced place, so a key is written by
    /// exactly one code path.
    enum Keys {
        static let accessory = "runInAccessoryMode"
        static let showsRPM = "showsRPMInMenuBar"
        static let derateOnBattery = "reduceFansOnBattery"
        static let mode = "controlMode"
        static let curves = "customCurves"
        static let activeCurveID = "activeCurveID"
        static let rise = "maximumCommandRiseRatePercentPerSecond"
        static let fall = "maximumCommandFallRatePercentPerSecond"
        static let hysteresis = "coolingTemperatureHysteresis"
        static let minChange = "minimumCommandChangePercent"
        static let confirmation = "coolingConfirmationSeconds"
        static let pins = "userPinnedFanIDs"
        static let linkedFans = "linkedFans"
        static let curveSensor = "curveSensor"
        static let startupCurveID = "startupCurveID"
        static let profiles = "fanProfiles"
        static let activeProfile = "activeProfileID"
    }

    // MARK: Published, view-facing state
    //
    // Mirrors of the canonical state below. They change *only* while something is
    // actually looking, and only on a real difference — assigning an unchanged
    // value to a `@Published` still fires `objectWillChange`, which re-lays out a
    // hidden panel once per second.

    @Published var fans: [FanJSON] = []
    @Published var cpuTemp: Double? = nil
    @Published var gpuTemp: Double? = nil
    @Published var batteryTemp: Double? = nil
    @Published var tempHistory: [TempRecord] = []

    @Published var isAuthorized: Bool = false
    @Published var controlServiceActive: Bool = false
    /// "Sync all fans together": every *user* fan command applies to all fans.
    @Published var linkedFans: Bool = UserDefaults.standard.bool(forKey: Keys.linkedFans) {
        didSet { UserDefaults.standard.set(linkedFans, forKey: Keys.linkedFans) }
    }
    @Published var errorMessage: String? = nil
    /// Desktops (and anything without a reported power source) count as AC.
    @Published var isOnACPower: Bool = true
    @Published var isAutoStart: Bool = SMAppService.mainApp.status == .enabled

    /// The engine the UI is switching between. `didSet` persists and hands the fans
    /// back when it stops — it never touches another engine's state.
    @Published var controlMode: ControlMode = .macOS {
        didSet {
            guard controlMode != oldValue else { return }
            UserDefaults.standard.set(controlMode.rawValue, forKey: Keys.mode)
            engineTransition(from: oldValue, to: controlMode)
            applyCadence()
        }
    }

    /// Menu-bar-only mode: no Dock icon, no window at launch.
    @Published var runInAccessoryMode: Bool = UserDefaults.standard.object(forKey: Keys.accessory) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(runInAccessoryMode, forKey: Keys.accessory)
            Self.applyActivationPolicy(runInAccessoryMode)
        }
    }

    /// Whether the menu-bar label shows a live RPM number.
    @Published var showsRPMInMenuBar: Bool = UserDefaults.standard.bool(forKey: Keys.showsRPM) {
        didSet {
            UserDefaults.standard.set(showsRPMInMenuBar, forKey: Keys.showsRPM)
            if labelModel.showsRPM != showsRPMInMenuBar { labelModel.showsRPM = showsRPMInMenuBar }
            if !showsRPMInMenuBar, !labelModel.rpmText.isEmpty { labelModel.rpmText = "" }
            refreshMenuBarTitle(force: true)
        }
    }

    /// Global on-battery derating: a curve demand is multiplied by 0.75 when the
    /// machine is drawing from the battery.
    @Published var reduceFansOnBattery: Bool = UserDefaults.standard.object(forKey: Keys.derateOnBattery) as? Bool ?? true {
        didSet { UserDefaults.standard.set(reduceFansOnBattery, forKey: Keys.derateOnBattery) }
    }

    /// The menu-bar tray's render state, owned here. The app only *observes* it for
    /// the status item, so the wiring cannot depend on when SwiftUI decides to
    /// create its state. Ownership makes the tray provable: the model exists for as
    /// long as the controller does.
    let labelModel = MenuBarLabelModel()
    var lastLabelSpeed: Int = 0
    var labelRefreshDate: Date? = nil

    static func applyActivationPolicy(_ accessory: Bool) {
        NSApplication.shared.setActivationPolicy(accessory ? .accessory : .regular)
    }

    /// Fan ids the **user** pinned (per-fan slider, mode picker, or an explicit
    /// "all fans" command). Persisted, because it is the user's intent and must
    /// survive a relaunch.
    @Published var userPinnedFanIDs: Set<Int> = [] {
        didSet {
            guard userPinnedFanIDs != oldValue else { return }
            UserDefaults.standard.set(userPinnedFanIDs.sorted(), forKey: Keys.pins)
        }
    }

    func isPinned(_ fanID: Int) -> Bool { userPinnedFanIDs.contains(fanID) }

    var canWrite: Bool { controlServiceActive || isAuthorized }

    /// The highest current fan speed, for the optional live menu-bar label.
    var maxFanSpeed: Int? {
        rawStatus?.fans.map(\.currentSpeed).max() ?? fans.map(\.currentSpeed).max()
    }

    // MARK: - Canonical state (never published)
    //
    // Thermal control must keep sampling every second whether or not anything is
    // looking. Everything the control loop needs lives here, in non-published
    // storage; the `@Published` values above are mirrors copied out of it while a
    // panel is visible. The loop must never read a published mirror as its input.

    var isWindowOpen = false
    var isMenuOpen = false
    var rawStatus: SystemStatusJSON? = nil
    /// The fans **as the control loop sees them**: always the newest SMC snapshot,
    /// never the published mirror. `fans` is only refreshed while a panel is visible
    /// (that is the whole point of the visibility gate), so iterating it from a
    /// command path would give the loop an empty list when nothing is on screen and
    /// silently issue zero writes.
    var controlFans: [FanJSON] { rawStatus?.fans ?? fans }
    /// Validated temperatures used by the engine and by the published mirror.
    var controlTemps: [TemperatureSensor: Double] = [:]
    var sensorGates: [TemperatureSensor: SensorGate] = [:]
    /// Raw readings that failed validation, so the UI can say "no data" instead of
    /// showing a value that is minutes old.
    var historyBuffer: [TempRecord] = []
    var lastHistoryRecordTime: Date? = nil
    let historyRetentionInterval: TimeInterval = 24 * 60 * 60
    var historyStore: HistoryStore? = HistoryStore.open()

    var wantsLiveUI: Bool { isMenuOpen || isWindowOpen }

    /// Whether the menu-bar panel is genuinely on screen. `MenuBarView`'s
    /// `onDisappear` is not reliable for a `.window`-style `MenuBarExtra` (the panel
    /// is ordered out and its view tree survives), so the gate also asks AppKit.
    var menuPanelIsVisible: Bool {
        for window in NSApp.windows where window.className.contains("MenuBarExtra")
            || window.title == "MenuBarExtraWindow" {
            return window.isVisible && !window.isMiniaturized
        }
        // No panel window found: fall back to the view's own report.
        return isMenuOpen
    }

    /// True between a `willSleepNotification` and the next wake — no matter which
    /// notification (or tick) delivers that wake. The polling tick is the wake
    /// detector, because a tick cannot fire while the process is suspended.
    var isAsleep = false
    /// Set with `isAsleep`; consumed by the first post-wake reconcile.
    var needsWakeReconcile = false
    /// rpm each pinned fan was explicitly set to when the machine went to sleep.
    /// Captured before the sleep release zeroes the write bookkeeping, because the
    /// release's success reply may never arrive (the process is suspended mid-call).
    var sleepPinnedRPM: [Int: Int] = [:]
    /// Consumed by the first successful read after a wake.
    var wakePinsToReassert: [Int: Int] = [:]
    /// Set when a poll read was enqueued; cleared when it lands. Bounded below so a
    /// wedged read cannot hold the loop shut forever.
    var pollInFlightSince: Date? = nil
    var lastPowerSourceCheck: Date? = nil
    /// Temperature hysteresis, deadband, cooling confirmation and the (time-based)
    /// command-rate limiter.
    var commandFilter = CommandFilter(
        riseRate: 6, fallRate: 3, hysteresisC: 5, minChangePercent: 4, confirmationSeconds: 8
    )
    var lastCommandedPercent: Double? = nil
    var wasEngineApplied = false

    /// fan id → last value successfully written (`-1` = handed back to macOS).
    /// Drops redundant writes: re-issuing an identical `F0Tg` twice per second is SMC
    /// traffic that changes nothing.
    var lastWrittenTargets: [Int: Int] = [:]

    // MARK: Privileged channel state

    var controlConnection: NSXPCConnection?
    var controlServiceInstallAttempted = false

    // MARK: Notification rate limiting

    // An engine idling just above the release threshold crosses the demand boundary
    // over and over; without a cooldown every crossing posts a banner.
    var lastNotificationDate: Date? = nil
    var notifiedEngaged = false
    let notificationCooldown: TimeInterval = 120

    // MARK: Persistence coalescing

    // Slider drags fire the save path on every mouse event. Cheap keys write
    // immediately; the large blobs are coalesced so `cfprefsd` does not see one
    // write per pixel.
    var curveSaveTask: Task<Void, Never>?
    var profileSaveTask: Task<Void, Never>?
    /// True only while a `load*()` is restoring state, to suppress the persistence
    /// side effects of that restore.
    var isLoadingCurveState = false
    var isLoadingProfileState = false
    /// Suppresses the knob write-back and the detach checks while *we* are the ones
    /// moving values (load, apply, restore) — otherwise applying a profile would
    /// immediately rewrite it from its own values.
    var isApplyingProfile = false

    // MARK: - Curve engine (the XY curve: temperature → fan %)

    @Published var activeCurveID: String = FanCurve.presets[1].id {
        didSet {
            guard activeCurveID != oldValue else { return }
            UserDefaults.standard.set(activeCurveID, forKey: Keys.activeCurveID)
        }
    }
    /// Compatibility view of `controlMode` for callers that think in booleans.
    var isCurveEngineEnabled: Bool {
        get { controlMode == .curve }
        set { controlMode = newValue ? .curve : .macOS }
    }

    /// The percentage the controller last commanded, for the tuning readout.
    @Published var currentCommandedPercent: Double? = nil

    // MARK: - Fan-response knobs
    //
    // Plain persisted values. Assigning them must not enable, disable or reset an
    // engine; the next poll picks the new numbers up, and `syncCommandFilter`
    // pushes them into the live limiter.

    // Every knob also writes into the *selected* profile (see
    // `writeKnobsToActiveProfile`), which is what makes "Restore default
    // profiles" meaningful: a profile holds the response values you are
    // actually using, so the built-ins can drift and be put back.
    @Published var maximumCommandRiseRatePercentPerSecond: Double = 6.0 {
        didSet {
            UserDefaults.standard.set(maximumCommandRiseRatePercentPerSecond, forKey: Keys.rise)
            syncCommandFilter(); writeKnobsToActiveProfile()
        }
    }
    @Published var maximumCommandFallRatePercentPerSecond: Double = 3.0 {
        didSet {
            UserDefaults.standard.set(maximumCommandFallRatePercentPerSecond, forKey: Keys.fall)
            syncCommandFilter(); writeKnobsToActiveProfile()
        }
    }
    @Published var coolingTemperatureHysteresis: Double = 5.0 {
        didSet {
            UserDefaults.standard.set(coolingTemperatureHysteresis, forKey: Keys.hysteresis)
            syncCommandFilter(); writeKnobsToActiveProfile()
        }
    }
    @Published var minimumCommandChangePercent: Double = 4.0 {
        didSet {
            UserDefaults.standard.set(minimumCommandChangePercent, forKey: Keys.minChange)
            syncCommandFilter(); writeKnobsToActiveProfile()
        }
    }
    @Published var coolingConfirmationSeconds: Double = 8.0 {
        didSet {
            UserDefaults.standard.set(coolingConfirmationSeconds, forKey: Keys.confirmation)
            syncCommandFilter(); writeKnobsToActiveProfile()
        }
    }

    // MARK: - Curve editing

    /// The sampling sensor the *built-in* shapes are derived for. The chart, the
    /// sampling picker and the engine always follow the ACTIVE curve's own sensor
    /// (a saved curve carries it), so `curveSensor` tracks what is on screen and
    /// re-shapes the built-ins when it moves.
    @Published var curveSensor: TemperatureSensor = .hottest {
        didSet {
            UserDefaults.standard.set(curveSensor.rawValue, forKey: Keys.curveSensor)
        }
    }

    /// Unsaved curve edits, overlaying the curve they were forked from. `nil`
    /// means the curve on screen IS the saved state. The editor and the engine
    /// both sample the draft (live tuning); it becomes real only through the
    /// editor's save/discard control, and navigation (profile switch, sensor
    /// change) rejects it. Never persisted: quitting with a dirty draft loses
    /// exactly what the user declined to save.
    @Published var curveDraft: FanCurve? = nil

    /// Which curve the app should come up with, instead of the last-used one. Empty
    /// means "last used". Persisted; applied once at load.
    @Published var startupCurveID: String = "" {
        didSet {
            guard startupCurveID != oldValue else { return }
            UserDefaults.standard.set(startupCurveID, forKey: Keys.startupCurveID)
        }
    }

    /// Every curve the user saved. Persisted (coalesced) under `customCurves`.
    @Published var userCurves: [FanCurve] = [] {
        didSet { saveCurves() }
    }

    // MARK: - Profiles
    //
    // One named bundle: curve id + sensor + the five response knobs (see
    // `Models/FanProfile.swift`). Applying one moves all three together; while
    // a profile is selected it also *absorbs* the response edits you make, which
    // is what gives "Restore default profiles" something to put back.

    /// Every profile: the four factory ones (always present, never removable)
    /// plus the user's own.
    @Published var profiles: [FanProfile] = FanProfile.factoryDefaults() {
        didSet { saveProfiles() }
    }

    /// The profile that describes what is on screen, or `""` when the current
    /// curve / sensor / response settings are not (or no longer) a profile.
    @Published var activeProfileID: String = "" {
        didSet {
            guard activeProfileID != oldValue else { return }
            UserDefaults.standard.set(activeProfileID, forKey: Keys.activeProfile)
        }
    }

    // MARK: - Lifecycle

    var timer: Timer?
    var isStatusUpdateInProgress = false
    /// Set by `prepareForQuit()`. `applicationShouldTerminate` uses it to stay
    /// idempotent, and the poll loop stops sampling once it is set.
    var isQuitting = false
    /// All in-process SMC reads are serialised here: `SMC.shared` owns one IOKit
    /// connection and the control loop is not re-entrant.
    let smcQueue = DispatchQueue(label: "com.local.fancurve.app.smc-reads")
    /// Keeps App Nap from throttling a thermal-protection loop. Idle system
    /// sleep is still allowed; only UI-triggered nap is refused.
    var activityToken: NSObjectProtocol?
    var sleepObservers: [NSObjectProtocol] = []

    /// Notifications are only worth posting for a demand this high.
    static let notifiableDemandPercent = 50.0

    var helperPath: String {
        let bundleHelper = Bundle.main.bundlePath + "/Contents/MacOS/fancurve-helper"
        if FileManager.default.fileExists(atPath: bundleHelper) { return bundleHelper }
        return FileManager.default.currentDirectoryPath + "/fancurve-helper"
    }

    init() {
        if debugLogging { setvbuf(stdout, nil, _IONBF, 0) }
        loadResponseSettings()
        loadCurves()
        loadProfiles()
        loadPins()
        loadHistory()
        restoreControlMode()
        checkAuthorization()
        updatePowerSource()
        syncCommandFilter()

        if Bundle.main.bundleIdentifier != nil {
            // The one-time ask, up front. The daemon lives in /Library (outside the
            // bundle) and survives every rebuild, so no later launch prompts again.
            connectControlServiceIfNeeded()
            checkControlService()
            if helperNeedsAuthorization && !isAuthorized { scheduleControlServiceInstall() }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            observeSleepNotifications()
        }
        applyActivityAssertion()
        Self.applyActivationPolicy(runInAccessoryMode)
        // The tray renders from the label model before the first poll lands; sync it
        // now so the icon and the RPM switch are correct at first paint.
        labelModel.showsRPM = showsRPMInMenuBar
        refreshMenuBarIcon()
        refreshMenuBarTitle(force: true)
        startPolling()
    }

    deinit {
        if let token = activityToken { ProcessInfo.processInfo.endActivity(token) }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.forEach { center.removeObserver($0) }
        timer?.invalidate()
    }
}

// MARK: - Small shared helpers

extension FanViewModel {
    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        Swift.min(Swift.max(value, lower), upper)
    }

    static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        Swift.min(Swift.max(value, lower), upper)
    }
}

extension String {
    /// Removes a leading prefix (used for the helper's `ERROR: ` line).
    func dropping(prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
