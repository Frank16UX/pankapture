import SwiftUI

/// Design tokens. Colors are intentionally absent: chrome uses semantic system
/// colors (`.primary`, `.secondary`, `Color.accentColor`, materials) so light,
/// dark, increased-contrast, and the user's accent color all work for free.
/// See docs/DESIGN.md.
public enum PK {
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius {
        /// Tool buttons, swatches.
        public static let control: CGFloat = 6
        /// Thumbnails, small cards.
        public static let thumbnail: CGFloat = 8
        /// Floating toolbars and HUDs.
        public static let toolbar: CGFloat = 12
        /// Panels and windows-within-windows.
        public static let panel: CGFloat = 16
    }

    public enum Metrics {
        /// Hit target for a toolbar icon button (≥ 28pt per HIG for pointer UIs).
        public static let toolButton: CGFloat = 28
        public static let toolIcon: CGFloat = 15
        /// Gap between a capture selection and its floating toolbars.
        public static let toolbarOffset: CGFloat = 8
        public static let swatch: CGFloat = 18
        public static let hairline: CGFloat = 0.5
    }

    public enum Motion {
        /// Hover/press feedback.
        public static let quick = Animation.easeOut(duration: 0.12)
        /// Toolbars and thumbnails appearing.
        public static let standard = Animation.spring(duration: 0.25, bounce: 0.1)
        /// Larger transitions (editor open, thumbnail fly-in).
        public static let emphasized = Animation.spring(duration: 0.35, bounce: 0.15)
    }

    /// Overlay chrome that must stay legible over *any* screen content,
    /// independent of the app's light/dark setting.
    public enum Overlay {
        /// Dim applied outside the selection.
        public static let dimOpacity: Double = 0.45
        public static let selectionStroke = Color.white
        public static let handleSize: CGFloat = 7
    }
}
