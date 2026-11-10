import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey (no Accessibility permission needed).
@MainActor
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var reference: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D50_5457) /* 'MPTW' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        let id = id
        Task { @MainActor in HotKey.handlers[id] = nil }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
