import AppKit
import Foundation

// The privileged write path. There are two channels and exactly one is live at a
// time, which is what makes "can I write?" a single answer:
//
//   1. The launchd root daemon (`FanCurveHelperProtocol` over a Mach service).
//      Installed once into /Library, outside the bundle, so it survives rebuilds
//      and reinstalls without another password prompt.
//   2. The bundled setuid helper, forked per command. Used only when the daemon is
//      not live; `controlProxy()` returns nil in that case, so the two channels can
//      never be half-configured at the same time.
//
// Reading the SMC needs no privileges at all — only writes do. That is why the UI
// can look completely alive while every command is refused.

extension FanViewModel {

    // MARK: - Authorization / privileged channels

    func checkAuthorization() {
        let path = helperPath
        var authorized = false
        if FileManager.default.fileExists(atPath: path),
           let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            let ownerId = attributes[.ownerAccountID] as? Int ?? -1
            let posixPermissions = attributes[.posixPermissions] as? Int ?? 0
            authorized = (ownerId == 0 && (posixPermissions & 0o4000) != 0)
        }
        if isAuthorized != authorized { isAuthorized = authorized }
    }

    /// The helper exists but is missing root ownership / the setuid bit, so every
    /// fan *write* it performs is refused by the kernel. Reads never need it, which
    /// is why the UI looks alive while control silently fails.
    var helperNeedsAuthorization: Bool {
        let path = helperPath
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return true }
        let ownerId = attributes[.ownerAccountID] as? Int ?? -1
        let posixPermissions = attributes[.posixPermissions] as? Int ?? 0
        return !(ownerId == 0 && (posixPermissions & 0o4000) != 0)
    }

    static let helperUnauthorizedMessage =
        "Fan control failed — no privileged helper is available. Install the control service (asks for your admin password once)."

    /// One visible result for a fan write, from either path. Failures name the
    /// cause; a later success clears them. `errorMessage` is only assigned when it
    /// really changes, so a failing write cannot invalidate the UI every second.
    func reportWriteResult(success: Bool, message: String) {
        let next = success
            ? (errorMessage?.hasPrefix("Fan control failed") == true ? nil : errorMessage)
            : L10n.format("Fan control failed — %@", message)
        if next != errorMessage { errorMessage = next }
    }

    // MARK: - XPC control service

    /// Open the Mach-service connection once. `interruptionHandler` fires when the
    /// daemon dies; `invalidationHandler` fires when *we* drop the reference. Both
    /// compare `controlConnection === connection` so a handler from a superseded
    /// connection cannot tear down the replacement.
    func connectControlServiceIfNeeded() {
        guard controlConnection == nil else { return }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.controlConnection === connection else { return }
                self.controlServiceActive = false
                self.reportWriteResult(success: false, message: L10n.text("the control service restarted; retry"))
                // launchd restarts the daemon (KeepAlive), so the *next* ping decides
                // whether the channel is really gone. Without a scheduled recheck the
                // app would stay write-less until relaunch even though the daemon came
                // back seconds later.
                self.scheduleControlServiceRecheck()
            }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.controlConnection === connection else { return }
                self.controlConnection = nil
                self.controlServiceActive = false
            }
        }
        connection.remoteObjectInterface = NSXPCInterface(with: FanCurveHelperProtocol.self)
        connection.activate()
        controlConnection = connection
    }

    /// The daemon proxy, or nil when the daemon is not usable. The exception handler
    /// tears the connection down so the *next* write falls back to the setuid helper
    /// instead of vanishing into a dead service.
    func controlProxy() -> FanCurveHelperProtocol? {
        guard controlServiceActive, let connection = controlConnection else { return nil }
        let handler: (Error) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.controlServiceActive = false
                self.controlConnection?.invalidate()
                self.controlConnection = nil
                self.reportWriteResult(success: false,
                                       message: L10n.format("the control service did not answer (%@)", error.localizedDescription))
            }
        }
        // `remoteObjectProxyWithErrorHandler(_:)` — the ObjC name survives into the
        // Swift surface; there is no `withExceptionHandler:` overload. Every proxy use
        // goes through here, because a daemon that dies mid-call otherwise simply
        // never replies and the click looks ignored.
        return connection.remoteObjectProxyWithErrorHandler(handler) as? FanCurveHelperProtocol
    }

    /// Ping the daemon and record whether it is usable.
    ///
    /// Deliberately does **not** go through `controlProxy()`: that helper only hands
    /// out a proxy while `controlServiceActive` is already true, which would make the
    /// first probe a no-op — the flag could never become true, so the app would run
    /// forever with `canWrite == false` and silently drop every command.
    ///
    /// `ping` reports the fan count the daemon can actually see, so "live" means
    /// "reachable *and* looking at the SMC".
    func checkControlService() {
        connectControlServiceIfNeeded()
        guard let connection = controlConnection else {
            if controlServiceActive { controlServiceActive = false }
            return
        }
        let handler: (Error) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.controlServiceActive = false
                self.reportWriteResult(success: false,
                                       message: L10n.format("the control service did not answer (%@)", error.localizedDescription))
            }
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(handler) as? FanCurveHelperProtocol else {
            if controlServiceActive { controlServiceActive = false }
            return
        }
        let deadline = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if debugLogging { print("[service] ping timed out (2 s)") }
                self.controlServiceActive = false
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: deadline)
        proxy.ping { [weak self] info in
            deadline.cancel()
            DispatchQueue.main.async {
                guard let self else { return }
                // Any reply means the daemon is reachable and the client passed its
                // signature check. `fans=0` is the specific failure worth caring
                // about: the daemon answered but cannot see the SMC, so every write
                // through it would be a no-op. A reply *without* a fan count is an
                // older daemon build — functional, just not self-reporting.
                let live = !info.contains("fans=0")
                if debugLogging { print("[service] ping \(info) -> live=\(live)") }
                if self.controlServiceActive != live { self.controlServiceActive = live }
                if !live {
                    self.reportWriteResult(success: false,
                                           message: L10n.text("the installed control service cannot read the SMC — press Install to update it"))
                }
            }
        }
    }

    /// Retry the liveness check and, only if the daemon is genuinely absent from
    /// disk, run the one-time install. A daemon that exists but is briefly
    /// unresponsive must never trigger another password prompt.
    func scheduleControlServiceInstall() {
        for delay in [1.5, 4.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.canWrite, !self.controlServiceInstallAttempted else { return }
                if FileManager.default.fileExists(atPath: HelperConstants.daemonProgramPath) {
                    self.checkControlService()
                    return
                }
                self.controlServiceInstallAttempted = true
                self.installControlService()
            }
        }
    }

    /// Re-ping the daemon shortly after a wake or an XPC interruption. launchd may
    /// need a beat to resume the root daemon; without this the app stays "no
    /// privileged channel" until relaunch even though the daemon is alive, and every
    /// curve command is refused.
    func scheduleControlServiceRecheck() {
        for delay in [2.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.controlServiceActive else { return }
                self.checkControlService()
            }
        }
    }

    // MARK: - One-time install

    /// One-time install of the root control daemon. Runs on the main thread:
    /// `NSAppleScript` is not thread-safe.
    func installControlService() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let script = HelperConstants.daemonInstallScript
            .replacingOccurrences(of: "%BUNDLE%", with: Self.shellQuoted(Bundle.main.bundlePath))
        guard let appleScript = NSAppleScript(source: "do shell script \"\(Self.appleScriptEscaped(script))\" with administrator privileges") else {
            reportWriteResult(success: false, message: L10n.text("Failed to prepare control-service install."))
            return
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number != -128 {
                reportWriteResult(success: false, message: (error[NSAppleScript.errorMessage] as? String) ?? "control-service install failed")
            }
        }
        // launchd may take a beat to bring the daemon up; re-check shortly.
        checkControlService()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.checkControlService()
            self?.checkAuthorization()
        }
    }

    /// Authorize the bundled setuid helper (root ownership + the setuid bit).
    func authorize() {
        let path = helperPath
        guard FileManager.default.fileExists(atPath: path) else {
            reportWriteResult(success: false, message: L10n.text("helper tool ‘fancurve-helper’ not found"))
            return
        }
        let command = "chown root:wheel \(Self.shellQuoted(path)) && chmod +s \(Self.shellQuoted(path))"
        guard let appleScript = NSAppleScript(source: "do shell script \"\(Self.appleScriptEscaped(command))\" with administrator privileges") else {
            reportWriteResult(success: false, message: L10n.text("Failed to compile authorization script."))
            return
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        guard let error else {
            errorMessage = nil
            checkAuthorization()
            updateStatus()
            return
        }
        isAuthorized = false
        let desc = (error[NSAppleScript.errorMessage] as? String) ?? "authorization rejected"
        reportWriteResult(success: false, message: desc)
    }

    /// Quote a path for `/bin/sh`. Every path that reaches a shell command goes
    /// through here, so a bundle path containing a quote can neither break nor
    /// inject into the command.
    static func shellQuoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Helper CLI fallback

    /// Runs the bundled helper with captured output. Returns `(exitStatus, output)`.
    /// The pipe is drained *before* `waitUntilExit()`, so a chatty helper cannot
    /// deadlock on a full buffer.
    func runHelper(_ arguments: [String]) -> (Int32, String) {
        let path = helperPath
        guard FileManager.default.fileExists(atPath: path) else { return (-1, "helper missing") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        var collected = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        do { try task.run() } catch { group.wait(); return (-1, error.localizedDescription) }
        group.wait()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: collected, encoding: .utf8) ?? "")
    }

    /// Surfaces helper write failures in the UI (and clears them once writes succeed
    /// again), so a failed control action is never silently ignored. Matches the
    /// helper's `ERROR:` line prefix rather than scanning for the substring "ERROR"
    /// anywhere in the output.
    func reportHelperResult(_ status: Int32, output: String) {
        let lines = output.split(separator: "\n").map(String.init)
        let failure = lines.first(where: { $0.hasPrefix("ERROR") })
        let failed = status != 0 || failure != nil
        let message = failure?.dropping(prefix: "ERROR: ")
            ?? (failed ? Self.helperUnauthorizedMessage : "ok")
        reportWriteResult(success: !failed, message: message)
    }
}
