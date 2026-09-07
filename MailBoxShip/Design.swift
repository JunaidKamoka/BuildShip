import SwiftUI

/// Shared visual language.
///
/// Kept in one place so spacing, corner radius and the accent gradient stay
/// consistent — the thing that makes an interface read as considered rather
/// than assembled is that these values agree with each other everywhere.
///
/// The scales below are deliberately short. Three surface levels, six spacing
/// steps and six type faces are enough to build every screen in this app, and a
/// short scale is what forces two unrelated rows to line up instead of landing
/// a pixel apart because each was tuned by eye.
enum Design {

    // MARK: - Metrics

    /// Cards and other large surfaces.
    static let corner: CGFloat = 10
    /// Controls that sit *inside* a card: fields, chips, small buttons. Smaller
    /// than the card that contains them, which is what keeps a field from
    /// looking like it is bulging out of its own panel.
    static let controlCorner: CGFloat = 7
    static let cardPadding: CGFloat = 16
    /// Every label column in the app, so fields down a whole screen share one
    /// left edge no matter which card they are in.
    static let labelWidth: CGFloat = 132

    /// Spacing scale. Anything not on it is a one-off that has to justify itself.
    enum Gap {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let section: CGFloat = 20
    }

    // MARK: - Type

    /// The type scale. Named by role rather than by size, so a heading stays a
    /// heading when the size is tuned.
    enum Face {
        static let title = Font.system(size: 15, weight: .semibold)
        static let heading = Font.system(size: 12.5, weight: .semibold)
        static let body = Font.system(size: 12)
        static let label = Font.system(size: 11.5)
        static let caption = Font.system(size: 10.5)
        static let chip = Font.system(size: 10, weight: .semibold)
        static let mono = Font.system(size: 11.5, design: .monospaced)
        /// Version numbers and other figures read as data, not prose.
        static let figure = Font.system(size: 15, weight: .semibold, design: .rounded)
    }

    // MARK: - Colour

    static let accent = LinearGradient(
        colors: [Color(red: 0.20, green: 0.52, blue: 0.98),
                 Color(red: 0.36, green: 0.34, blue: 0.94)],
        startPoint: .topLeading, endPoint: .bottomTrailing,
    )

    /// The gradient's midpoint as a flat colour.
    ///
    /// A gradient is right for a filled 34pt tile and wrong everywhere else: at
    /// 12% opacity behind an icon it turns to mud, and it cannot tint a 1px
    /// border at all. Anything that needs *the accent* rather than *the badge*
    /// uses this.
    static let accentSolid = Color(red: 0.28, green: 0.43, blue: 0.96)

    static let success = Color(red: 0.16, green: 0.68, blue: 0.42)
    static let warning = Color(red: 0.87, green: 0.60, blue: 0.15)
    static let failure = Color(red: 0.85, green: 0.27, blue: 0.24)

    /// Borders and dividers. `separatorColor` rather than a black at some
    /// opacity, because the same opacity that reads as a hairline on a white
    /// card disappears entirely on a dark one.
    static let hairline = Color(nsColor: .separatorColor)
    /// A raised surface: cards, and the fields inside them are cut back out of it.
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// The recess a control sits in — a field, a chip, an unfilled button.
    static let well = Color.primary.opacity(0.045)
}

// MARK: - Surfaces

/// The card treatment: fill, hairline, and just enough shadow to lift it.
///
/// The shadow is nearly invisible on purpose. Its job is not to look like a
/// shadow but to stop the card's edge from being carried entirely by a 1px
/// border, which is what makes a stack of panels read as a wireframe.
struct CardSurface: ViewModifier {
    var padding: CGFloat = Design.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
                    .fill(Design.surface),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
                    .strokeBorder(Design.hairline, lineWidth: 1),
            )
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

/// The recess a control sits in, with a focus ring when it is being typed into.
struct FieldSurface: ViewModifier {
    var focused = false
    var corner: CGFloat = Design.controlCorner

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Design.well),
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        focused ? Design.accentSolid : Design.hairline,
                        lineWidth: focused ? 1.5 : 1,
                    ),
            )
    }
}

extension View {
    func cardSurface(padding: CGFloat = Design.cardPadding) -> some View {
        modifier(CardSurface(padding: padding))
    }

    func fieldSurface(focused: Bool = false, corner: CGFloat = Design.controlCorner) -> some View {
        modifier(FieldSurface(focused: focused, corner: corner))
    }
}

// MARK: - Cards

/// The small tinted tile a card wears instead of a bare glyph.
///
/// A loose SF Symbol beside a title reads as a bullet point. Giving it a
/// container of its own is what makes the row look like a section header, and
/// the tint carries the accent to every card without repeating a saturated
/// gradient block five times down one screen.
struct SectionIcon: View {
    let symbol: String
    var tint: Color = Design.accentSolid

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.opacity(0.14))
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint),
            )
    }
}

/// A titled group of controls.
struct Card<Content: View>: View {
    let title: String
    let symbol: String
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(
        _ title: String,
        symbol: String,
        accessory: AnyView? = nil,
        @ViewBuilder content: () -> Content,
    ) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Gap.medium) {
            HStack(spacing: Design.Gap.small) {
                SectionIcon(symbol: symbol)
                Text(title).font(Design.Face.heading)
                Spacer(minLength: Design.Gap.small)
                if let accessory { accessory }
            }
            // Separates the header from the fields without a full divider,
            // which at this size reads as a second card starting.
            Rectangle()
                .fill(Design.hairline)
                .frame(height: 1)
                .padding(.bottom, Design.Gap.tight)

            content
        }
        .cardSurface()
    }
}

