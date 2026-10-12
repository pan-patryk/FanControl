//
//  main.swift
//  FanCurve Helper — XPC daemon (no args) or CLI (with args)
//
//  Two personalities, one binary:
//   • No arguments → an XPC server on `com.local.fancurve.app.helper`.
//     launchd runs it as a root daemon (/Library/LaunchDaemons), so it needs
//     no setuid bit, no per-rebuild re-authorization, and no prompts after
//     the one-time install.
//   • With arguments → the CLI (`get` / `set` / `reset` / `keys`), used by the
//     dev tools and by the app's setuid-helper fallback path.
//
//  Sources: this file plus `Core/SMC*.swift`, `Models/FanJSON.swift` and
//  `Shared/FanCurveHelperProtocol.swift` — see `build.sh`'s HELPER_SOURCES and the
//  `fancurve-helper` target in `project.yml`. The wire shapes come from `Models/`
//  rather than being re-declared here: two copies of a wire shape is how the CLI and
//  the app drift apart, and `FanJSON.swift` has no dependencies beyond Foundation.

import Foundation
import Security

/// Dumps the raw key metadata the decoding in this file depends on.
/// `fancurve-helper keys [KEY …]` — with no arguments, the built-in list.
func dumpKeys(_ keys: [String]) {
    let smc = SMC.shared
    let list = keys.isEmpty ? [
        "FNum", "FS! ", "Ftst",
        "F0Ac", "F0Mn", "F0Mx", "F0Tg", "F0Md", "F0md", "F0ID", "F0!t", "F0!T", "F0Cx", "F0FG",
        "TC0P", "TC0D", "TC0F", "Tp09", "TG0P", "TB0T", "TB1T", "Th0H", "Qwas", "CLPC", "PDTR"
    ] : keys
    for key in list {
        print(smc.keyInfo(key) ?? "\(key): nil")
    }
}

func printHelp() {
    let help = """
    SMC FanCurve Helper CLI
    Usage:
      fancurve-helper get
      fancurve-helper set <fanId> <mode> [<speed>]   (mode: 0 = auto, 1 = manual; speed in RPM)
      fancurve-helper reset
      fancurve-helper keys [KEY ...]     print raw SMC key types/bytes (no privilege needed)
    """
    print(help)
}

func getStatus() {
    let smc = SMC.shared
    
    guard let fanCountVal = smc.getValue("FNum") else {
        print("{}")
        return
    }
    
    let fanCount = Int(fanCountVal)
    var fansList: [FanJSON] = []
    
    for i in 0..<fanCount {
        let name = smc.getStringValue("F\(i)ID") ?? "Fan \(i)"
        let current = Int(smc.getValue("F\(i)Ac") ?? 0)
        let minS = Int(smc.getValue("F\(i)Mn") ?? 0)
        let maxS = Int(smc.getValue("F\(i)Mx") ?? 0)
        let target = Int(smc.getValue("F\(i)Tg") ?? 0)
        
        let modeKey = smc.fanModeKey(i)
        let mode = Int(smc.getValue(modeKey) ?? 0)
        
        fansList.append(FanJSON(
            id: i,
            name: name,
            currentSpeed: current,
            minSpeed: minS,
            maxSpeed: maxS,
            targetSpeed: target,
            mode: mode
        ))
    }
    
    // Read typical temperature sensors with comprehensive Intel / Apple Silicon fallback list
    let cpuKeys = [
        "TC0P", "TC0D", "TC0F", "TC1C", "TCAD", "TCBD",
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0C", "Tp0g", "Tp0h", "Te0S"
    ]
    let gpuKeys = [
        "TG0D", "TG0H", "TG0P",
        "Tg05", "Tg0j", "Tg0g", "Tg01", "Tg0c"
    ]
    let batteryKeys = [
        "TB0T", "TB1T", "TB2T", "Tw0P", "Ts0P", "Th0H"
    ]
    
    func getFirstValidTemp(keys: [String]) -> Double? {
        for key in keys {
            // Ignore values outside a physically plausible die-temperature range.
            // Some Apple Silicon SMC keys temporarily report tiny non-zero values.
            if let val = smc.getValue(key), val >= 10 && val <= 115 {
                return val
            }
        }
        return nil
    }

    func getMaximumValidTemp(keys: [String]) -> Double? {
        keys.compactMap { key -> Double? in
            guard let value = smc.getValue(key),
                  value.isFinite,
                  value >= 10,
                  value <= 115 else {
                return nil
            }
            return value
        }
        .max()
    }
    
    // CPU keys describe several plausible CPU-adjacent sensors. Using the
    // highest valid reading is conservative for thermal control and avoids
    // making the result depend on the first key that happens to respond.
    let cpuTemp = getMaximumValidTemp(keys: cpuKeys)
    let gpuTemp = getFirstValidTemp(keys: gpuKeys)
    let batteryTemp = getFirstValidTemp(keys: batteryKeys)
    
    let status = SystemStatusJSON(
        fans: fansList,
        cpuTemp: cpuTemp,
        gpuTemp: gpuTemp,
        batteryTemp: batteryTemp
    )
    
    if let jsonData = try? JSONEncoder().encode(status),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
    } else {
        print("{}")
    }
}

