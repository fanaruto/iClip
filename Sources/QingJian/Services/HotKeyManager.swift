import Foundation
import Carbon
import AppKit

/// 可持久化的全局快捷键模型（支持任意修饰键 + 主键组合）
struct HotKeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    /// 默认主面板呼出快捷键：Option + V
    static let defaultShortcut = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(optionKey)
    )

    /// 默认免开面板顺序出队快捷键：Control + Option + V
    static let defaultQueueShortcut = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    /// 供界面显示的苹果标准符号串（例如 "⌥ V"、"⌃ ⌥ V"）
    var displayString: String {
        var parts: [String] = []
        if (carbonModifiers & UInt32(controlKey)) != 0 { parts.append("⌃") }
        if (carbonModifiers & UInt32(optionKey)) != 0 { parts.append("⌥") }
        if (carbonModifiers & UInt32(shiftKey)) != 0 { parts.append("⇧") }
        if (carbonModifiers & UInt32(cmdKey)) != 0 { parts.append("⌘") }
        parts.append(Self.keyLabel(for: keyCode))
        return parts.joined(separator: " ")
    }

    /// 紧凑符号串（用于菜单栏提示，例如 "⌥V"）
    var compactDisplayString: String {
        displayString.replacingOccurrences(of: " ", with: "")
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let clean = flags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if clean.contains(.command) { mods |= UInt32(cmdKey) }
        if clean.contains(.option) { mods |= UInt32(optionKey) }
        if clean.contains(.control) { mods |= UInt32(controlKey) }
        if clean.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    static func keyLabel(for keyCode: UInt32) -> String {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↵", kVK_Tab: "⇥",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
        ]
        return map[Int(keyCode)] ?? "Key\(keyCode)"
    }
}

/// 基于 Carbon 的多通道可热更新全局快捷键管理（ID 1: 呼出主面板；ID 2: 免开面板顺序出队）
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var toggleHotKeyRef: EventHotKeyRef?
    private var queueHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var onToggleTrigger: (() -> Void)?
    private var onQueueTrigger: (() -> Void)?

    private var currentShortcut: HotKeyShortcut = .defaultShortcut
    private var currentQueueShortcut: HotKeyShortcut = .defaultQueueShortcut

    private init() {}

    private func ensureEventHandlerInstalled() -> Bool {
        if eventHandlerRef != nil { return true }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard err == noErr else { return noErr }
                let id = hkID.id
                DispatchQueue.main.async {
                    if id == 1 {
                        manager.onToggleTrigger?()
                    } else if id == 2 {
                        manager.onQueueTrigger?()
                    }
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandlerRef
        )
        return status == noErr
    }

    @discardableResult
    func registerToggleHotKey(shortcut: HotKeyShortcut = .defaultShortcut, action: @escaping () -> Void) -> Bool {
        self.onToggleTrigger = action
        self.currentShortcut = shortcut
        guard ensureEventHandlerInstalled() else { return false }

        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x514A434C), id: 1)
        let regStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &toggleHotKeyRef
        )
        return regStatus == noErr
    }

    @discardableResult
    func registerQueuePopHotKey(shortcut: HotKeyShortcut = .defaultQueueShortcut, action: @escaping () -> Void) -> Bool {
        self.onQueueTrigger = action
        self.currentQueueShortcut = shortcut
        guard ensureEventHandlerInstalled() else { return false }

        if let ref = queueHotKeyRef {
            UnregisterEventHotKey(ref)
            queueHotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x514A434C), id: 2)
        let regStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &queueHotKeyRef
        )
        return regStatus == noErr
    }

    @discardableResult
    func updateShortcut(_ shortcut: HotKeyShortcut) -> Bool {
        guard let action = onToggleTrigger else {
            currentShortcut = shortcut
            return true
        }
        return registerToggleHotKey(shortcut: shortcut, action: action)
    }

    @discardableResult
    func updateQueueShortcut(_ shortcut: HotKeyShortcut) -> Bool {
        guard let action = onQueueTrigger else {
            currentQueueShortcut = shortcut
            return true
        }
        return registerQueuePopHotKey(shortcut: shortcut, action: action)
    }

    /// 录制新快捷键前临时挂起全局拦截
    func suspendForRecording() {
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
        if let ref = queueHotKeyRef {
            UnregisterEventHotKey(ref)
            queueHotKeyRef = nil
        }
    }

    /// 取消或结束录制后恢复当前双通道快捷键
    func resumeAfterRecording() {
        _ = updateShortcut(currentShortcut)
        _ = updateQueueShortcut(currentQueueShortcut)
    }

    func unregister() {
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
        if let ref = queueHotKeyRef {
            UnregisterEventHotKey(ref)
            queueHotKeyRef = nil
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