/// A labelled row, so every field lines up on the same left edge.
struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Design.Gap.medium) {
            Text(label)
                .font(Design.Face.label)
                .foregroundStyle(.secondary)
                .frame(width: Design.labelWidth, alignment: .leading)
            content
        }
    }
}

// MARK: - Fields

/// The one text field in the app.
///
/// Every field used to be a `.roundedBorder` `TextField` sitting beside a
/// custom-drawn path row and a segmented picker, each with its own height,
/// radius and border — three different ideas of what a control looks like,
/// stacked in one card. This is the single answer: one height, one radius, one
/// well, and a focus ring the system style cannot draw once `.plain` has
/// removed its own.
struct ShipTextField: View {
    let prompt: String
    @Binding var text: String
    /// Identifiers, keys and paths: figures where a mistaken character matters,
    /// and where a monospaced face makes one findable.
    var mono = false

    @FocusState private var focused: Bool

    init(_ prompt: String, text: Binding<String>, mono: Bool = false) {
        self.prompt = prompt
        self._text = text
        self.mono = mono
    }

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? Design.Face.mono : Design.Face.body)
            .focused($focused)
            .padding(.horizontal, Design.Gap.small)
            .padding(.vertical, 5)
            .fieldSurface(focused: focused)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// `ShipTextField` for a secret. Same well, same ring, same height — a password
/// row that sat a pixel off from the username above it was the tell that these
/// were two different controls wearing the same border.
struct ShipSecureField: View {
    let prompt: String
    @Binding var text: String

    @FocusState private var focused: Bool

    init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        self._text = text
    }

    var body: some View {
        SecureField(prompt, text: $text)
            .textFieldStyle(.plain)
            .font(Design.Face.body)
            .focused($focused)
            .padding(.horizontal, Design.Gap.small)
            .padding(.vertical, 5)
            .fieldSurface(focused: focused)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: - Chips

/// Small status chip.
struct Pill: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: Design.Gap.tight) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(Design.Face.chip)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 1))
        .foregroundStyle(color)
    }
}

/// An explanatory paragraph inside a card.
///
/// These are the longest text in the app and they were set as a loose icon
/// beside grey prose, which put them in the same visual register as the field
/// labels above — so they read as another row rather than as an aside, and the
/// eye had to work out which. A tinted well and a rule down the leading edge
/// settle that in one glance: this is commentary, not a control.
struct Note: View {
    let text: String
    var symbol = "info.circle.fill"
    var tint: Color = Design.success

    var body: some View {
        HStack(alignment: .top, spacing: Design.Gap.small) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(Design.Face.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Design.Gap.small)
        .background(
            RoundedRectangle(cornerRadius: Design.controlCorner, style: .continuous)
                .fill(tint.opacity(0.06)),
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(0.45))
                .frame(width: 2)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Buttons

/// The primary action, sized and coloured to be unmistakably the main thing.
struct PrimaryButton: View {
    let title: String
    let symbol: String
    var enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(enabled ? AnyShapeStyle(Design.accent)
                                  : AnyShapeStyle(Design.well)),
            )
            // Only the enabled button lifts. A disabled control that casts a
            // shadow still looks pressable, which is the one thing it is not.
            .shadow(color: enabled ? Design.accentSolid.opacity(hovering ? 0.35 : 0.22) : .clear,
                    radius: hovering ? 7 : 4, y: 2)
            .foregroundStyle(enabled ? .white : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 && enabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A secondary action with an icon, sized to be seen and hit without aiming.
///
/// The borderless buttons elsewhere are right for options that sit beside a
/// field. They are wrong for the things a person reaches for *after* a run —
/// where is it, open the folder — which have to read as buttons from across
/// the room, because at that moment they are the only thing being looked for.
struct ActionButton: View {
    let title: String
    let symbol: String
    var tint: Color = .primary
    /// Carries the tint as its own fill: for the one action in a row that is
    /// the obvious next move.
    var prominent = false
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            // Intrinsic width always. Squeezed into a row beside a long file
            // name these otherwise collapse to "Show i…", which reads as broken
            // rather than as tight — the name is the part that can be trimmed.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Design.controlCorner, style: .continuous)
                    .fill(prominent
                          ? tint.opacity(hovering ? 0.26 : 0.15)
                          : Color.primary.opacity(hovering ? 0.11 : 0.055)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.controlCorner, style: .continuous)
                    .strokeBorder(prominent ? tint.opacity(0.38) : Design.hairline, lineWidth: 1),
            )
            .foregroundStyle(prominent ? tint : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 && enabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// An icon-only button for the sidebar footer.
///
/// `@State` for the hover needs a view of its own — a `some View` returned from
/// a helper method on the parent cannot hold one, which is why the six of these
/// were bare `.borderless` glyphs with no hover state at all.
struct SidebarIconButton: View {
    let symbol: String
    let help: String
    var danger = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill((danger ? Design.failure : Color.primary)
                            .opacity(hovering ? (danger ? 0.14 : 0.09) : 0)),
                )
                .foregroundStyle(
                    hovering ? (danger ? Design.failure : Color.primary) : Color.secondary,
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 && isEnabled }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// A quiet toolbar action: icon and label, no chrome until pointed at.
///
/// The header and the run bar are full of these. As bare `.borderless` buttons
/// they were text floating on a background with no hit area to speak of; the
/// hover fill is what tells you the row is a set of controls rather than a
/// caption.
struct QuietButton: View {
    let title: String
    let symbol: String
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .medium))
                Text(title).font(Design.Face.label)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0)),
            )
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 && enabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
