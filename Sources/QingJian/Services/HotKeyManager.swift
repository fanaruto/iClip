import Foundation
import Carbon

/// 基于 Carbon 的全局快捷键管理（默认 ⌥V）
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    private init() {}

    func registerToggleHotKey(action: @escaping () -> Void) {
        unregister()
        self.onTrigger = action

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData = userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onTrigger?()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandlerRef
        )

        guard status == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x514A434C), id: 1)
        // V 键码为 9，组合键为 Option
        let modifiers = UInt32(optionKey)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}
