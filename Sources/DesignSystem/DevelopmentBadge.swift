import AppKit
import SwiftUI

/// Small "DEV" capsule marking a local development build, so it's never
/// mistaken for the installed release. Callers show it only when the build
/// isn't a release build (`SoftwareUpdate.isReleaseBuild`), so people who
/// install a release never see it.
public struct DevelopmentBadge: View {
    public init() {}

    public var body: some View {
        Text("DEV")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.orange)
            .padding(.horizontal, PK.Spacing.xs + PK.Spacing.xxs)
            .padding(.vertical, PK.Spacing.xxs)
            .background(.orange.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(.orange.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .help("Development build: not the released app")
            .accessibilityLabel("Development build")
    }
}

public extension NSWindow {
    /// Adds the `DevelopmentBadge` to the trailing end of the title bar.
    func addDevelopmentBadge() {
        let hosting = NSHostingView(rootView: DevelopmentBadge().padding(.horizontal, PK.Spacing.s))
        hosting.frame.size = hosting.fittingSize
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = hosting
        accessory.layoutAttribute = .trailing
        addTitlebarAccessoryViewController(accessory)
    }
}
