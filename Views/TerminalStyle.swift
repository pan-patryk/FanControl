import SwiftUI

// MARK: - Design system
//
// One small, strict system every view builds on. The look is stock macOS:
// system colors and fonts, real controls, real progress meters, consistent
// spacing. The only accent color in the app is green, reserved for "fan /
// live" values so the eye finds them immediately. Everything else is neutral.

enum DS {
    // MARK: Surfaces (dark macOS)
    static let window   = Color(nsColor: .windowBackgroundColor)
    static let cardFill = Color.primary.opacity(0.045)
    static let cardLine = Color.primary.opacity(0.09)
    static let inset    = Color.primary.opacity(0.05)
    static let track    = Color.primary.opacity(0.12)   // meter background

    // MARK: Ink
    static let text      = Color.primary
    static let secondary = Color.secondary
    static let tertiary  = Color(nsColor: .tertiaryLabelColor)

    // MARK: Semantics
    static let fan      = Color.green      // live fan values, gauges
    static let warn     = Color.orange
    static let error    = Color.red
    static let accent   = Color.accentColor

    // MARK: Type
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Spacing
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16

    static let radius: CGFloat = 10
}

// MARK: - Card

/// The standard card: subtle raised surface, hairline edge, 10pt corners.
struct Card<Content: View>: View {
    var title: String?
    var icon: String?
    var tint: Color = DS.tertiary
    var content: () -> Content

    init(_ title: String? = nil, icon: String? = nil, tint: Color = DS.tertiary,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            if let title {
                HStack(spacing: DS.s2) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(tint)
                    }
                    Text(title)
                        .font(DS.ui(13, .semibold))
                        .foregroundColor(DS.text)
                }
            }
            content()
        }
        .padding(DS.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
                .stroke(DS.cardLine, lineWidth: 1)
        )
    }
}

// MARK: - Meter (real rounded progress bar — the app's gauge)

struct Meter: View {
    var value: Double            // 0...1
    var height: CGFloat = 6
    var tint: Color = DS.fan

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Status pill (dot + label, for header rows)

struct StatusPill: View {
    var label: String
    var tint: Color = DS.tertiary

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(DS.ui(11, .medium))
                .foregroundColor(DS.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(DS.inset)
        .clipShape(Capsule())
    }
}

// MARK: - Small labeled row (label left, control center, value right)

struct LabeledRow<Control: View>: View {
    var label: String
    var value: String
    var tint: Color = DS.text
    var control: () -> Control

    var body: some View {
        HStack(spacing: DS.s3) {
            Text(label)
                .font(DS.ui(11))
                .foregroundColor(DS.secondary)
                .frame(minWidth: 84, alignment: .leading)
            control()
            Text(value)
                .font(DS.mono(11))
                .foregroundColor(tint)
                .frame(minWidth: 46, alignment: .trailing)
        }
    }
}

// MARK: - Text gauges (compact readouts in the menu panel)

enum Gauge {
    static func temp(_ value: Double?) -> String {
        value.map { String(format: "%.0f°C", $0) } ?? "—"
    }
}

// MARK: - Convenience aliases kept for call-site stability

extension Button {
    func dsSmall() -> some View {
        self.buttonStyle(.bordered).controlSize(.small).tint(DS.accent)
    }
    func dsProminent() -> some View {
        self.buttonStyle(.borderedProminent).controlSize(.regular).tint(DS.accent)
    }
}
