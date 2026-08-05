import SwiftUI

/// Shared visual language.
///
/// Kept in one place so spacing, corner radius and the accent gradient stay
/// consistent — the thing that makes an interface read as considered rather
/// than assembled is that these values agree with each other everywhere.
enum Design {
    static let corner: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let labelWidth: CGFloat = 132

    static let accent = LinearGradient(
        colors: [Color(red: 0.20, green: 0.52, blue: 0.98),
                 Color(red: 0.36, green: 0.34, blue: 0.94)],
        startPoint: .topLeading, endPoint: .bottomTrailing,
    )

    static let success = Color(red: 0.16, green: 0.68, blue: 0.42)
    static let warning = Color(red: 0.87, green: 0.60, blue: 0.15)
    static let failure = Color(red: 0.85, green: 0.27, blue: 0.24)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Design.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let accessory { accessory }
            }
            content
        }
        .padding(Design.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1),
        )
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
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: Design.labelWidth, alignment: .leading)
            content
        }
    }
}

/// Small status chip.
struct Pill: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }
}

/// The primary action, sized and coloured to be unmistakably the main thing.
struct PrimaryButton: View {
    let title: String
    let symbol: String
    var enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(enabled ? AnyShapeStyle(Design.accent)
                                  : AnyShapeStyle(Color.gray.opacity(0.25))),
            )
            .foregroundStyle(enabled ? .white : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
