import Foundation
import Carbon
import AppKit

/// 支持「双击单键呼出」的纯净修饰键类型（按下松开不向输入框产生任何字符，零打字污染）
enum SingleModifierKind: String, Codable, Equatable {
    case command
    case option
    case control
    case shift
    case fn

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .fn: return "Fn"
        }
    }

    var canonicalKeyCode: UInt32 {
        switch self {
        case .command: return 55
        case .option: return 58
        case .control: return 59
        case .shift: return 56
        case .fn: return 63
        }
    }

    static func from(keyCode: UInt16) -> SingleModifierKind? {
        switch keyCode {
        case 55, 54: return .command
        case 58, 61: return .option
        case 59, 62: return .control
        case 56, 60: return .shift
        case 63: return .fn
        default: return nil
        }
    }

    func isFlagPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .command: return flags.contains(.command)
        case .option: return flags.contains(.option)
        case .control: return flags.contains(.control)
        case .shift: return flags.contains(.shift)
        case .fn: return flags.contains(.function)
        }
    }

    func isExclusivelyPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection([.command, .option, .control, .shift, .function])
        switch self {
        case .command: return relevant == .command
        case .option: return relevant == .option
        case .control: return relevant == .control
        case .shift: return relevant == .shift
        case .fn: return relevant == .function
        }
    }
}

/// 零误触双击修饰单键状态机（第二次干净松开瞬间触发；期间只要夹杂任何字母键如 ⌘C×2 或鼠标点击即自动静默作废）
struct ModifierDoubleTapStateMachine {
    var maxHoldDuration: TimeInterval = 0.30
    var maxTapGap: TimeInterval = 0.34

    private var activePressKind: SingleModifierKind? = nil
    private var activePressKeyCode: UInt16? = nil
    private var activePressStartTime: TimeInterval = 0
    private var pollutedDuringHold: Bool = false

    private var firstCleanTapKind: SingleModifierKind? = nil
    private var firstCleanTapKeyCode: UInt16? = nil
    private var firstCleanReleaseTime: TimeInterval = 0

    enum StepOutcome: Equatable {
        case none
        case firstTapCompleted(SingleModifierKind)
        case doubleTapTriggered(SingleModifierKind)
    }

    init(maxHoldDuration: TimeInterval = 0.30, maxTapGap: TimeInterval = 0.34) {
        self.maxHoldDuration = maxHoldDuration
        self.maxTapGap = maxTapGap
    }

    mutating func reset() {
        activePressKind = nil
        activePressKeyCode = nil
        activePressStartTime = 0
        pollutedDuringHold = false
        firstCleanTapKind = nil
        firstCleanTapKeyCode = nil
        firstCleanReleaseTime = 0
    }

    /// 当普通按键按下或鼠标点击发生时调用，彻底阻断 ⌘C->⌘V 或 ⌘C×2 误触发双击修饰键
    mutating func markInterferingEvent() {
        pollutedDuringHold = true
        firstCleanTapKind = nil
        firstCleanTapKeyCode = nil
        firstCleanReleaseTime = 0
    }

