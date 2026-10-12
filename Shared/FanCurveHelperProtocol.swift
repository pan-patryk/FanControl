import Foundation

// This file is compiled into *both* the GUI app (XPC client) and the privileged
// helper daemon (XPC server). NSXPC matches interfaces by selector at runtime,
// so sharing the exact declaration keeps the two sides in lockstep.

/// Well-known names shared between the app and the privileged helper daemon.
public enum HelperConstants {
    /// Mach service the daemon vends and the app connects to. Must match the
    /// `MachServices` key in the launchd plist and the `machServiceName` used
    /// by `NSXPCConnection`.
    public static let machServiceName = "com.local.fancurve.app.helper"

    /// The GUI app's bundle identifier — the ONE identity the app is known by.
    /// It must equal `CFBundleIdentifier` in `build.sh`'s Info.plist and
    /// `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`. When those disagree, an app's
    /// saved state silently lands in a different `UserDefaults` domain, and the
    /// daemon has to trust both identities.
    public static let appBundleIdentifier = "com.local.fancurve.app"

    /// Signing identifiers allowed to connect. Matched against the code
    /// signature's *signing identifier* (`kSecCodeInfoIdentifier`), which for a
    /// bundled app equals the bundle identifier — but unlike `Info.plist`, the
    /// signing identifier is something the signature actually vouches for.
    ///
    /// Exactly one entry. Trusting a second, "we also shipped this once" identifier is
    /// how another binary ends up issuing root SMC writes; an out-of-alignment build
    /// must be reinstalled. The daemon logs the identifier it refused, so that failure
    /// is diagnosable from `log show --predicate 'process == "fancurve-helper"'`.
    public static let allowedClientBundleIdentifiers: Set<String> = [
        appBundleIdentifier
    ]

    /// Apple Developer Program team IDs whose signature is accepted. A client whose
    /// signature carries a team id must match one of these; an ad-hoc signed client
    /// (the default build) has no team id and is accepted on signing-identifier +
    /// cdhash-logging grounds (see `strictClientCdHashes`).
    ///
    /// Empty by default: ad-hoc builds need no entry. If you sign releases with
    /// your own Developer ID, add your team identifier here — a client signed
    /// with an unknown team id is refused, by design.
    public static let allowedTeamIdentifiers: Set<String> = []

    /// Optional pinning for development builds: cdhashes (`kSecCodeInfoUnique`,
    /// logged by the daemon on every ad-hoc connection) that are allowed when the
    /// client has no team identifier. Empty means "any validly signed build of an
    /// allowed identifier".
    public static let strictClientCdHashes: Set<String> = []

    /// System install location of the daemon binary. Living outside the app
    /// bundle is deliberate: rebuilding or reinstalling the app must never
    /// break the running control service (and must never force another
    /// authorization prompt).
    public static let daemonProgramPath = "/Library/fancurve/fancurve-helper"

    /// The one-time install script template. `%BUNDLE%` is replaced with the
    /// app bundle path at runtime. Requires administrator privileges; after it
    /// runs once, the daemon survives every future app rebuild untouched.
    ///
    /// `%BUNDLE%` is substituted with the *shell-quoted* app bundle path and assigned
    /// to a variable once — interpolating a quoted path inside `"%BUNDLE%/…"` would
    /// put literal apostrophes in the middle of the path.
    ///
    /// Ordering, and why:
    ///  1. `bootout` the job **before** anything touches the binary. `cp` truncates and
    ///     writes in place, so copying onto a *running* daemon replaces the live
    ///     process's mmap'd `__TEXT` pages under it — and that succeeds rather than
    ///     failing with ETXTBSY, which is worse than an error: the daemon keeps running
    ///     mixed code until the next page fault.
    ///  2. Write to a temporary file in the destination directory and `mv` it into
    ///     place. Rename is atomic and leaves the old inode alive for anything still
    ///     executing it, so a crash mid-install cannot leave a half-written daemon.
    ///  3. `chown`/`chmod` before the rename, on the temp file.
    ///  4. `bootstrap` then `enable` then `kickstart -k`, so a disabled label does not
    ///     sit there refusing to start.
    ///
    /// Every step is idempotent, and the whole script exits 0 even on a re-install.
    public static let daemonInstallScript = """
    set -e; \
    LABEL=com.local.fancurve.app.helper; \
    BUNDLE=%BUNDLE%; \
    launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true; \
    mkdir -p /Library/fancurve; \
    TMP=/Library/fancurve/.helper.$$; \
    cp "$BUNDLE/Contents/MacOS/fancurve-helper" "$TMP"; \
    chmod 755 "$TMP"; \
    chown root:wheel "$TMP"; \
    mv -f "$TMP" /Library/fancurve/fancurve-helper; \
    PTMP=/Library/LaunchDaemons/.helper.plist.$$; \
    cp "$BUNDLE/Contents/Library/LaunchDaemons/$LABEL.plist" "$PTMP"; \
    chmod 644 "$PTMP"; \
    chown root:wheel "$PTMP"; \
    mv -f "$PTMP" "/Library/LaunchDaemons/$LABEL.plist"; \
    launchctl enable "system/$LABEL" >/dev/null 2>&1 || true; \
    launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist" >/dev/null 2>&1 || true; \
    launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true; \
    exit 0
    """
}

/// XPC interface the privileged helper exposes. Deliberately tiny: it offers
/// only the operations that require root — SMC *writes*. Sensor/state *reads*
/// don't need privilege and stay in the unprivileged app process
/// (`SystemStatusReader`), which keeps the root attack surface minimal.
@objc public protocol FanCurveHelperProtocol {
    /// - Parameters:
    ///   - fanId: zero-based fan index.
    ///   - mode: `0` = automatic (macOS-managed), `1` = manual/forced.
    ///   - speed: target RPM, only used when `mode == 1`.
    ///   - reply: `(success, message)`.
    func setFan(fanId: Int, mode: Int, speed: Int, withReply reply: @escaping (Bool, String) -> Void)

    /// Return every fan to macOS automatic control.
    func resetAll(withReply reply: @escaping (Bool, String) -> Void)

    /// Liveness/handshake check confirming the daemon is reachable and that the
    /// client passed code-signature validation.
    func ping(withReply reply: @escaping (String) -> Void)
}
