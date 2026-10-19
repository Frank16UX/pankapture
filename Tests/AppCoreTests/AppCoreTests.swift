import Carbon.HIToolbox
import Foundation
import Testing
@testable import AppCore

@Suite("CaptureFileNamer")
struct CaptureFileNamerTests {
    private let namer = CaptureFileNamer(timeZone: TimeZone(identifier: "UTC")!)
    private let date = Date(timeIntervalSince1970: 1_792_419_225) // 2026-10-19 14:13:45 UTC

    @Test func baseNameUsesSortableTimestamp() {
        #expect(namer.baseName(for: date) == "Pankapture 2026-10-19 at 14.13.45")
    }

    @Test func uniqueURLAvoidsCollisions() {
        let directory = URL(fileURLWithPath: "/tmp/captures", isDirectory: true)
        let taken: Set<String> = [
            "Pankapture 2026-10-19 at 14.13.45.png",
            "Pankapture 2026-10-19 at 14.13.45 (2).png",
        ]
        let url = namer.uniqueURL(in: directory, for: date, fileExtension: "png") {
            taken.contains($0.lastPathComponent)
        }
        #expect(url.lastPathComponent == "Pankapture 2026-10-19 at 14.13.45 (3).png")
    }
}

@Suite("KeyCombo")
struct KeyComboTests {
    @Test func displayStringUsesCanonicalModifierOrder() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: [.command, .shift, .option, .control])
        #expect(combo.displayString == "⌃⌥⇧⌘X")
    }

    @Test func carbonFlagsMatchCarbonConstants() {
        let modifiers: KeyCombo.Modifiers = [.command, .shift]
        #expect(modifiers.carbonFlags == UInt32(cmdKey | shiftKey))
    }

    @Test func roundTripsThroughJSON() throws {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: [.command, .shift])
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(combo))
        #expect(decoded == combo)
    }
}

@Suite("ShortcutStore")
struct ShortcutStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "pankapture.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func captureAreaDefaultsToCommandShiftX() {
        let store = ShortcutStore(defaults: makeDefaults())
        #expect(store.combo(for: .captureArea)?.displayString == "⇧⌘X")
    }

    @Test func explicitlyClearedShortcutStaysUnassigned() {
        let store = ShortcutStore(defaults: makeDefaults())
        store.setCombo(nil, for: .captureArea)
        #expect(store.combo(for: .captureArea) == nil)
    }

    @Test func customShortcutOverridesDefaultAndResets() {
        let store = ShortcutStore(defaults: makeDefaults())
        let custom = KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: [.command, .option])
        store.setCombo(custom, for: .captureArea)
        #expect(store.combo(for: .captureArea) == custom)

        store.resetToDefaults()
        #expect(store.combo(for: .captureArea) == ShortcutAction.captureArea.defaultCombo)
    }
}
