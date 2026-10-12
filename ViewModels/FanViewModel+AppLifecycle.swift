import AppKit
import Foundation
import ServiceManagement

// The status item and the app's process lifecycle: the RPM readout, the icon, the
// login item, the on-demand window, and the release path that runs on quit.

extension FanViewModel {

    // MARK: - Menu-bar readout

    /// Rebuilds the menu-bar readout. Policy is deliberately visibility-independent:
    /// at most every 10 s, and inside the first 30 s only for a change of ≥150 rpm.
    /// A re-layout of the status item is a real UI cost, and the throttle is what
    /// keeps it off the 1 Hz path.
    func refreshMenuBarTitle(force: Bool = false) {
        guard showsRPMInMenuBar else {
            if !labelModel.rpmText.isEmpty { labelModel.rpmText = "" }
            return
        }
        let now = Date()
        if !force, let last = labelRefreshDate, now.timeIntervalSince(last) < 10 { return }
        guard let speed = maxFanSpeed else { return }
        if !force, let last = labelRefreshDate, now.timeIntervalSince(last) < 30,
           abs(speed - lastLabelSpeed) < 150 { return }
        labelRefreshDate = now
        lastLabelSpeed = speed
        let rpm = "\(speed)"
        if rpm != labelModel.rpmText { labelModel.rpmText = rpm }
    }

    /// Tray icon: who owns the fans and whether the channel is healthy, written
    /// through the label model and diffed — a per-second poll costs a string compare.
    func refreshMenuBarIcon() {
        let icon = menuBarIcon
        if labelModel.icon != icon { labelModel.icon = icon }
    }

    // MARK: - Launch at login
    //
    // The result of the *call* is what the toggle shows: the `SMAppService` status
    // is re-read after every attempt, so a rejected registration cannot look like a
    // success.

    func setAutoStart(_ newValue: Bool) {
        do {
            if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if errorMessage != nil { errorMessage = nil }
        } catch {
            reportWriteResult(success: false, message: L10n.format("Launch-at-login could not be changed: %@", error.localizedDescription))
        }
        let status = SMAppService.mainApp.status == .enabled
        if isAutoStart != status { isAutoStart = status }
    }

    // MARK: - Window on demand

    /// Opens the settings window. It is a `Settings` scene, so no window — and no
    /// SwiftUI layout — exists until the user asks for one.
    func showMainWindow() {
        if runInAccessoryMode { NSApplication.shared.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        for name in ["showSettingsWindow:", "showPreferencesWindow:"] {
            if NSApp.sendAction(Selector((name)), to: nil, from: nil) { return }
        }
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Quit

    /// The menu's Quit item. Routed through `applicationShouldTerminate` so the
    /// fans are released exactly once no matter how the app is asked to exit.
    func terminate() {
        NSApplication.shared.terminate(nil)
    }

    /// Releases every override before the process exits — **without blocking the
    /// main thread**. XPC replies are delivered *on the main queue*, so a main-thread
    /// wait on them can only ever time out, and quitting while the engine held the
    /// fans would leave the SMC pinned at that speed indefinitely.
    ///
    /// `reply` is called (bounded, 3 s) when the release has been issued and
    /// answered, or when no privileged channel exists to answer at all.
    func prepareForQuit(reply: @escaping () -> Void) {
        guard !isQuitting else { reply(); return }
        isQuitting = true
        timer?.invalidate()
        timer = nil
        flushCurveSave()
        flushProfileSave()
        historyStore?.synchronize()
        // Not async by accident: AppKit wants `reply(toApplicationShouldTerminate:)`
        // *after* `applicationShouldTerminate` returns, so a quit with no privileged
        // channel still has to hand the reply back on the next turn of the run loop.
        guard canWrite else { DispatchQueue.main.async { reply() }; return }

        let group = DispatchGroup()
        group.enter()
        if let proxy = controlProxy() {
            proxy.resetAll { ok, _ in
                _ = ok
                group.leave()
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = self?.runHelper(["reset"]) ?? (-1, "")
                group.leave()
            }
        }
        DispatchQueue.global().async {
            _ = group.wait(timeout: .now() + 3)
            DispatchQueue.main.async { reply() }
        }
    }
}
