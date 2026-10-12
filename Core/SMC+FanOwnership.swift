// SMC+FanOwnership.swift — claiming and releasing individual fans.
//
// A fan is either firmware-owned (`automatic`) or ours (`forced`). The two
// architectures express that differently: Apple Silicon has a per-fan mode key
// (`F<n>md` / `F<n>Md`) plus a target, Intel has one `FS! ` bitmask. This file
// presents one `setFanMode` / `setFanSpeed` surface over both.

import Foundation
import IOKit

extension SMC {

    public func fanModeKey(_ id: Int) -> String {
        #if arch(arm64)
        if _fanModeKeyIsLower == nil {
            var probe = SMCVal_t("F0md")
            _fanModeKeyIsLower = read(&probe) == kIOReturnSuccess && probe.dataSize > 0
        }
        return _fanModeKeyIsLower! ? "F\(id)md" : "F\(id)Md"
        #else
        return "F\(id)Md"
        #endif
    }

    public func setFanMode(_ id: Int, mode: FanMode) -> Bool {
        #if arch(arm64)
        if mode == .forced {
            return unlockFanControl(fanId: id)
        } else {
            let modeKey = fanModeKey(id)
            let targetKey = "F\(id)Tg"

            if self.getValue(modeKey) != nil {
                var modeVal = SMCVal_t(modeKey)
                let readResult = read(&modeVal)
                guard readResult == kIOReturnSuccess else {
                    print(smcError("read", key: modeKey, result: readResult))
                    return false
                }
                if modeVal.bytes[0] != 0 {
                    modeVal.bytes[0] = 0
                    if !writeWithRetry(modeVal) { return false }
                }
            }

            var targetValue = SMCVal_t(targetKey)
            let result = read(&targetValue)
            guard result == kIOReturnSuccess else {
                print(smcError("read", key: targetKey, result: result))
                return false
            }

            let bytes = Float(0).bytes
            targetValue.bytes[0] = bytes[0]
            targetValue.bytes[1] = bytes[1]
            targetValue.bytes[2] = bytes[2]
            targetValue.bytes[3] = bytes[3]

            return writeWithRetry(targetValue)
        }
        #else
        // Intel
        if self.getValue("F\(id)Md") != nil {
            var result: kern_return_t = 0
            var value = SMCVal_t("F\(id)Md")

            result = read(&value)
            if result != kIOReturnSuccess {
                print("Error read fan mode: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
                return false
            }

            value.bytes = [UInt8(mode.rawValue), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0)]

            result = write(value)
            if result != kIOReturnSuccess {
                print("Error write: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
                return false
            }
        }

        // `FS! ` is a bitmask: bit n forces fan n. The mask must be read-modify-
        // written, never rebuilt from a per-fan table — a table that only covers two
        // fans clears the whole mask on a 4- or 6-fan Mac, so forcing fan 3 silently
        // hands fans 1 and 2 back to firmware.
        let fansMode = Int(self.getValue("FS! ") ?? 0)
        let bit = 1 << id
        let newMode: Int
        switch mode {
        case .forced: newMode = fansMode | bit
        case .automatic, .auto3:
            // `auto3` (some Intel firmwares) is still "not forced": clearing the bit
            // hands the fan back.
            newMode = fansMode & ~bit
        }

        if fansMode == newMode {
            return true   // idempotent: no write, no thermalmonitord churn
        }

        var result: kern_return_t = 0
        var value = SMCVal_t("FS! ")

        result = read(&value)
        if result != kIOReturnSuccess {
            print("Error read fan mode: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }

        value.bytes = [0, UInt8(truncatingIfNeeded: newMode), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0)]

        result = write(value)
        if result != kIOReturnSuccess {
            print("Error write: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }
        return true
        #endif
    }

    public func setFanSpeed(_ id: Int, speed: Int) -> Bool {
        guard let maxSpeed = self.getValue("F\(id)Mx") else { return false }
        // Clamp to the fan's full physical range: a target below F<n>Mn is
        // rejected by the SMC on some machines, and a manual minimum is still
        // a real fan speed the user asked for.
        let minSpeed = Int(self.getValue("F\(id)Mn") ?? 0)
        let targetSpeed = max(min(speed, Int(maxSpeed)), minSpeed)

        #if arch(arm64)
        var modeVal = SMCVal_t(fanModeKey(id))
        let modeResult = read(&modeVal)
        guard modeResult == kIOReturnSuccess else {
            print("Error read fan mode: " + (String(cString: mach_error_string(modeResult), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }
        if modeVal.bytes[0] != 1 {
            if !unlockFanControl(fanId: id) { return false }
        }
        #endif

        var result: kern_return_t = 0
        var value = SMCVal_t("F\(id)Tg")

        result = read(&value)
        if result != kIOReturnSuccess {
            print("Error read fan value: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }

        // Elide a write that cannot change anything: an identical `F0Tg` write is
        // wasted IOKit traffic, and it is how a wedged controller could still look
        // alive. The view model skips the obvious cases; this catches everything that
        // reaches the hardware layer. The mode has already been forced above, so
        // returning early here is safe on both arches.
        if let current = readSpeed(from: value), abs(current - Double(targetSpeed)) < 1.0 {
            return true
        }

        if value.dataType == "flt " {
            let bytes = Float(targetSpeed).bytes
            value.bytes[0] = bytes[0]
            value.bytes[1] = bytes[1]
            value.bytes[2] = bytes[2]
            value.bytes[3] = bytes[3]
        } else if value.dataType == "fpe2" {
            value.bytes[0] = UInt8(targetSpeed >> 6)
            value.bytes[1] = UInt8((targetSpeed << 2) ^ ((targetSpeed >> 6) << 8))
            value.bytes[2] = UInt8(0)
            value.bytes[3] = UInt8(0)
        }

        #if arch(arm64)
        return writeWithRetry(value)
        #else
        result = write(value)
        if result != kIOReturnSuccess {
            print("Error write: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }
        return true
        #endif
    }

    /// Decode the speed already held in an `F<n>Tg` value struct, using the inverse
    /// of the two encodings the write path above understands.
    func readSpeed(from value: SMCVal_t) -> Double? {
        switch value.dataType {
        case "flt ":
            // Little-endian, byte by byte: `load(as: Float.self)` over [UInt8]
            // storage is not guaranteed aligned, and a misaligned load traps.
            let bits = UInt32(value.bytes[0])
                | UInt32(value.bytes[1]) << 8
                | UInt32(value.bytes[2]) << 16
                | UInt32(value.bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            return Double((Int(value.bytes[0]) << 6) + (Int(value.bytes[1]) >> 2))
        default:
            return nil
        }
    }
}