    mutating func handleFlagsChanged(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        uptime: TimeInterval
    ) -> StepOutcome {
        guard let kind = SingleModifierKind.from(keyCode: keyCode) else {
            markInterferingEvent()
            return .none
        }

        let cleanFlags = flags.intersection([.command, .option, .control, .shift, .function])

        if kind.isFlagPressed(in: cleanFlags) {
            guard kind.isExclusivelyPressed(in: cleanFlags) else {
                // 同时按下了第二个修饰键（如 ⌃+⌥），作废单键双击序列
                markInterferingEvent()
                return .none
            }
            if firstCleanTapKind != nil && (uptime - firstCleanReleaseTime) > maxTapGap {
                firstCleanTapKind = nil
                firstCleanTapKeyCode = nil
            }
            activePressKind = kind
            activePressKeyCode = keyCode
            activePressStartTime = uptime
            pollutedDuringHold = false
            return .none
        } else {
            // 松开修饰键：必须无残留其他修饰键、期间未按过字母键、且按住时长不超过阈值
            guard cleanFlags.isEmpty,
                  !pollutedDuringHold,
                  activePressKind == kind,
                  activePressKeyCode == keyCode,
                  (uptime - activePressStartTime) <= maxHoldDuration else {
                reset()
                return .none
            }

            activePressKind = nil
            activePressKeyCode = nil

            if firstCleanTapKind == kind,
               firstCleanTapKeyCode == keyCode,
               (uptime - firstCleanReleaseTime) <= maxTapGap {
                firstCleanTapKind = nil
                firstCleanTapKeyCode = nil
                firstCleanReleaseTime = 0
                return .doubleTapTriggered(kind)
            } else {
                firstCleanTapKind = kind
                firstCleanTapKeyCode = keyCode
                firstCleanReleaseTime = uptime
                return .firstTapCompleted(kind)
            }
        }
    }
}

/// 可持久化的全局快捷键模型（支持「修饰键+主键」组合键与「双击单键 ⌘/⌥/⌃/⇧/Fn」两种模式，向后兼容旧版 JSON）
struct HotKeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let doubleTapModifier: SingleModifierKind?

    init(keyCode: UInt32, carbonModifiers: UInt32, doubleTapModifier: SingleModifierKind? = nil) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.doubleTapModifier = doubleTapModifier
    }

    static func doubleTap(_ kind: SingleModifierKind) -> HotKeyShortcut {
        HotKeyShortcut(keyCode: kind.canonicalKeyCode, carbonModifiers: 0, doubleTapModifier: kind)
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case carbonModifiers
        case doubleTapModifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        self.carbonModifiers = try container.decode(UInt32.self, forKey: .carbonModifiers)
        self.doubleTapModifier = try container.decodeIfPresent(SingleModifierKind.self, forKey: .doubleTapModifier)
    }

    var isDoubleTap: Bool {
        doubleTapModifier != nil
    }

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

    /// 默认跨处选段「续接复制（Copy-Append）」快捷键：Control + Option + C
    static let defaultCopyAppendShortcut = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_C),
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    /// 默认原生区域/窗口截图快捷键：Option + A
    static let defaultScreenshotShortcut = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_A),
        carbonModifiers: UInt32(optionKey)
    )

    /// 供界面显示的苹果标准符号串（例如 "⌥ V"、"⌃ ⌥ V"、"双击 ⌘"）
    var displayString: String {
        if let kind = doubleTapModifier {
            return "双击 \(kind.symbol)"
        }
        var parts: [String] = []
        if (carbonModifiers & UInt32(controlKey)) != 0 { parts.append("⌃") }
        if (carbonModifiers & UInt32(optionKey)) != 0 { parts.append("⌥") }
        if (carbonModifiers & UInt32(shiftKey)) != 0 { parts.append("⇧") }
        if (carbonModifiers & UInt32(cmdKey)) != 0 { parts.append("⌘") }
        parts.append(Self.keyLabel(for: keyCode))
        return parts.joined(separator: " ")
    }

    /// 紧凑符号串（用于菜单栏提示，例如 "⌥V"、"⌘⌘"）
    var compactDisplayString: String {
        if let kind = doubleTapModifier {
            return kind == .fn ? "Fn×2" : "\(kind.symbol)\(kind.symbol)"
        }
        return displayString.replacingOccurrences(of: " ", with: "")
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
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
        ]
        return map[Int(keyCode)] ?? "Key\(keyCode)"
    }

    var isFunctionKey: Bool {
        let functionKeyCodes: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12
        ]
        return functionKeyCodes.contains(Int(keyCode))
    }

    /// 新手引导键帽舞台所需的动态符号与标签
    var onboardingKeycaps: (leftSymbol: String, leftLabel: String, rightSymbol: String, rightLabel: String, isDoubleTap: Bool) {
        if let kind = doubleTapModifier {
            return (kind.symbol, "轻按第 1 下", "×2", "连按呼出", true)
        }
        let modMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let mods = carbonModifiers & modMask
        let keyTitle = Self.keyLabel(for: keyCode)
        if mods == 0 {
            return ("", "", keyTitle, "呼出面板", false)
        }
        var activeMods: [(symbol: String, label: String)] = []
        if (mods & UInt32(controlKey)) != 0 { activeMods.append(("⌃", "Control")) }
        if (mods & UInt32(optionKey)) != 0 { activeMods.append(("⌥", "Option")) }
        if (mods & UInt32(shiftKey)) != 0 { activeMods.append(("⇧", "Shift")) }
        if (mods & UInt32(cmdKey)) != 0 { activeMods.append(("⌘", "Command")) }
        let leftSymbol = activeMods.map(\.symbol).joined()
        let leftLabel = activeMods.count == 1 ? activeMods[0].label : "修饰键"
        return (leftSymbol, leftLabel, keyTitle, "呼出面板", false)
    }

    /// 判断当前按下的修饰键是否命中试按阶段的键帽下沉反馈（与双击状态机一致，排除多修饰键误触发）
    func matchesTrialModifierPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        if let kind = doubleTapModifier {
            return kind.isExclusivelyPressed(in: flags)
        }
        let modMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let required = carbonModifiers & modMask
        guard required != 0 else { return false }
        return Self.carbonModifiers(from: flags) == required
    }

    /// 本地键盘事件是否精准匹配当前用户配置的呼出组合键（双击单键交由 flagsChanged 状态机处理）
    func matchesLocalKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard doubleTapModifier == nil else { return false }
        let modMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return UInt32(keyCode) == self.keyCode
            && Self.carbonModifiers(from: flags) == (carbonModifiers & modMask)
    }
}

