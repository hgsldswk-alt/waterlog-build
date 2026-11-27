import SwiftUI

enum Palette {
    static let paper = rgb(247, 249, 253)
    static let ink = rgb(21, 36, 58)
    static let muted = rgb(82, 98, 120)
    static let line = rgb(220, 229, 239)
    static let blue = rgb(18, 82, 186)
    static let darkBlue = rgb(14, 66, 151)
    static let tint = rgb(232, 240, 255)
    static let progressTrack = rgb(203, 218, 250)

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }
}

struct WaterButton: ButtonStyle {
    enum Kind: Equatable { case text, outline, primary }
    var kind: Kind = .text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(kind == .primary ? .white : Palette.darkBlue)
            .background(kind == .primary ? Palette.blue : (kind == .outline ? .white : .clear),
                        in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                if kind == .outline {
                    RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.line)
                }
            }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.68 : 1)
    }
}

struct Panel: ViewModifier {
    var radius: CGFloat = 17

    func body(content: Content) -> some View {
        content
            .background(.white, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Palette.line).allowsHitTesting(false) }
    }
}

struct ContextDate {
    static func label(_ date: Date, zone: TimeZone, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter.string(from: date)
    }

    static func day(_ key: String, zone: TimeZone) -> String {
        guard let date = Days.date(key, in: zone) else { return key }
        return label(date, zone: zone, format: "yMMMdEEE")
    }
}

struct FieldError: View {
    var message: String?

    var body: some View {
        if let message {
            Text(message)
                .foregroundStyle(.red)
                .font(.footnote)
                .accessibilityIdentifier("form.error")
        }
    }
}

struct TestTextSize: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.dynamicTypeSize(.accessibility3) }
        else { content }
    }
}