/// The SMC write logic, shared by the CLI and the XPC daemon.
enum HelperFanWrite {
    @discardableResult
    static func set(fanId: Int, mode: Int, speed: Int?) -> (Bool, String) {
        let smc = SMC.shared

        if mode == 0 {
            return smc.setFanMode(fanId, mode: .automatic)
                ? (true, "fan \(fanId) → automatic")
                : (false, "failed to set fan \(fanId) to automatic")
        } else if mode == 1 {
            guard let targetSpeed = speed else {
                return (false, "speed in RPM is required for manual mode")
            }
            // 1. Set mode to forced, 2. then the speed.
            guard smc.setFanMode(fanId, mode: .forced) else {
                return (false, "failed to set fan \(fanId) mode to manual")
            }
            return smc.setFanSpeed(fanId, speed: targetSpeed)
                ? (true, "fan \(fanId) → manual \(targetSpeed) rpm")
                : (false, "failed to set fan \(fanId) speed to \(targetSpeed) rpm")
        } else {
            return (false, "invalid mode. use 0 for auto, 1 for manual")
        }
    }
}

func setFan(fanId: Int, mode: Int, speed: Int?) {
    let (success, message) = HelperFanWrite.set(fanId: fanId, mode: mode, speed: speed)
    if success {
        print("SUCCESS: \(message)")
    } else {
        print("ERROR: \(message)")
        exit(1)
    }
}

// MARK: - XPC daemon mode

/// The privileged end of the XPC connection: only the three SMC *writes*.
/// Reads never come through here (the app reads sensors in-process), which
/// keeps the root attack surface at three validated integer arguments.
final class FanCurveHelperService: NSObject, FanCurveHelperProtocol {
    // `SMC.shared` owns one IOKit connection and is not re-entrant; XPC
    // replies arrive on a thread-pool queue, so serialize all SMC use.
    private let smcQueue = DispatchQueue(label: "com.local.fancurve.helper.smc")

    func setFan(fanId: Int, mode: Int, speed: Int, withReply reply: @escaping (Bool, String) -> Void) {
        smcQueue.async {
            let (success, message) = HelperFanWrite.set(fanId: fanId, mode: mode, speed: mode == 1 ? speed : nil)
            reply(success, message)
        }
    }

    func resetAll(withReply reply: @escaping (Bool, String) -> Void) {
        smcQueue.async {
            let success = SMC.shared.resetFanControl()
            reply(success, success ? "all fans → automatic" : "reset failed")
        }
    }

    /// Liveness, honestly reported.
    ///
    /// The reply includes the fan count the daemon can actually read, and the app
    /// treats `fans=0` as not-live. A bare `pong` would be returned just as happily
    /// by a daemon that had lost its IOKit connection, which makes the "control
    /// service live" indicator true while every write fails.
    func ping(withReply reply: @escaping (String) -> Void) {
        smcQueue.async {
            let count = SMC.shared.getValue("FNum").map { Int($0) } ?? 0
            reply("pong pid=\(getpid()) fans=\(count)")
        }
    }
}

/// Strong references for the lifetime of the daemon (NSXPCListener.delegate is
/// weak, so the gate must be retained; NSXPC also retains the exported object
/// per connection).
private var daemonService: FanCurveHelperService?
private var daemonGate: ConnectionGate?

