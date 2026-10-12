import SwiftUI
import AppKit

// MARK: - Shared state, not observed by the scene body
enum AppState {
    static let viewModel = FanViewModel()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Release all fan overrides before the process exits. Quitting while a
    /// curve or manual-pin override is active would otherwise leave the SMC pinned at
    /// that speed forever, past the lifetime of this process.
    ///
    /// `.terminateLater` + an asynchronous release. A blocking reset here cannot
    /// complete: XPC replies are delivered on the main queue the wait is occupying.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppState.viewModel.isQuitting else { return .terminateLater }
        AppState.viewModel.prepareForQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One controller per machine. Two instances interleave writes to the same SMC
        // fan targets, each with its own timer, its own idea of which engine owns
        // which fan, and its own history appends — so the fans flap between two
        // demands. LaunchServices prevents this for `open`, but running the executable
        // directly does not.
        let mine = getpid()
        if let other = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != mine
        }) {
            let message = "FanCurve is already running as pid \(other.processIdentifier) — "
                + "refusing to start a second fan controller.\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            NSApp.terminate(nil)
            return
        }
    }
}

@main
struct FanCurveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Menu-bar-only by default: no Dock icon, no window built at launch. The
        // setting is reversible from the accordion's Settings submenu.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        // No presentation binding: the item is always inserted (the user needs a
        // permanent indicator), and the new SDK's `isInserted:` variant would
        // otherwise drop the status item whenever the binding is false.
        //
        // `.window` style, not `.menu`: in a classic menu every item selection
        // (apply a curve, set a fan, drag a slider) dismisses the whole menu, so
        // tuning meant reopen-tap-reopen forever. As a panel, none of the
        // actions close it — only clicking outside or Escape does. That is the
        // interaction the accordion is designed for.
        MenuBarExtra {
            MenuBarView(viewModel: AppState.viewModel)
        } label: {
            // A dedicated view observing the tray's own model: observation is
            // guaranteed at the View level, and the model is owned by the view
            // model — the tray renders whatever the controller last wrote, no
            // matter how SwiftUI schedules the scene's own state.
            MenuBarTrayLabel(model: AppState.viewModel.labelModel)
        }
        .menuBarExtraStyle(.window)

        // A `Settings` scene exists only while it is open, so the chart, the curve
        // editor and the fine RPM slider cost literally nothing when closed. A
        // always-on `WindowGroup` would lay all of that out at 1 Hz for a window the
        // user never opened.
        Settings {
            ContentView(viewModel: AppState.viewModel)
                .preferredColorScheme(.dark)
                .onAppear { AppState.viewModel.setWindowOpen(true) }
                .onDisappear { AppState.viewModel.setWindowOpen(false) }
        }
    }
}

/// The status item's label: tray icon + optional live RPM readout. It observes only
/// the label model, so the per-second sensor loop cannot re-render the status item:
/// `rpmText` moves at most every 10 s and the icon only when the mode or the channel
/// changes, both written by the control loop itself.
private struct MenuBarTrayLabel: View {
    @ObservedObject var model: MenuBarLabelModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.icon)
            if model.showsRPM, !model.rpmText.isEmpty {
                Text(model.rpmText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
        }
    }
}
