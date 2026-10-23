import SwiftUI

/// Visual language taken from Duet's macOS app: white sidebar, light grey
/// canvas, white cards and a bright blue accent.
enum Theme {
    static let accent = Color(red: 0.18, green: 0.55, blue: 0.97)
    static let accentPressed = Color(red: 0.13, green: 0.45, blue: 0.85)
    static let sidebar = Color.white
    static let sidebarSelected = Color(red: 0.91, green: 0.925, blue: 0.95)
    static let canvas = Color(red: 0.957, green: 0.961, blue: 0.969)
    static let card = Color.white
    static let promo = Color(red: 0.925, green: 0.933, blue: 0.945)
    static let text = Color(red: 0.12, green: 0.14, blue: 0.19)
    static let secondaryText = Color(red: 0.40, green: 0.43, blue: 0.48)
    static let faintText = Color(red: 0.60, green: 0.62, blue: 0.66)
    static let border = Color(red: 0.84, green: 0.86, blue: 0.89)
    static let success = Color(red: 0.16, green: 0.68, blue: 0.38)
    static let warning = Color(red: 0.93, green: 0.55, blue: 0.10)
    static let danger = Color(red: 0.86, green: 0.24, blue: 0.24)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Avenir Next", size: size).weight(weight)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(large ? 16 : 14, .medium))
            .foregroundColor(.white)
            .padding(.horizontal, large ? 18 : 14)
            .padding(.vertical, large ? 10 : 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Theme.accentPressed : Theme.accent)
            )
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(13, .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(configuration.isPressed ? Theme.sidebarSelected : Color.white)
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Duet's square blue checkbox.
struct CheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(configuration.isOn ? Theme.accent : Color.white)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(configuration.isOn ? Theme.accent : Theme.border, lineWidth: 1))
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .opacity(configuration.isOn ? 1 : 0)
                )
                .frame(width: 17, height: 17)
        }
        .buttonStyle(.plain)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

struct Badge: View {
    let text: String
    var color: Color = Theme.secondaryText

    var body: some View {
        Text(text)
            .font(Theme.font(10, .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Segmented control styled like the rest of the UI.
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var disabled: (Value) -> Bool = { _ in false }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let value = options[index].0
                let label = options[index].1
                Button {
                    selection = value
                } label: {
                    Text(label)
                        .font(Theme.font(12, selection == value ? .semibold : .regular))
                        .foregroundColor(selection == value ? .white : Theme.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selection == value ? Theme.accent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled(value))
                .opacity(disabled(value) ? 0.4 : 1)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}