/// 全局热键槽位类型
enum HotKeySlotRole: Equatable {
    case mainToggle
    case queuePop
    case copyAppend
    case screenshot
}

/// 快捷键全链路冲突检测器（一旦命中冲突即返回明确拦截原因，禁止设定保存）
enum HotKeyConflictValidator {
    private static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    /// 纯静态/应用内冲突规则校验（无修饰键、单 Shift 干扰输入、系统核心快捷键、iClip 内部多通道及面板热键）
    static func staticConflictReason(
        for candidate: HotKeyShortcut,
        role: HotKeySlotRole,
        existingOwnShortcut: HotKeyShortcut,
        otherBindings: [(shortcut: HotKeyShortcut, label: String)]
    ) -> String? {
        if candidate == existingOwnShortcut {
            return nil
        }

        // 若为「双击修饰单键（⌘ / ⌥ / ⌃ / ⇧ / Fn）」模式，检查应用内其他槽位查重与系统听写双击冲突
        if let kind = candidate.doubleTapModifier {
            for binding in otherBindings where binding.shortcut == candidate {
                return "「\(candidate.displayString)」已绑定为「\(binding.label)」，禁止冲突设定"
            }
            if let dictationReason = activeSystemDictationDoubleTapConflict(for: kind) {
                return dictationReason
            }
            return nil
        }

        let mods = candidate.carbonModifiers & modifierMask

        // 1. 修饰键完备性校验：禁止普通字符无修饰键或仅 Shift 搭配普通字符（引导用户双击修饰键实现单键呼出）
        if mods == 0 && !candidate.isFunctionKey {
            return "普通字符键会干扰日常打字；请搭配修饰键，或连按两次 ⌘ / ⌥ / ⌃ / ⇧ 设为双击单键"
        }
        if mods == UInt32(shiftKey) && !candidate.isFunctionKey {
            return "「\(candidate.displayString)」会干扰日常大写与符号输入，请搭配 ⌘ / ⌥ / ⌃ 或双击单键"
        }

        // 2. 与 iClip 自身其他已启用全局热键槽位互锁查重
        for binding in otherBindings where binding.shortcut == candidate {
            return "「\(candidate.displayString)」已绑定为「\(binding.label)」，禁止冲突设定"
        }

        // 3. macOS 系统核心编辑、窗口与全局截屏锁屏保留键硬拦截
        if let sysName = systemCoreReservedName(for: candidate) {
            return "「\(candidate.displayString)」与系统「\(sysName)」冲突，禁止设定"
        }

        // 4. iClip 面板内建固定核心快捷键冲突保护（仅针对呼出主面板与顺序出队）
        if let internalName = internalPanelReservedName(for: candidate) {
            return "「\(candidate.displayString)」与 iClip 内置「\(internalName)」冲突，禁止设定"
        }

        return nil
    }

