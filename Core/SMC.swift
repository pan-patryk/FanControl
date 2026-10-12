// SMC.swift — the raw Apple System Management Controller client.
//
// The IOKit `AppleSMC` service is a keyed register file with a 32-byte payload per
// key. This file holds the wire structures and the transport (open / close / read /
// write / call). Key decoding lives in `SMC+Values.swift`, fan ownership in
// `SMC+FanOwnership.swift`, the Apple Silicon unlock dance in `SMC+Unlock.swift`.
//
// It is compiled into both the app and the root helper, so it must stay free of
// SwiftUI, AppKit and `UserDefaults`.

import Foundation
import IOKit

internal enum SMCDataType: String {
    case UI8 = "ui8 "
    case UI16 = "ui16"
    case UI32 = "ui32"
    case SP1E = "sp1e"
    case SP3C = "sp3c"
    case SP4B = "sp4b"
    case SP5A = "sp5a"
    case SPA5 = "spa5"
    case SP69 = "sp69"
    case SP78 = "sp78"
    case SP87 = "sp87"
    case SP96 = "sp96"
    case SPB4 = "spb4"
    case SPF0 = "spf0"
    case FLT = "flt "
    case FPE2 = "fpe2"
    case FP2E = "fp2e"
    case FDS = "{fds"
}

internal enum SMCKeys: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
    case readPLimit = 11
    case readVers = 12
}

public enum FanMode: Int, Codable {
    case automatic = 0
    case forced = 1
    case auto3 = 3
}

internal struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)

    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0))
}

internal struct SMCVal_t {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes: [UInt8] = Array(repeating: 0, count: 32)

    init(_ key: String) {
        self.key = key
    }
}

extension FourCharCode {
    /// SMC keys are exactly four **ASCII** bytes.
    ///
    /// Failable, and the callers turn a nil into an error return. A key that is a
    /// mistyped interpolation ("F\(id)Md" with an unexpected id) or a non-ASCII name
    /// from a config file must not abort the process — inside the daemon that would
    /// kill fan control for the whole machine.
    init?(ascii str: String) {
        guard str.utf8.count == 4 else { return nil }
        var code: FourCharCode = 0
        for byte in str.utf8 {
            guard byte < 0x80 else { return nil }
            code = code << 8 | FourCharCode(byte)
        }
        self = code
    }

    func toString() -> String {
        var out = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((self >> UInt32(shift)) & 0xff)
            // Non-printable bytes become "?" instead of producing Latin-1 mojibake.
            out.append(byte >= 0x20 && byte < 0x7f ? Character(UnicodeScalar(byte)) : "?")
        }
        return out
    }
}

extension UInt16 {
    init(bytes: (UInt8, UInt8)) {
        self = UInt16(bytes.0) << 8 | UInt16(bytes.1)
    }
}

extension UInt32 {
    init(bytes: (UInt8, UInt8, UInt8, UInt8)) {
        self = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
    }
}

extension Int {
    init(fromFPE2 bytes: (UInt8, UInt8)) {
        self = (Int(bytes.0) << 6) + (Int(bytes.1) >> 2)
    }
}

extension Float {
    init?(_ bytes: [UInt8]) {
        if bytes.count < 4 { return nil }
        self = bytes.withUnsafeBytes {
            return $0.load(fromByteOffset: 0, as: Self.self)
        }
    }

    var bytes: [UInt8] {
        withUnsafeBytes(of: self, Array.init)
    }
}


public class SMC {
    public static let shared = SMC()
    var conn: io_connect_t = 0
    var _fanModeKeyIsLower: Bool?

    public init() {
        var result: kern_return_t
        var iterator: io_iterator_t = 0
        let device: io_object_t

        let matchingDictionary: CFMutableDictionary = IOServiceMatching("AppleSMC")
        result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        if result != kIOReturnSuccess {
            print("Error IOServiceGetMatchingServices(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }

        device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        if device == 0 {
            print("Error: No AppleSMC device found.")
            return
        }

        result = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        if result != kIOReturnSuccess {
            print("Error IOServiceOpen(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
    }

    deinit {
        let result = self.close()
        if result != kIOReturnSuccess && conn != 0 {
            print("error close smc connection: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
        }
    }

    public func close() -> kern_return_t {
        if conn != 0 {
            let res = IOServiceClose(conn)
            conn = 0
            return res
        }
        return kIOReturnSuccess
    }

    // MARK: - Low-level transport

    /// One-line error string for the log, naming the key and the operation that
    /// failed on it. The SMC reports per-key results, so a bare kern_return_t is not
    /// enough to tell a dead sensor from a read-only key.
    func smcError(_ operation: String, key: String, result: kern_return_t) -> String {
        let errorDesc = String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"
        return "[\(key)] \(operation) failed: \(errorDesc) (0x\(String(result, radix: 16)))"
    }

    func read(_ value: UnsafeMutablePointer<SMCVal_t>) -> kern_return_t {
        var result: kern_return_t = 0
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()

        guard let key = FourCharCode(ascii: value.pointee.key) else { return kIOReturnBadArgument }
        input.key = key
        input.data8 = SMCKeys.readKeyInfo.rawValue

        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }
        // The SMC's own error byte, not just the Mach return: an unknown key answers
        // with `result != 0` and *zeroed* bytes while the IOKit call itself succeeds.
        // That is how a dead sensor reaches the control loop as "0 °C" and commands
        // the fans to 0 %.
        guard output.result == 0 else { return kIOReturnError }

        // `bytes` is a fixed 32-byte tuple. `dataSize` is firmware-controlled, so it
        // must be clamped before the copy: an unchecked memcpy of it walks off the
        // stack frame.
        let reported = UInt32(output.keyInfo.dataSize)
        value.pointee.dataSize = min(reported, UInt32(value.pointee.bytes.count))
        value.pointee.dataType = output.keyInfo.dataType.toString()
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = SMCKeys.readBytes.rawValue

        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }
        guard output.result == 0 else { return kIOReturnError }

        memcpy(&value.pointee.bytes, &output.bytes, Int(value.pointee.dataSize))
        return kIOReturnSuccess
    }

    func write(_ value: SMCVal_t) -> kern_return_t {
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()

        guard let key = FourCharCode(ascii: value.key) else { return kIOReturnBadArgument }
        input.key = key
        input.data8 = SMCKeys.writeBytes.rawValue
        input.keyInfo.dataSize = IOByteCount32(value.dataSize)
        input.bytes = (value.bytes[0], value.bytes[1], value.bytes[2], value.bytes[3], value.bytes[4], value.bytes[5],
                       value.bytes[6], value.bytes[7], value.bytes[8], value.bytes[9], value.bytes[10], value.bytes[11],
                       value.bytes[12], value.bytes[13], value.bytes[14], value.bytes[15], value.bytes[16], value.bytes[17],
                       value.bytes[18], value.bytes[19], value.bytes[20], value.bytes[21], value.bytes[22], value.bytes[23],
                       value.bytes[24], value.bytes[25], value.bytes[26], value.bytes[27], value.bytes[28], value.bytes[29],
                       value.bytes[30], value.bytes[31])

        let result = self.call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }

        if output.result != 0x00 {
            return kIOReturnError
        }

        return kIOReturnSuccess
    }

    func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        if conn == 0 { return kIOReturnNotOpen }
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }
}
