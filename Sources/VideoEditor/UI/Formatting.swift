import Foundation
import SwiftUI

enum Format {
    /// `1:05.3`, or `1:02:05.3` past an hour.
    static func time(_ seconds: Double, precise: Bool = true) -> String {
        let seconds = max(0, seconds.isFinite ? seconds : 0)
        let tenths = Int((seconds * 10).rounded(.down))
        let totalSeconds = tenths / 10
        let (hours, minutes, secs) = (totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
        let base = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
        return precise ? "\(base).\(tenths % 10)" : base
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func rate(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

extension RGBAColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            alpha: Double(resolved.alphaComponent)
        )
    }
}

extension GradientPreset {
    var linearGradient: LinearGradient {
        LinearGradient(
            colors: [colors.start.swiftUIColor, colors.end.swiftUIColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension CustomGradient {
    /// The same direction as the export (`endpoints(in:)`), in unit points.
    var linearGradient: LinearGradient {
        let radians = angle * .pi / 180
        let dx = cos(radians) / 2, dy = sin(radians) / 2
        return LinearGradient(
            colors: [start.swiftUIColor, end.swiftUIColor],
            startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
            endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
        )
    }
}
