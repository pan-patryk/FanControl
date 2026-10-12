// SMC+Unlock.swift — the Apple Silicon fan-ownership handshake.
//
// On Apple Silicon, forcing a fan is not a single write. `thermalmonitord` holds the
// mode key, and on M1–M4 the client has to raise the `Ftst` test key, wait for
// thermalmonitord to yield, and only then write the per-fan mode key. On M5+ the mode
// key takes a direct write and `Ftst` does not exist.
//
// Everything here is bounded by wall clock, because these functions run on the XPC
// delivery queue inside the root daemon: a stall is indistinguishable from a hang.

import Foundation
import IOKit

extension SMC {

    // MARK: - Apple Silicon: taking a fan away from thermalmonitord

    #if arch(arm64)
    /// Writes with retries, bounded by BOTH an attempt count and a wall-clock
    /// deadline. A count-only bound can sleep for tens of seconds inside a single
    /// fan command, which is a stall in the XPC delivery queue.
    func writeWithRetry(_ value: SMCVal_t, maxAttempts: Int = 10, delayMicros: UInt32 = 50_000,
                                deadline: TimeInterval = 0.5) -> Bool {
        let mutableValue = value
        let limit = Date().addingTimeInterval(deadline)
        var lastResult: kern_return_t = kIOReturnSuccess
        for attempt in 0..<maxAttempts {
            lastResult = write(mutableValue)
            if lastResult == kIOReturnSuccess {
                return true
            }
            if attempt == maxAttempts - 1 || Date() >= limit { break }
            usleep(min(delayMicros, 100_000))
        }
        print(smcError("write", key: value.key, result: lastResult))
        return false
    }

    /// Force a fan and return true once the SMC agrees it is ours.
    ///
    /// Bounded by the total `unlockBudget` wall clock: this runs on the XPC delivery
    /// queue, so a long stall here makes the daemon look hung, times out the client's
    /// 2 s ping, and flickers the "control service live" indicator.
    func unlockFanControl(fanId: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Self.unlockBudget)

        // Try direct mode write first (works on M5+ without Ftst)
        let modeKey = fanModeKey(fanId)
        var modeVal = SMCVal_t(modeKey)
        let modeRead = read(&modeVal)
        guard modeRead == kIOReturnSuccess else {
            print(smcError("read", key: modeKey, result: modeRead))
            return false
        }
        if modeVal.bytes[0] == 1 { return true }
        modeVal.bytes[0] = 1
        if write(modeVal) == kIOReturnSuccess {
            return true
        }

        // Direct failed; try Ftst unlock (M1-M4)
        var ftstVal = SMCVal_t("Ftst")
        let ftstResult = read(&ftstVal)
        guard ftstResult == kIOReturnSuccess, ftstVal.dataSize > 0 else {
            return false
        }

        if ftstVal.bytes[0] != 1 {
            ftstVal.bytes[0] = 1
            guard writeWithRetry(ftstVal, maxAttempts: 100, deadline: 0.3) else { return false }
            // thermalmonitord needs a moment to yield, and a fixed sleep is not
            // acceptable in a request path: poll the mode key and return the moment
            // it takes.
            while Date() < deadline {
                usleep(20_000)
                if retryModeWriteOnce(fanId: fanId) { return true }
            }
            return false
        }

        return retryModeWrite(fanId: fanId, maxAttempts: 20, deadline: deadline)
    }

    /// One non-retaining attempt at the mode write, for the polling loop above.
    func retryModeWriteOnce(fanId: Int) -> Bool {
        var modeVal = SMCVal_t(fanModeKey(fanId))
        guard read(&modeVal) == kIOReturnSuccess else { return false }
        modeVal.bytes[0] = 1
        return write(modeVal) == kIOReturnSuccess
    }

    /// Wall-clock budget for taking one fan away from `thermalmonitord`.
    static let unlockBudget: TimeInterval = 1.0

    func retryModeWrite(fanId: Int, maxAttempts: Int, deadline: Date) -> Bool {
        let modeKey = fanModeKey(fanId)
        var modeVal = SMCVal_t(modeKey)
        let result = read(&modeVal)
        guard result == kIOReturnSuccess else {
            print(smcError("read", key: modeKey, result: result))
            return false
        }
        modeVal.bytes[0] = 1
        let remaining = max(deadline.timeIntervalSinceNow, 0)
        return writeWithRetry(modeVal, maxAttempts: maxAttempts, delayMicros: 100_000,
                              deadline: min(remaining, 0.5))
    }

    #endif

    public func resetFanControl() -> Bool {
        var success = true
        var hasFtst = false
        var ftstVal = SMCVal_t("Ftst")
        
        #if arch(arm64)
        let ftstReadResult = read(&ftstVal)
        hasFtst = (ftstReadResult == kIOReturnSuccess && ftstVal.dataSize > 0)
        
        if hasFtst {
            if ftstVal.bytes[0] != 1 {
                ftstVal.bytes[0] = 1
                if !writeWithRetry(ftstVal, maxAttempts: 100, deadline: 0.3) {
                    print("Failed to unlock Ftst for reset")
                } else {
                    // Wait for thermalmonitord to yield, but keep it short: this is on
                    // the quit path.
                    usleep(200_000)
                }
            }
        }
        #endif

        guard let count = getValue("FNum") else { return false }
        for i in 0..<Int(count) {
            if !setFanMode(i, mode: .automatic) {
                success = false
            }
        }

        #if arch(arm64)
        if hasFtst {
            ftstVal.bytes[0] = 0
            if !writeWithRetry(ftstVal, maxAttempts: 100, deadline: 0.3) {
                success = false
            }
        }
        #endif

        return success
    }
}
