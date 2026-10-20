import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: one virtual key code plus modifiers.
/// Stored as JSON in UserDefaults, registered through `HotKeyCenter`.
public struct KeyCombo: Hashable, Codable, Sendable {
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        public init(_ flags: NSEvent.ModifierFlags) {
            var result: Modifiers = []
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.option) { result.insert(.option) }
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.command) { result.insert(.command) }
            self = result
        }

        /// Flags in the format `RegisterEventHotKey` expects.
        public var carbonFlags: UInt32 {
            var flags = 0
            if contains(.control) { flags |= controlKey }
            if contains(.option) { flags |= optionKey }
            if contains(.shift) { flags |= shiftKey }
            if contains(.command) { flags |= cmdKey }
            return UInt32(flags)
        }

        /// Symbols in the canonical macOS menu order: ⌃⌥⇧⌘.
        public var symbols: String {
            var s = ""
            if contains(.control) { s += "⌃" }
            if contains(.option) { s += "⌥" }
            if contains(.shift) { s += "⇧" }
            if contains(.command) { s += "⌘" }
            return s
        }
    }

    /// Human-readable form, e.g. "⇧⌘X".
    public var displayString: String {
        modifiers.symbols + Self.keyName(for: keyCode)
    }

    /// F1–F12 may be used without modifiers.
    public static func isFunctionKey(_ keyCode: Int) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12].contains(keyCode)
    }

    public static func keyName(for keyCode: UInt32) -> String {
        keyNames[Int(keyCode)] ?? "#\(keyCode)"
    }

    private static let keyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_Tab: "⇥",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()
}