    /// 实时查询 macOS「系统设置 → 键盘快捷键」中当前处于启用状态的全局符号热键（CopySymbolicHotKeys）
    static func activeSystemSymbolicHotKeyConflict(
        for candidate: HotKeyShortcut,
        existingOwnShortcut: HotKeyShortcut
    ) -> String? {
        if candidate == existingOwnShortcut || candidate.isDoubleTap { return nil }
        let mods = candidate.carbonModifiers & modifierMask

        var unmanagedArray: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&unmanagedArray)
        guard status == noErr,
              let list = unmanagedArray?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }

        for entry in list {
            let enabled = (entry[kHISymbolicHotKeyEnabled as String] as? Bool)
                ?? ((entry[kHISymbolicHotKeyEnabled as String] as? Int ?? 0) != 0)
            guard enabled else { continue }
            guard let rawCode = entry[kHISymbolicHotKeyCode as String] as? Int,
                  rawCode >= 0 && rawCode != 65535,
                  let rawMods = entry[kHISymbolicHotKeyModifiers as String] as? Int else {
                continue
            }
            let sysCode = UInt32(rawCode)
            let sysMods = UInt32(rawMods) & modifierMask
            if sysCode == candidate.keyCode && sysMods == mods {
                return "「\(candidate.displayString)」已在 macOS 系统键盘快捷键中启用，禁止设定"
            }
        }
        return nil
    }

    private static func systemCoreReservedName(for s: HotKeyShortcut) -> String? {
        let code = Int(s.keyCode)
        let mods = s.carbonModifiers & modifierMask
        let cmd = UInt32(cmdKey)
        let opt = UInt32(optionKey)
        let ctrl = UInt32(controlKey)
        let shift = UInt32(shiftKey)

        if mods == cmd {
            switch code {
            case kVK_ANSI_C: return "复制"
            case kVK_ANSI_V: return "粘贴"
            case kVK_ANSI_X: return "剪切"
            case kVK_ANSI_Z: return "撤销"
            case kVK_ANSI_A: return "全选"
            case kVK_ANSI_S: return "保存"
            case kVK_ANSI_F: return "查找"
            case kVK_ANSI_Q: return "退出应用"
            case kVK_ANSI_W: return "关闭窗口"
            case kVK_ANSI_H: return "隐藏应用"
            case kVK_ANSI_M: return "最小化窗口"
            case kVK_ANSI_N: return "新建窗口"
            case kVK_ANSI_T: return "新建标签页"
            case kVK_ANSI_Comma: return "应用偏好设置"
            case kVK_Tab: return "应用切换器"
            case kVK_ANSI_Grave: return "同应用切换窗口"
            case kVK_Space: return "聚焦搜索 (Spotlight)"
            default: break
            }
        } else if mods == (cmd | shift) {
            switch code {
            case kVK_ANSI_Z: return "重做"
            case kVK_Tab: return "应用反向切换"
            case kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5: return "系统截屏/录屏"
            default: break
            }
        } else if mods == (cmd | opt) {
            switch code {
            case kVK_Escape: return "强制退出应用"
            case kVK_ANSI_H: return "隐藏其他应用"
            case kVK_ANSI_D: return "显示/隐藏程序坞"
            default: break
            }
        } else if mods == (cmd | ctrl) {
            switch code {
            case kVK_ANSI_Q: return "锁定屏幕"
            case kVK_Space: return "表情与符号"
            case kVK_ANSI_F: return "切换全屏"
            default: break
            }
        } else if mods == ctrl && code == kVK_Space {
            return "切换输入法"
        } else if mods == (ctrl | opt) && code == kVK_Space {
            return "切换下一个输入法"
        } else if mods == (cmd | ctrl | shift) && (code == kVK_ANSI_3 || code == kVK_ANSI_4) {
            return "截屏到剪贴板"
        }
        return nil
    }

    private static func internalPanelReservedName(for s: HotKeyShortcut) -> String? {
        let code = Int(s.keyCode)
        let mods = s.carbonModifiers & modifierMask
        let cmd = UInt32(cmdKey)
        let opt = UInt32(optionKey)
        let ctrl = UInt32(controlKey)
        let shift = UInt32(shiftKey)

        let digitCodes: Set<Int> = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
            kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
        ]
        if (mods == cmd || mods == (cmd | opt) || mods == (cmd | shift)) && digitCodes.contains(code) {
            return "顺位快速粘贴 (⌘1~9)"
        }
        let tabOptionCodes: Set<Int> = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6
        ]
        if mods == opt && tabOptionCodes.contains(code) {
            return "分类快速切换 (⌥1~6)"
        }
        if mods == ctrl && (code == kVK_ANSI_1 || code == kVK_ANSI_2 || code == kVK_ANSI_3) {
            return "直达语义变换 (⌃1~3)"
        }
        if mods == opt && code == kVK_Space {
            return "原位差异比对 (⌥Space)"
        }
        if mods == cmd {
            switch code {
            case kVK_ANSI_P: return "窗口始终在前 (⌘P)"
            case kVK_ANSI_E: return "极简模式/编辑 (⌘E)"
            case kVK_ANSI_R: return "修改备注 (⌘R)"
            case kVK_ANSI_O: return "打开链接/路径 (⌘O)"
            case kVK_ANSI_D: return "收藏切换 (⌘D)"
            case kVK_ANSI_Y: return "速览预览 (⌘Y)"
            case kVK_Delete: return "删除记录 (⌘⌫)"
            default: break
            }
        }
        if mods == (cmd | shift) && code == kVK_ANSI_C {
            return "连环追加复制 (⇧⌘C)"
        }
        if mods == (cmd | opt) && code == kVK_ANSI_C {
            return "纯文本/路径拷贝 (⌥⌘C)"
        }
        return nil
    }

    private static func activeSystemDictationDoubleTapConflict(for kind: SingleModifierKind) -> String? {
        guard let speechDomain = UserDefaults.standard.persistentDomain(forName: "com.apple.speech.recognition.AppleSpeechRecognition.prefs"),
              let masterEnabled = speechDomain["DictationIMMasterDictationEnabled"] as? Bool,
              masterEnabled else {
            return nil
        }
        // macOS 语音听写开启时默认常绑定双击 Fn 或双击 Control / Command（DictationIMShortcutValue）
        if let shortcutVal = speechDomain["DictationIMShortcutValue"] as? Int {
            let conflicted: Bool
            switch shortcutVal {
            case 1: conflicted = (kind == .fn)
            case 2, 3, 4: conflicted = (kind == .command)
            case 5: conflicted = (kind == .control)
            default: conflicted = false
            }
            if conflicted {
                return "「双击 \(kind.symbol)」与 macOS 已启用的「听写」快捷键冲突，禁止设定"
            }
        }
        return nil
    }
}

