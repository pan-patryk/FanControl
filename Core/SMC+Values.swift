// SMC+Values.swift — decoding SMC register payloads into Swift values.
//
// Two entry points, both read-only: `getValue` for the numeric types the firmware
// reports, `getStringValue` for the `{fds` text type. `keyInfo` is the diagnostic
// that lets the decoding assumptions in `SMC.swift` be checked on real hardware.

import Foundation
import IOKit

extension SMC {

    /// Raw metadata for one SMC key: the type the firmware reports, its size and the
    /// bytes read. Every decoding assumption here (that `F0Tg` is `flt `, that `F0Ac`
    /// is a float, that the mode key is a `ui8`, that the mode key is lower-case
    /// `F0md` on Apple Silicon) is an assertion about firmware data, so this exists to
    /// check them against a real machine instead of a blog post
    /// (`fancurve-helper keys`).
    public func keyInfo(_ key: String) -> String? {
        var val = SMCVal_t(key)
        let result = read(&val)
        if result != kIOReturnSuccess {
            let code = String(UInt32(bitPattern: result), radix: 16)
            return "\(key): read failed (\(String(cString: mach_error_string(result), encoding: .ascii) ?? "?") 0x\(code))"
        }
        let hex = val.bytes.prefix(Int(val.dataSize)).map { String(format: "%02x", $0) }.joined(separator: " ")
        return "\(key): type=\(val.dataType.isEmpty ? "?" : val.dataType) size=\(val.dataSize) bytes=[\(hex)] double=\(String(describing: getValue(key)))"
    }

    public func getValue(_ key: String) -> Double? {
        var result: kern_return_t = 0
        var val: SMCVal_t = SMCVal_t(key)

        result = read(&val)
        if result != kIOReturnSuccess {
            return nil
        }

        if val.dataSize > 0 {
            // A genuine 0 (fan stopped, `FS! ` clear, a temperature at 0 °C) is data
            // and must be returned. `read()` already fails on an SMC-level error, so
            // there is no "all bytes are zero means no data" heuristic to fall back on
            // — a key-suffix blacklist would silently blank every legitimately-zero
            // sensor.
            switch val.dataType {
            case SMCDataType.UI8.rawValue:
                return Double(val.bytes[0])
            case SMCDataType.UI16.rawValue:
                return Double(UInt16(bytes: (val.bytes[0], val.bytes[1])))
            case SMCDataType.UI32.rawValue:
                return Double(UInt32(bytes: (val.bytes[0], val.bytes[1], val.bytes[2], val.bytes[3])))
            case SMCDataType.SP1E.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 16384)
            case SMCDataType.SP3C.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 4096)
            case SMCDataType.SP4B.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 2048)
            case SMCDataType.SP5A.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 1024)
            case SMCDataType.SP69.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 512)
            case SMCDataType.SP78.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 256)
            case SMCDataType.SP87.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 128)
            case SMCDataType.SP96.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 64)
            case SMCDataType.SPA5.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 32)
            case SMCDataType.SPB4.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 16)
            case SMCDataType.SPF0.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return intValue
            case SMCDataType.FLT.rawValue:
                let value: Float? = Float(val.bytes)
                if value != nil {
                    return Double(value!)
                }
                return nil
            case SMCDataType.FPE2.rawValue:
                return Double(Int(fromFPE2: (val.bytes[0], val.bytes[1])))
            default:
                return nil
            }
        }

        return nil
    }

    public func getStringValue(_ key: String) -> String? {
        var result: kern_return_t = 0
        var val: SMCVal_t = SMCVal_t(key)

        result = read(&val)
        if result != kIOReturnSuccess {
            return nil
        }

        if val.dataSize > 0 {
            switch val.dataType {
            case SMCDataType.FDS.rawValue:
                // FDS stores its text starting at byte 4. Bound the read by `dataSize`
                // (a hard-coded length pads short keys with junk and truncates long
                // ones) and keep only printable ASCII.
                let start = 4
                let end = min(start + Int(val.dataSize), val.bytes.count)
                guard start < end else { return nil }
                let printable = val.bytes[start..<end].filter { $0 >= 0x20 && $0 < 0x7f }
                guard let decoded = String(bytes: printable, encoding: .ascii)?
                    .trimmingCharacters(in: .whitespaces), !decoded.isEmpty else { return nil }
                return decoded
            default:
                return nil
            }
        }

        return nil
    }

}
