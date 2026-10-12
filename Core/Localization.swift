import Foundation

/// Uses the application's standard `Localizable.strings` table. Keeping this
/// wrapper for dynamically constructed labels prevents them from bypassing the
/// same macOS localization mechanism that SwiftUI uses for string literals.
enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    /// Formats `key` with the given arguments WITHOUT touching the C
    /// `String(format:)` variadic path.
    ///
    /// The C formatter matches specifiers in the template against raw
    /// `va_list` slots. A mismatch — an `Int` served to a `%@`, a stray `%`
    /// in a string, an off-by-one count — makes it dereference garbage
    /// object pointers: an instant EXC_BAD_ACCESS. This function runs from
    /// menu-bar renders, so a bad template takes the whole app down with it.
    ///
    /// Substitution here is explicit and total: each real specifier is
    /// replaced with the next argument's description. Mismatches degrade to
    /// readable text instead of a crash.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let template = text(key)
        var args = arguments
        var result = ""
        result.reserveCapacity(template.count + args.count * 4)

        // One left-to-right pass over the *template*; substituted values are appended
        // and never re-scanned. Mutating the template in place and searching it again
        // from the start would let any value containing a percent — an error string
        // like "0% of range", "50 %", a fan name — consume the next argument or be
        // re-interpreted as a specifier.
        var index = template.startIndex
        while index < template.endIndex {
            guard let range = nextSpecifier(in: template, from: index) else {
                appendTemplate(template[index...], to: &result)
                break
            }
            appendTemplate(template[index..<range.lowerBound], to: &result)
            if args.isEmpty {
                result += template[range]        // more specifiers than arguments
            } else {
                result += describe(args.removeFirst())
            }
            index = range.upperBound
        }
        return result
    }

    /// Appends a slice of the template, collapsing `%%` escapes as it goes.
    private static func appendTemplate(_ slice: Substring, to result: inout String) {
        if !slice.contains("%%") { result += slice; return }
        result += slice.replacingOccurrences(of: "%%", with: "%")
    }

    /// Finds the next real format specifier in `s` (a `%` not part of a `%%`
    /// escape, followed by a conversion character), or nil.
    private static func nextSpecifier(in s: String, from start: String.Index) -> Range<String.Index>? {
        let conversion = Set("dioxXeEFGgAcbsUShn%".unicodeScalars)
        let flags = Set("-+#0'.,".unicodeScalars)

        var i = start
        while i < s.endIndex {
            guard s[i] == "%" else { i = s.index(after: i); continue }
            var j = s.index(after: i)

            // `%%` is a literal percent, not a specifier.
            if j < s.endIndex, s[j].unicodeScalars.first == "%" {
                i = s.index(after: j)
                continue
            }

            // Skip flags, width, precision.
            while j < s.endIndex,
                  s[j].isNumber || flags.contains(s[j].unicodeScalars.first!) {
                j = s.index(after: j)
            }

            if j < s.endIndex, conversion.contains(s[j].unicodeScalars.first!) {
                return i..<s.index(after: j)
            }

            // No conversion character: treat this `%` as a literal.
            i = s.index(after: j)
        }
        return nil
    }

    private static func describe(_ arg: CVarArg) -> String {
        switch arg {
        case let value as Int: return "\(value)"
        case let value as Double:
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", value)
                : String(format: "%.1f", value)
        case let value as String: return value
        default: return String(describing: arg)
        }
    }
}
