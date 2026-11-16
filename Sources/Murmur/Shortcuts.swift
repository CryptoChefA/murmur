import AppKit
import Carbon.HIToolbox

/// Two system-wide shortcuts: paste the last dictation again, and undo it. Registered with the
/// system's own hot-key service, so nothing of Murmur's runs while other keys are typed.
final class Shortcuts {
    static let shared = Shortcuts()
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    var onPasteLast: (() -> Void)?
    var onUndo: (() -> Void)?

    func apply(enabled: Bool) {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        guard enabled else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async {
                    if id.id == 1 { Shortcuts.shared.onPasteLast?() } else if id.id == 2 { Shortcuts.shared.onUndo?() }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        // Control-Option-V and Control-Option-Z.
        for (id, key) in [(UInt32(1), kVK_ANSI_V), (UInt32(2), kVK_ANSI_Z)] {
            var ref: EventHotKeyRef?
            let hotKey = EventHotKeyID(signature: OSType(0x4D52_4D52), id: id)
            if RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), hotKey, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref { refs.append(ref) }
        }
    }
}