/// Decides whether a connecting process may drive the fans.
///
/// A peer that can drive the fans is identified by its code signature, never by its
/// path. A path and an `Info.plist` are attacker-controlled: any binary could name
/// itself `…/FanCurve.app/Contents/MacOS/whatever` with `com.local.fancurve.app` in
/// the plist, connect to this root daemon, and pin the fans — or hold them at 0 rpm
/// while the machine cooks. `Info.plist` is not part of what a code signature vouches
/// for, so resolving `proc_pidpath` from `connection.processIdentifier` and reading
/// the bundle id out of that folder is not an authorization check.
///
/// **What the OS documentation prescribes:**
/// - `NSXPCConnection.h`: `processIdentifier`, `effectiveUserIdentifier` and
///   `auditSessionIdentifier` are all documented as "may be used by the listener
///   delegate to accept or reject connections", with the audit session identifier
///   described as "The BSM audit session identifier for the connecting process".
/// - `SecCode.h`: `SecCodeCopyGuestWithAttributes(NULL, attributes, …)` is "the
///   omnibus API function for obtaining dynamic code references"; asking the NULL
///   host (the kernel) for `kSecGuestAttributeAudit` / `kSecGuestAttributePid`
///   returns a `SecCode` for that running process. The kernel hands back the code
///   object for the *audit token the XPC layer attached to the connection*, which
///   a client cannot forge.
/// - `SecCode.h`: `SecCodeCheckValidity*` "Performs dynamic validation … It checks
///   the SecCode's dynamic validity status as reported by its host … This call is
///   secure against attempts to modify the file system source of the SecCode."
///   Dynamic validity is what rejects a process with an injected library, which a
///   path/plist check could never see.
/// - `SecCode.h`: `kSecCodeInfoIdentifier` is "the actual signing identifier",
///   `kSecCodeInfoTeamIdentifier` the Apple Team ID ("Signing" → needs
///   `kSecCSSigningInformation`), and `kSecCodeInfoUnique` "a CFData binary
///   identifier that uniquely identifies the static code … can be used to
///   recognize this particular code (and none other)".
///
/// Policy, in that order:
/// 1. resolve the peer's `SecCode` from its audit session id, falling back to its
///    pid (pid can be recycled between the two calls; the audit token cannot);
/// 2. require a *valid* signature, including dynamic validity;
/// 3. require the signing identifier to be one of the known app identifiers;
/// 4. if a team identifier is present (Developer ID / Mac App Store builds), require
///    it to be one of ours; an **ad-hoc** build legitimately has none, so it is
///    accepted with its cdhash logged — see `HelperConstants.strictClientCdHashes`
///    for pinning a specific development binary.
final class ConnectionGate: NSObject, NSXPCListenerDelegate {
    let service: FanCurveHelperService

    init(service: FanCurveHelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        let uid = connection.effectiveUserIdentifier
        let audit = connection.auditSessionIdentifier

        switch validateClient(pid: pid, audit: audit) {
        case .accepted(let identity):
            log("accepted pid=\(pid) uid=\(uid) \(identity)")
            connection.exportedObject = service
            connection.exportedInterface = NSXPCInterface(with: FanCurveHelperProtocol.self)
            connection.interruptionHandler = { }
            connection.invalidationHandler = { }
            connection.resume()
            return true
        case .refused(let reason):
            log("REFUSED pid=\(pid) uid=\(uid) — \(reason)")
            return false   // the listener invalidates the connection for us
        }
    }

    private enum Verdict {
        case accepted(identity: String)
        case refused(String)
    }

