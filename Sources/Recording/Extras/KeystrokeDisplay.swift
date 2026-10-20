import AppCore
import AppKit
import DesignSystem
import Observation
import SwiftUI

/// Turns key events into what the keystroke pill shows (REC-12). Pure.
public enum KeystrokeFormatter {
    public enum Entry: Equatable, Sendable {
        /// A shortcut or special key, shown on its own: "⌘C", "⇧⌘4", "↩".
        case combo(String)
        /// A printable character, appended to the running typed text.
        case typed(String)
    }

    /// - Parameters:
    ///   - characters: `NSEvent.characters` (with Shift applied, other modifiers not).
    ///   - showAllKeys: `false` shows only combinations with ⌘, ⌃, or ⌥.
    public static func entry(
        keyCode: UInt16,
        modifiers: KeyCombo.Modifiers,
        characters: String?,
        showAllKeys: Bool
    ) -> Entry? {
        let isShortcut = !modifiers.isDisjoint(with: [.command, .control, .option])
        if isShortcut { return .combo(modifiers.symbols + keyName(keyCode: keyCode, characters: characters)) }
        guard showAllKeys else { return nil }

        if let characters, characters.count == 1, let scalar = characters.unicodeScalars.first, isPrintable(scalar) {
            return .typed(characters)
        }
        return .combo(modifiers.symbols + keyName(keyCode: keyCode, characters: characters))
    }

    static func keyName(keyCode: UInt16, characters: String?) -> String {
        let name = KeyCombo.keyName(for: UInt32(keyCode))
        guard name.hasPrefix("#") else { return name }
        // Keys outside the shared table (punctuation, keypad, …): use the character.
        if let characters, let scalar = characters.unicodeScalars.first, isPrintable(scalar) {
            return characters.uppercased()
        }
        return name
    }

    /// Not a control character and not one of AppKit's function-key code points.
    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x20 || value == 0x7F { return false }
        if (0xF700...0xF8FF).contains(value) { return false }
        return true
    }
}

/// Shows pressed shortcuts/keys as a pill at the bottom-center of the recorded
/// frame (REC-12). The panel is a Pankapture window that **is** recorded: pass
/// `windowID` in `RecordingConfiguration.includedOverlayWindowIDs`. Needs
/// Accessibility permission for the global key monitor.
@MainActor
public final class KeystrokeDisplay {
    @Observable
    final class Model {
        var text = ""
        var isVisible = false
    }

    public var showsAllKeys: Bool
    private let model = Model()
    private var panel: OverlayPanel?
    private var monitors: [Any] = []
    private var hideTask: Task<Void, Never>?
    private var lastTypedAt: Date = .distantPast
    private var typedBuffer = ""
    private static let visibleDuration: Duration = .milliseconds(1500)
    private static let maxTypedLength = 24

    public init(showsAllKeys: Bool = false) {
        self.showsAllKeys = showsAllKeys
    }

    public var windowID: CGWindowID? { panel?.windowID }
    public var isActive: Bool { panel != nil }

    /// Starts listening. `frame` is the recorded region in AppKit global
    /// coordinates (a display's frame or an area). Returns `false` (and prompts
    /// for Accessibility) if the permission is missing.
    @discardableResult
    public func start(in frame: CGRect) -> Bool {
        stop()
        guard Permissions.status(.accessibility) == .granted else {
            Task { await Permissions.request(.accessibility) }
            Log.recording.notice("Keystroke display needs Accessibility permission")
            return false
        }

        let height: CGFloat = 96
        let panelFrame = CGRect(
            x: frame.minX,
            y: frame.minY + min(PK.Spacing.xxl * 2, max(frame.height - height, 0) / 2),
            width: frame.width,
            height: height
        )
        let panel = OverlayPanel(contentRect: panelFrame, level: .recordingOverlay, clickThrough: true)
        panel.contentView = NSHostingView(rootView: KeystrokePill(model: model))
        // Kept ordered in while recording (transparent when idle) so
        // ScreenCaptureKit always knows the window.
        panel.orderFrontRegardless()
        self.panel = panel

        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let info = KeyInfo(event)
            MainActor.assumeIsolated { self?.handle(info) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let info = KeyInfo(event)
            MainActor.assumeIsolated { self?.handle(info) }
            return event
        }) { monitors.append(local) }
        return true
    }

    public func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        model.isVisible = false
        model.text = ""
        typedBuffer = ""
    }

    private struct KeyInfo {
        let keyCode: UInt16
        let modifiers: KeyCombo.Modifiers
        let characters: String?
        let isRepeat: Bool

        init(_ event: NSEvent) {
            keyCode = event.keyCode
            modifiers = KeyCombo.Modifiers(event.modifierFlags)
            characters = event.characters
            isRepeat = event.isARepeat
        }
    }

    private func handle(_ key: KeyInfo) {
        guard !key.isRepeat, let entry = KeystrokeFormatter.entry(
            keyCode: key.keyCode, modifiers: key.modifiers, characters: key.characters, showAllKeys: showsAllKeys
        ) else { return }

        let now = Date()
        switch entry {
        case .combo(let text):
            typedBuffer = ""
            model.text = text
        case .typed(let character):
            if now.timeIntervalSince(lastTypedAt) > 1.5 { typedBuffer = "" }
            typedBuffer = String((typedBuffer + character).suffix(Self.maxTypedLength))
            lastTypedAt = now
            model.text = typedBuffer
        }
        model.isVisible = true

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            self?.model.isVisible = false
        }
    }
}

/// The pill itself. It's recorded *content*, so it uses a fixed dark style
/// that reads the same over any screen and in either appearance (like the
/// overlay exception in DESIGN §2), not themed chrome.
private struct KeystrokePill: View {
    let model: KeystrokeDisplay.Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.isVisible, !model.text.isEmpty {
                Text(model.text)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .padding(.horizontal, PK.Spacing.xl)
                    .padding(.vertical, PK.Spacing.m)
                    .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: PK.Radius.panel, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: PK.Radius.panel, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .linear(duration: 0.1) : PK.Motion.standard, value: model.isVisible)
        .accessibilityHidden(true)
    }
}
