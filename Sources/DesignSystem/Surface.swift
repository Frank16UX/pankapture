import SwiftUI

/// Floating surface used for toolbars, HUDs, and thumbnails.
///
/// On macOS 26+ this is the system glass material; on macOS 15 it falls back
/// to a vibrant material with a hairline border. Both adapt to light/dark and
/// honour Reduce Transparency automatically.
struct PKSurface: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator, lineWidth: PK.Metrics.hairline))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
    }
}

/// Surface for sheets docked over busy content (video, screenshots): a
/// heavily frosted material so text stays legible over anything behind it.
/// The clear glass of `PKSurface` lets too much of a moving picture through.
struct PKSheetSurface: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.thickMaterial, in: shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: PK.Metrics.hairline))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
    }
}

public extension View {
    /// Frosted sheet surface for panels over video or images.
    func pkSheetSurface(cornerRadius: CGFloat = PK.Radius.panel) -> some View {
        modifier(PKSheetSurface(cornerRadius: cornerRadius))
    }

    func pkSurface(cornerRadius: CGFloat = PK.Radius.toolbar) -> some View {
        modifier(PKSurface(cornerRadius: cornerRadius))
    }
}

/// Icon button used in every Pankapture toolbar: SF Symbol, square hit target,
/// accent-tinted when selected, subtle hover feedback.
public struct PKToolButtonStyle: ButtonStyle {
    public var isSelected: Bool

    public init(isSelected: Bool = false) {
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        ToolButtonBody(configuration: configuration, isSelected: isSelected)
    }

    private struct ToolButtonBody: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: PK.Metrics.toolIcon, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: PK.Metrics.toolButton, height: PK.Metrics.toolButton)
                .background(
                    RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                        .fill(backgroundStyle)
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.35)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(PK.Motion.quick, value: configuration.isPressed)
                .animation(PK.Motion.quick, value: isHovering)
                .onHover { isHovering = $0 }
        }

        private var backgroundStyle: AnyShapeStyle {
            if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.18)) }
            if isEnabled, isHovering || configuration.isPressed { return AnyShapeStyle(.quaternary) }
            return AnyShapeStyle(.clear)
        }
    }
}