/// 基于 Carbon 的多通道可热更新全局快捷键管理（ID 1: 呼出主面板；ID 2: 免开面板顺序出队）
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var toggleHotKeyRef: EventHotKeyRef?
    private var queueHotKeyRef: EventHotKeyRef?
    private var copyAppendHotKeyRef: EventHotKeyRef?
    private var screenshotHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var onToggleTrigger: (() -> Void)?
    private var onQueueTrigger: (() -> Void)?
    private var onCopyAppendTrigger: (() -> Void)?
    private var onScreenshotTrigger: (() -> Void)?

    private var currentShortcut: HotKeyShortcut = .defaultShortcut
    private var currentQueueShortcut: HotKeyShortcut = .defaultQueueShortcut
    private var currentCopyAppendShortcut: HotKeyShortcut = .defaultCopyAppendShortcut
    private var currentScreenshotShortcut: HotKeyShortcut = .defaultScreenshotShortcut

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalInterferenceMonitor: Any?
    private var localInterferenceMonitor: Any?
    private var runtimeDoubleTapMachine = ModifierDoubleTapStateMachine()
    private var isSuspendedForRecording: Bool = false
    private var lastDoubleTapFireUptime: TimeInterval = 0

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
                    } else if id == 3 {
                        manager.onCopyAppendTrigger?()
                    } else if id == 4 {
                        manager.onScreenshotTrigger?()
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

        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }

        if shortcut.isDoubleTap {
            refreshDoubleTapMonitors()
            return true
        }

        refreshDoubleTapMonitors()
        guard ensureEventHandlerInstalled() else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x514A434C), id: 1)
        var regStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &toggleHotKeyRef
        )
        if regStatus == eventHotKeyExistsErr {
            regStatus = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &toggleHotKeyRef
            )
        }
        return regStatus == noErr
    }

    @discardableResult
    func registerQueuePopHotKey(shortcut: HotKeyShortcut = .defaultQueueShortcut, action: @escaping () -> Void) -> Bool {
        self.onQueueTrigger = action
        self.currentQueueShortcut = shortcut

        if let ref = queueHotKeyRef {
            UnregisterEventHotKey(ref)
            queueHotKeyRef = nil
        }

        if shortcut.isDoubleTap {
            refreshDoubleTapMonitors()
            return true
        }

        refreshDoubleTapMonitors()
        guard ensureEventHandlerInstalled() else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x514A434C), id: 2)
        var regStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &queueHotKeyRef
        )
        if regStatus == eventHotKeyExistsErr {
            regStatus = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &queueHotKeyRef
            )
        }
        return regStatus == noErr
    }

    @discardableResult
    func registerCopyAppendHotKey(shortcut: HotKeyShortcut = .defaultCopyAppendShortcut, action: @escaping () -> Void) -> Bool {
        self.onCopyAppendTrigger = action
        self.currentCopyAppendShortcut = shortcut
        guard ensureEventHandlerInstalled() else { return false }

        if let ref = copyAppendHotKeyRef {
            UnregisterEventHotKey(ref)
            copyAppendHotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x514A434C), id: 3)
        var regStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &copyAppendHotKeyRef
        )
        if regStatus == eventHotKeyExistsErr {
            regStatus = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &copyAppendHotKeyRef
            )
        }
        return regStatus == noErr
    }

    @discardableResult
    func registerScreenshotHotKey(shortcut: HotKeyShortcut = .defaultScreenshotShortcut, action: @escaping () -> Void) -> Bool {
        self.onScreenshotTrigger = action
        self.currentScreenshotShortcut = shortcut

        if let ref = screenshotHotKeyRef {
            UnregisterEventHotKey(ref)
            screenshotHotKeyRef = nil
        }

        if shortcut.isDoubleTap {
            refreshDoubleTapMonitors()
            return true
        }

        refreshDoubleTapMonitors()
        guard ensureEventHandlerInstalled() else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x514A434C), id: 4)
        var regStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &screenshotHotKeyRef
        )
        if regStatus == eventHotKeyExistsErr {
            regStatus = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &screenshotHotKeyRef
            )
        }
        return regStatus == noErr
    }

    /// 录制设定新快捷键时的硬性冲突检测：一旦与系统核心键、系统启用热键、本应用其他热键或其他运行中应用冲突，返回原因并拒绝保存
    func validateAndProbeShortcut(
        _ candidate: HotKeyShortcut,
        for role: HotKeySlotRole,
        copyAppendEnabled: Bool = true
    ) -> String? {
        let existingOwn: HotKeyShortcut
        var others: [(shortcut: HotKeyShortcut, label: String)] = []

        switch role {
        case .mainToggle:
            existingOwn = currentShortcut
            if onQueueTrigger != nil {
                others.append((currentQueueShortcut, "顺序出队热键"))
            }
            if copyAppendEnabled && onCopyAppendTrigger != nil {
                others.append((currentCopyAppendShortcut, "跨处续接复制"))
            }
            if onScreenshotTrigger != nil {
                others.append((currentScreenshotShortcut, "区域/窗口截图"))
            }
        case .queuePop:
            existingOwn = currentQueueShortcut
            others.append((currentShortcut, "全局呼出快捷键"))
            if copyAppendEnabled && onCopyAppendTrigger != nil {
                others.append((currentCopyAppendShortcut, "跨处续接复制"))
            }
            if onScreenshotTrigger != nil {
                others.append((currentScreenshotShortcut, "区域/窗口截图"))
            }
        case .copyAppend:
            existingOwn = currentCopyAppendShortcut
            others.append((currentShortcut, "全局呼出快捷键"))
            if onQueueTrigger != nil {
                others.append((currentQueueShortcut, "顺序出队热键"))
            }
            if onScreenshotTrigger != nil {
                others.append((currentScreenshotShortcut, "区域/窗口截图"))
            }
        case .screenshot:
            existingOwn = currentScreenshotShortcut
            others.append((currentShortcut, "全局呼出快捷键"))
            if onQueueTrigger != nil {
                others.append((currentQueueShortcut, "顺序出队热键"))
            }
            if copyAppendEnabled && onCopyAppendTrigger != nil {
                others.append((currentCopyAppendShortcut, "跨处续接复制"))
            }
        }

        if let staticReason = HotKeyConflictValidator.staticConflictReason(
            for: candidate,
            role: role,
            existingOwnShortcut: existingOwn,
            otherBindings: others
        ) {
            return staticReason
        }

        if let sysSymbolicReason = HotKeyConflictValidator.activeSystemSymbolicHotKeyConflict(
            for: candidate,
            existingOwnShortcut: existingOwn
        ) {
            return sysSymbolicReason
        }

        if candidate != existingOwn && !candidate.isDoubleTap {
            var probeRef: EventHotKeyRef?
            let probeID = EventHotKeyID(signature: OSType(0x514A5052), id: 99)
            let status = RegisterEventHotKey(
                candidate.keyCode,
                candidate.carbonModifiers,
                probeID,
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive),
                &probeRef
            )
            if let ref = probeRef {
                UnregisterEventHotKey(ref)
            }
            if status != noErr {
                return "「\(candidate.displayString)」已被其他运行中应用占用，禁止设定"
            }
        }

        return nil
    }

    @discardableResult
    func updateCopyAppendShortcut(_ shortcut: HotKeyShortcut) -> Bool {
        guard let action = onCopyAppendTrigger else {
            currentCopyAppendShortcut = shortcut
            return true
        }
        return registerCopyAppendHotKey(shortcut: shortcut, action: action)
    }

    func unregisterCopyAppendHotKey() {
        if let ref = copyAppendHotKeyRef {
            UnregisterEventHotKey(ref)
            copyAppendHotKeyRef = nil
        }
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
    func updateScreenshotShortcut(_ shortcut: HotKeyShortcut) -> Bool {
        guard let action = onScreenshotTrigger else {
            currentScreenshotShortcut = shortcut
            return true
        }
        return registerScreenshotHotKey(shortcut: shortcut, action: action)
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
        isSuspendedForRecording = true
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
        if let ref = queueHotKeyRef {
            UnregisterEventHotKey(ref)
            queueHotKeyRef = nil
        }
        if let ref = copyAppendHotKeyRef {
            UnregisterEventHotKey(ref)
            copyAppendHotKeyRef = nil
        }
        if let ref = screenshotHotKeyRef {
            UnregisterEventHotKey(ref)
            screenshotHotKeyRef = nil
        }
        removeDoubleTapMonitors()
    }

    /// 取消或结束录制后恢复当前多通道快捷键
    func resumeAfterRecording() {
        isSuspendedForRecording = false
        _ = updateShortcut(currentShortcut)
        _ = updateQueueShortcut(currentQueueShortcut)
        if onCopyAppendTrigger != nil {
            _ = updateCopyAppendShortcut(currentCopyAppendShortcut)
        }
        if onScreenshotTrigger != nil {
            _ = updateScreenshotShortcut(currentScreenshotShortcut)
        }
        refreshDoubleTapMonitors()
    }

    private func refreshDoubleTapMonitors() {
        guard !isSuspendedForRecording else {
            removeDoubleTapMonitors()
            return
        }
        let needsToggle = (onToggleTrigger != nil && currentShortcut.isDoubleTap)
        let needsQueue = (onQueueTrigger != nil && currentQueueShortcut.isDoubleTap)
        let needsScreenshot = (onScreenshotTrigger != nil && currentScreenshotShortcut.isDoubleTap)
        guard needsToggle || needsQueue || needsScreenshot else {
            removeDoubleTapMonitors()
            return
        }
        guard globalFlagsMonitor == nil else { return }

        runtimeDoubleTapMachine.reset()

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.processRuntimeFlagsEvent(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.processRuntimeFlagsEvent(event)
            return event
        }
        globalInterferenceMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.runtimeDoubleTapMachine.markInterferingEvent()
        }
        localInterferenceMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.runtimeDoubleTapMachine.markInterferingEvent()
            return event
        }
    }

    private func removeDoubleTapMonitors() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m); globalFlagsMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
        if let m = globalInterferenceMonitor { NSEvent.removeMonitor(m); globalInterferenceMonitor = nil }
        if let m = localInterferenceMonitor { NSEvent.removeMonitor(m); localInterferenceMonitor = nil }
        runtimeDoubleTapMachine.reset()
    }

    private func processRuntimeFlagsEvent(_ event: NSEvent) {
        guard !isSuspendedForRecording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let outcome = runtimeDoubleTapMachine.handleFlagsChanged(
            keyCode: event.keyCode,
            flags: event.modifierFlags,
            uptime: now
        )
        guard case .doubleTapTriggered(let kind) = outcome else { return }
        guard (now - lastDoubleTapFireUptime) > 0.12 else { return }

        if currentShortcut.doubleTapModifier == kind, let toggle = onToggleTrigger {
            lastDoubleTapFireUptime = now
            DispatchQueue.main.async { toggle() }
        } else if currentQueueShortcut.doubleTapModifier == kind, let queue = onQueueTrigger {
            lastDoubleTapFireUptime = now
            DispatchQueue.main.async { queue() }
        } else if currentScreenshotShortcut.doubleTapModifier == kind, let shot = onScreenshotTrigger {
            lastDoubleTapFireUptime = now
            DispatchQueue.main.async { shot() }
        }
    }

    func unregister() {
        removeDoubleTapMonitors()
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
        if let ref = queueHotKeyRef {
            UnregisterEventHotKey(ref)
            queueHotKeyRef = nil
        }
        if let ref = copyAppendHotKeyRef {
            UnregisterEventHotKey(ref)
            copyAppendHotKeyRef = nil
        }
        if let ref = screenshotHotKeyRef {
            UnregisterEventHotKey(ref)
            screenshotHotKeyRef = nil
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
