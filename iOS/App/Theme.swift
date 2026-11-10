import SwiftUI

/// The app's look: black and white, like the photograph at the top. A studio backdrop that falls from dark grey to
/// black, soft charcoal cards, and white for whatever is selected or switched on.
enum Theme {
    static let backdropTop = Color(white: 0.21)
    static let backdropBottom = Color.black
    static let card = Color(white: 0.085)
    static let cardRaised = Color(white: 0.15)
    static let hairline = Color.white.opacity(0.09)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.36)
    static let cardShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    static var backdrop: some View {
        ZStack {
            Color.black
            LinearGradient(stops: [.init(color: backdropTop, location: 0), .init(color: Color(white: 0.07), location: 0.62),
                                   .init(color: backdropBottom, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 620)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
    }
}

/// "NOISE CONTROL": small, spaced capitals over each group of cards.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(1.8)
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A raised panel on the dark backdrop.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: Theme.cardShape)
            .overlay(Theme.cardShape.strokeBorder(Theme.hairline))
    }
}

/// Cards that are buttons dip slightly under the finger.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A switch in black and white: a white track with a black knob when on, charcoal with a grey knob when off.
struct MonoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                Capsule()
                    .fill(configuration.isOn ? Color.white : Color(white: 0.2))
                    .overlay(Capsule().strokeBorder(.white.opacity(configuration.isOn ? 0 : 0.12)))
                    .frame(width: 50, height: 30)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Color.black : Color(white: 0.62))
                            .padding(3.5)
                    }
                    .animation(.snappy(duration: 0.2), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A thin line between rows inside one card.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}