    private func validateClient(pid: pid_t, audit: au_asid_t) -> Verdict {
        // 1. Resolve the peer's dynamic code object.
        var code: SecCode?
        var resolvedBy = "audit"
        var status = SecCodeCopyGuestWithAttributes(
            nil, [kSecGuestAttributeAudit: NSNumber(value: audit)] as CFDictionary, [], &code)
        if status != errSecSuccess {
            resolvedBy = "pid"
            status = SecCodeCopyGuestWithAttributes(
                nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code)
        }
        guard status == errSecSuccess, let peerCode = code else {
            return .refused("cannot resolve client code (SecCodeCopyGuestWithAttributes \(status) via audit/pid)")
        }

        // 2. Validate the signature, including dynamic validity (rejects unsigned,
        //    tampered and library-injected processes).
        var validityError: Unmanaged<CFError>?
        let valid = SecCodeCheckValidityWithErrors(peerCode, [], nil, &validityError)
        guard valid == errSecSuccess else {
            let detail = validityError.map { $0.takeRetainedValue().localizedDescription } ?? "status \(valid)"
            return .refused("client signature invalid (\(detail))")
        }

        // 3/4. Signing identifier + team identifier.
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(peerCode, [], &staticCode) == errSecSuccess, let staticCode else {
            return .refused("cannot read client's static code")
        }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [CFString: Any] else {
            return .refused("cannot read client signing information")
        }

        let identifier = (info[kSecCodeInfoIdentifier] as? String) ?? ""
        let team = info[kSecCodeInfoTeamIdentifier] as? String
        let cdhash = (info[kSecCodeInfoUnique] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() } ?? "?"

        guard HelperConstants.allowedClientBundleIdentifiers.contains(identifier) else {
            return .refused("signing identifier ‘\(identifier)’ is not an allowed client (cdhash \(cdhash))")
        }
        if let team, !team.isEmpty {
            guard HelperConstants.allowedTeamIdentifiers.contains(team) else {
                return .refused("team identifier ‘\(team)’ is not ours (client \(identifier), cdhash \(cdhash))")
            }
            return .accepted(identity: "\(identifier) team=\(team) resolvedBy=\(resolvedBy)")
        }
        // Ad-hoc signature: no team id exists to check. Accept, and log the cdhash so
        // a developer can pin it via `strictClientCdHashes` if they want it.
        log("note: ad-hoc signed client \(identifier) cdhash=\(cdhash) (pin it in HelperConstants.strictClientCdHashes to require it)")
        if !HelperConstants.strictClientCdHashes.isEmpty, !HelperConstants.strictClientCdHashes.contains(cdhash) {
            return .refused("ad-hoc client cdhash not in the pinned set")
        }
        return .accepted(identity: "\(identifier) ad-hoc cdhash=\(cdhash) resolvedBy=\(resolvedBy)")
    }

    /// Daemon diagnostics go to the launchd-captured stderr
    /// (`/var/log/fancurve-helper.err`), never to stdout, which the CLI personality
    /// reserves for machine-readable output.
    private func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("fancurve-helper[\(getpid())]: \(message)\n".utf8))
    }
}

func runDaemon() {
    let service = FanCurveHelperService()
    daemonService = service
    let gate = ConnectionGate(service: service)
    daemonGate = gate

    let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
    listener.delegate = gate
    // (exported object/interface are set per-connection in the delegate; the
    // modern NSXPCListener no longer carries them itself.)

    listener.activate()

    try? FileHandle.standardError.write(contentsOf: Data("fancurve-helper: XPC daemon ready on \(HelperConstants.machServiceName) (pid \(getpid()))\n".utf8))
    dispatchMain()
}

func main() {
    let args = CommandLine.arguments

    // No arguments: launchd (or a developer) wants the XPC daemon.
    guard args.count > 1 else {
        runDaemon()
        return
    }
    
    let cmd = args[1].lowercased()
    
    switch cmd {
    case "get":
        getStatus()
    case "set":
        guard args.count >= 4 else {
            print("ERROR: Missing arguments for 'set'")
            printHelp()
            exit(1)
        }
        guard let fanId = Int(args[2]), let mode = Int(args[3]) else {
            print("ERROR: Invalid fanId or mode")
            exit(1)
        }
        let speed = args.count > 4 ? Int(args[4]) : nil
        setFan(fanId: fanId, mode: mode, speed: speed)
    case "keys":
        // Decoding self-check: prints the type/size/bytes the firmware reports for
        // every key this helper interprets. Needs no privilege.
        dumpKeys(Array(args.dropFirst(2)))
    case "reset":
        let success = SMC.shared.resetFanControl()
        if success {
            print("SUCCESS: Reset fan controls")
        } else {
            print("ERROR: Failed to reset fan controls")
            exit(1)
        }
    default:
        print("ERROR: Unknown command '\(cmd)'")
        printHelp()
        exit(1)
    }
}

main()
