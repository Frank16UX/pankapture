import Carbon.HIToolbox

/// Registers system-wide hot keys via Carbon's `RegisterEventHotKey`.
///
/// Carbon hot keys are still the supported way to get global shortcuts that
/// fire without Accessibility or Input Monitoring permission, and they swallow
/// the key event so the frontmost app never sees it.
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    public struct Token: Hashable, Sendable {
        fileprivate let id: UInt32
    }

    public enum RegistrationError: Error, Sendable {
        /// Another app (or the system) already owns this combination.
        case alreadyTaken(KeyCombo)
        case failed(KeyCombo, OSStatus)
    }

    private static let signature: OSType = 0x504B_4350 // "PKCP"

    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {}

    @discardableResult
    public func register(
        _ combo: KeyCombo,
        handler: @escaping @MainActor () -> Void
    ) -> Result<Token, RegistrationError> {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers.carbonFlags,
            EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            Log.hotkeys.error("Failed to register \(combo.displayString, privacy: .public): \(status)")
            if status == eventHotKeyExistsErr { return .failure(.alreadyTaken(combo)) }
            return .failure(.failed(combo, status))
        }

        refs[id] = ref
        handlers[id] = handler
        Log.hotkeys.debug("Registered \(combo.displayString, privacy: .public)")
        return .success(Token(id: id))
    }

    public func unregister(_ token: Token) {
        if let ref = refs.removeValue(forKey: token.id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: token.id)
    }

    public func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    /// Temporarily claims Esc system-wide (countdown, scrolling capture), which
    /// works without Accessibility permission. Unregister the token when done.
    public func registerEscape(_ handler: @escaping @MainActor () -> Void) -> Token? {
        let combo = KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: [])
        if case let .success(token) = register(combo, handler: handler) { return token }
        return nil
    }

    private func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // C callback: cannot capture context, so it routes through `shared`.
        // Carbon delivers hot key events on the main thread.
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
