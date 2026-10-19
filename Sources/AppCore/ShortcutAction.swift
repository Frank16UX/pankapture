import Carbon.HIToolbox
import Foundation

/// Every action that can be bound to a global shortcut.
/// Only the two most-used actions ship with defaults; the rest are opt-in so
/// we never silently steal shortcuts from other apps.
public enum ShortcutAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case captureArea
    case captureWindow
    case captureFullscreen
    case capturePreviousArea
    case captureText
    case scrollingCapture
    case recordScreen
    case openHistory

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureFullscreen: "Capture Fullscreen"
        case .capturePreviousArea: "Capture Previous Area"
        case .captureText: "Capture Text (OCR)"
        case .scrollingCapture: "Scrolling Capture"
        case .recordScreen: "Record Screen"
        case .openHistory: "Open Capture History"
        }
    }

    public var defaultCombo: KeyCombo? {
        switch self {
        case .captureArea:
            KeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: [.command, .shift])
        case .recordScreen:
            KeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: [.command, .shift, .option])
        default:
            nil
        }
    }
}

/// Persists user-customised shortcut bindings in UserDefaults as JSON.
/// A missing entry means "use the default"; an explicit `nil` means "unassigned".
public struct ShortcutStore {
    public static let defaultsKey = "shortcuts.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func combo(for action: ShortcutAction) -> KeyCombo? {
        let stored = load()
        if let entry = stored[action.rawValue] { return entry }
        return action.defaultCombo
    }

    public func setCombo(_ combo: KeyCombo?, for action: ShortcutAction) {
        var stored = load()
        stored[action.rawValue] = .some(combo)
        save(stored)
    }

    public func resetToDefaults() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func load() -> [String: KeyCombo?] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: KeyCombo?].self, from: data)) ?? [:]
    }

    private func save(_ value: [String: KeyCombo?]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
