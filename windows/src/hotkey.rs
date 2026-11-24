use serde::{Deserialize, Serialize};

// Win32 Virtual-Key 与 RegisterHotKey 修饰键常量（跨平台可编译单测，与 windows-sys 常量值 100% 一致）
pub const MOD_ALT_BITS: u32 = 0x0001;
pub const MOD_CONTROL_BITS: u32 = 0x0002;
pub const MOD_SHIFT_BITS: u32 = 0x0004;
pub const MOD_WIN_BITS: u32 = 0x0008;
pub const MOD_ALL_MASK: u32 = MOD_ALT_BITS | MOD_CONTROL_BITS | MOD_SHIFT_BITS | MOD_WIN_BITS;

/// 支持「单键双击呼出」的纯净修饰键类型（按下松开不向输入框产生字符，零打字污染）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WinSingleModifier {
    Control,
    Alt,
    Shift,
    Win,
}

impl WinSingleModifier {
    pub fn label(self) -> &'static str {
        match self {
            Self::Control => "Ctrl",
            Self::Alt => "Alt",
            Self::Shift => "Shift",
            Self::Win => "Win",
        }
    }

    pub fn canonical_vk(self) -> u32 {
        match self {
            Self::Control => 0x11, // VK_CONTROL
            Self::Alt => 0x12,     // VK_MENU
            Self::Shift => 0x10,   // VK_SHIFT
            Self::Win => 0x5B,     // VK_LWIN
        }
    }

    pub fn from_vk(vk: u32) -> Option<Self> {
        match vk {
            0x11 | 0xA2 | 0xA3 => Some(Self::Control), // VK_CONTROL / VK_LCONTROL / VK_RCONTROL
            0x12 | 0xA4 | 0xA5 => Some(Self::Alt),     // VK_MENU / VK_LMENU / VK_RMENU
            0x10 | 0xA0 | 0xA1 => Some(Self::Shift),   // VK_SHIFT / VK_LSHIFT / VK_RSHIFT
            0x5B | 0x5C => Some(Self::Win),            // VK_LWIN / VK_RWIN
            _ => None,
        }
    }

    pub fn modifier_bit(self) -> u32 {
        match self {
            Self::Control => MOD_CONTROL_BITS,
            Self::Alt => MOD_ALT_BITS,
            Self::Shift => MOD_SHIFT_BITS,
            Self::Win => MOD_WIN_BITS,
        }
    }
}

/// 零误触双击修饰单键状态机（与 macOS 版 ModifierDoubleTapStateMachine 1:1 同构）
#[derive(Debug, Clone)]
pub struct WinModifierDoubleTapMachine {
    pub max_hold_ms: u64,
    pub max_gap_ms: u64,
    active_kind: Option<WinSingleModifier>,
    active_vk: u32,
    press_start_ms: u64,
    polluted_during_hold: bool,
    first_clean_kind: Option<WinSingleModifier>,
    first_clean_vk: u32,
    first_release_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DoubleTapOutcome {
    None,
    FirstTapCompleted(WinSingleModifier),
    DoubleTapTriggered(WinSingleModifier),
}

impl Default for WinModifierDoubleTapMachine {
    fn default() -> Self {
        Self::new(300, 340)
    }
}

impl WinModifierDoubleTapMachine {
    pub fn new(max_hold_ms: u64, max_gap_ms: u64) -> Self {
        Self {
            max_hold_ms,
            max_gap_ms,
            active_kind: None,
            active_vk: 0,
            press_start_ms: 0,
            polluted_during_hold: false,
            first_clean_kind: None,
            first_clean_vk: 0,
            first_release_ms: 0,
        }
    }

    pub fn reset(&mut self) {
        self.active_kind = None;
        self.active_vk = 0;
        self.press_start_ms = 0;
        self.polluted_during_hold = false;
        self.first_clean_kind = None;
        self.first_clean_vk = 0;
        self.first_release_ms = 0;
    }

    /// 期间若发生任何普通键按下（如 Ctrl+C -> Ctrl+V）或鼠标点击，立即作废当前双击序列
    pub fn mark_interfering_event(&mut self) {
        self.polluted_during_hold = true;
        self.first_clean_kind = None;
        self.first_clean_vk = 0;
        self.first_release_ms = 0;
    }

    pub fn handle_modifier_transition(
        &mut self,
        vk: u32,
        is_key_down: bool,
        active_mod_bits: u32,
        now_ms: u64,
    ) -> DoubleTapOutcome {
        let Some(kind) = WinSingleModifier::from_vk(vk) else {
            self.mark_interfering_event();
            return DoubleTapOutcome::None;
        };

        let clean_bits = active_mod_bits & MOD_ALL_MASK;

        if is_key_down {
            // 若已在按住同一个键（系统自动连发 key repeat），直接忽略不重置计时
            if self.active_kind == Some(kind) && self.active_vk == vk {
                return DoubleTapOutcome::None;
            }
            if clean_bits != 0 && clean_bits != kind.modifier_bit() {
                self.mark_interfering_event();
                return DoubleTapOutcome::None;
            }
            if self.first_clean_kind.is_some()
                && now_ms.saturating_sub(self.first_release_ms) > self.max_gap_ms
            {
                self.first_clean_kind = None;
                self.first_clean_vk = 0;
            }
            self.active_kind = Some(kind);
            self.active_vk = vk;
            self.press_start_ms = now_ms;
            self.polluted_during_hold = false;
            DoubleTapOutcome::None
        } else {
            if clean_bits != 0
                || self.polluted_during_hold
                || self.active_kind != Some(kind)
                || self.active_vk != vk
                || now_ms.saturating_sub(self.press_start_ms) > self.max_hold_ms
            {
                self.reset();
                return DoubleTapOutcome::None;
            }

            self.active_kind = None;
            self.active_vk = 0;

            if self.first_clean_kind == Some(kind)
                && self.first_clean_vk == vk
                && now_ms.saturating_sub(self.first_release_ms) <= self.max_gap_ms
            {
                self.first_clean_kind = None;
                self.first_clean_vk = 0;
                self.first_release_ms = 0;
                DoubleTapOutcome::DoubleTapTriggered(kind)
            } else {
                self.first_clean_kind = Some(kind);
                self.first_clean_vk = vk;
                self.first_release_ms = now_ms;
                DoubleTapOutcome::FirstTapCompleted(kind)
            }
        }
    }
}

/// 可持久化的全局快捷键模型（支持组合键与双击单键 Ctrl/Alt/Shift/Win）
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WinHotKeyShortcut {
    pub vk: u32,
    pub modifiers: u32,
    #[serde(default)]
    pub double_tap: Option<WinSingleModifier>,
}

impl WinHotKeyShortcut {
    pub const fn combo(vk: u32, modifiers: u32) -> Self {
        Self {
            vk,
            modifiers,
            double_tap: None,
        }
    }

    pub fn double_tap(kind: WinSingleModifier) -> Self {
        Self {
            vk: kind.canonical_vk(),
            modifiers: 0,
            double_tap: Some(kind),
        }
    }

    /// 默认主面板呼出快捷键：Alt + V
    pub const fn default_toggle() -> Self {
        Self::combo(0x56, MOD_ALT_BITS)
    }

    /// 默认顺序出队快捷键：Ctrl + Alt + V
    pub const fn default_queue_pop() -> Self {
        Self::combo(0x56, MOD_CONTROL_BITS | MOD_ALT_BITS)
    }

    /// 默认跨处选段续接复制快捷键：Ctrl + Alt + C
    pub const fn default_copy_append() -> Self {
        Self::combo(0x43, MOD_CONTROL_BITS | MOD_ALT_BITS)
    }

    pub fn is_double_tap(&self) -> bool {
        self.double_tap.is_some()
    }

    pub fn is_function_key(&self) -> bool {
        (0x70..=0x7B).contains(&self.vk) // VK_F1 .. VK_F12
    }

    pub fn display_string(&self) -> String {
        if let Some(kind) = self.double_tap {
            return format!("双击 {}", kind.label());
        }
        let mut parts: Vec<&str> = Vec::new();
        if (self.modifiers & MOD_CONTROL_BITS) != 0 {
            parts.push("Ctrl");
        }
        if (self.modifiers & MOD_ALT_BITS) != 0 {
            parts.push("Alt");
        }
        if (self.modifiers & MOD_SHIFT_BITS) != 0 {
            parts.push("Shift");
        }
        if (self.modifiers & MOD_WIN_BITS) != 0 {
            parts.push("Win");
        }
        let key_str = vk_label(self.vk);
        if parts.is_empty() {
            key_str
        } else {
            format!("{} + {key_str}", parts.join(" + "))
        }
    }

    pub fn compact_string(&self) -> String {
        if let Some(kind) = self.double_tap {
            return format!("{}×2", kind.label());
        }
        self.display_string().replace(" + ", "+")
    }
}

pub fn vk_label(vk: u32) -> String {
    match vk {
        0x41..=0x5A => char::from_u32(vk).unwrap_or('?').to_string(),
        0x30..=0x39 => char::from_u32(vk).unwrap_or('0').to_string(),
        0x70..=0x7B => format!("F{}", vk - 0x70 + 1),
        0x20 => "Space".to_string(),
        0x0D => "Enter".to_string(),
        0x09 => "Tab".to_string(),
        0x08 => "Backspace".to_string(),
        0x2E => "Del".to_string(),
        0x1B => "Esc".to_string(),
        0x25 => "←".to_string(),
        0x26 => "↑".to_string(),
        0x27 => "→".to_string(),
        0x28 => "↓".to_string(),
        0xBC => ",".to_string(),
        0xBE => ".".to_string(),
        0xBF => "/".to_string(),
        0xBA => ";".to_string(),
        0xDE => "'".to_string(),
        0xDB => "[".to_string(),
        0xDD => "]".to_string(),
        0xDC => "\\".to_string(),
        0xBD => "-".to_string(),
        0xBB => "=".to_string(),
        0xC0 => "`".to_string(),
        _ => format!("Key{vk}"),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WinHotKeySlot {
    MainToggle,
    QueuePop,
    CopyAppend,
}

/// 静态与应用内快捷键冲突硬拦截校验（命中冲突返回具体原因，禁止保存）
pub fn static_hotkey_conflict_reason(
    candidate: &WinHotKeyShortcut,
    _slot: WinHotKeySlot,
    existing_own: &WinHotKeyShortcut,
    other_bindings: &[(&WinHotKeyShortcut, &str)],
) -> Option<String> {
    if candidate == existing_own {
        return None;
    }

    if candidate.is_double_tap() {
        for (other, label) in other_bindings {
            if *other == candidate {
                return Some(format!(
                    "「{}」已绑定为「{label}」，禁止冲突设定",
                    candidate.display_string()
                ));
            }
        }
        return None;
    }

    let mods = candidate.modifiers & MOD_ALL_MASK;
    if mods == 0 && !candidate.is_function_key() {
        return Some(
            "普通字符键会干扰打字；请搭配修饰键，或连按两次 Ctrl/Alt/Shift 设为双击单键"
                .to_string(),
        );
    }
    if mods == MOD_SHIFT_BITS && !candidate.is_function_key() {
        return Some(format!(
            "「{}」会干扰日常大写与符号输入，请搭配 Ctrl / Alt 或双击单键",
            candidate.display_string()
        ));
    }

    for (other, label) in other_bindings {
        if *other == candidate {
            return Some(format!(
                "「{}」已绑定为「{label}」，禁止冲突设定",
                candidate.display_string()
            ));
        }
    }

    if let Some(sys_name) = windows_system_reserved_name(candidate) {
        return Some(format!(
            "「{}」与系统「{sys_name}」冲突，禁止设定",
            candidate.display_string()
        ));
    }

    if let Some(inner_name) = iclip_panel_reserved_name(candidate) {
        return Some(format!(
            "「{}」与 iClip 内置「{inner_name}」冲突，禁止设定",
            candidate.display_string()
        ));
    }

    None
}

fn windows_system_reserved_name(s: &WinHotKeyShortcut) -> Option<&'static str> {
    let vk = s.vk;
    let mods = s.modifiers & MOD_ALL_MASK;

    if mods == MOD_CONTROL_BITS {
        return match vk {
            0x43 => Some("复制 (Ctrl+C)"),
            0x56 => Some("粘贴 (Ctrl+V)"),
            0x58 => Some("剪切 (Ctrl+X)"),
            0x5A => Some("撤销 (Ctrl+Z)"),
            0x59 => Some("重做 (Ctrl+Y)"),
            0x41 => Some("全选 (Ctrl+A)"),
            0x53 => Some("保存 (Ctrl+S)"),
            0x46 => Some("查找 (Ctrl+F)"),
            0x57 => Some("关闭标签/窗口 (Ctrl+W)"),
            0x4E => Some("新建窗口 (Ctrl+N)"),
            0x54 => Some("新建标签页 (Ctrl+T)"),
            _ => None,
        };
    }

    if mods == MOD_ALT_BITS {
        return match vk {
            0x09 => Some("应用切换 (Alt+Tab)"),
            0x73 => Some("关闭窗口 (Alt+F4)"),
            _ => None,
        };
    }

    if mods == (MOD_CONTROL_BITS | MOD_SHIFT_BITS) && vk == 0x1B {
        return Some("任务管理器 (Ctrl+Shift+Esc)");
    }

    if mods == (MOD_CONTROL_BITS | MOD_ALT_BITS) && vk == 0x2E {
        return Some("系统安全界面 (Ctrl+Alt+Del)");
    }

    if mods == MOD_WIN_BITS {
        return match vk {
            0x56 => Some("Windows 系统剪贴板 (Win+V)"),
            0x4C => Some("锁定屏幕 (Win+L)"),
            0x44 => Some("显示桌面 (Win+D)"),
            0x45 => Some("资源管理器 (Win+E)"),
            0x52 => Some("运行对话框 (Win+R)"),
            0x53 => Some("系统搜索 (Win+S)"),
            0x49 => Some("系统设置 (Win+I)"),
            0x58 => Some("系统快捷菜单 (Win+X)"),
            0x09 => Some("任务视图 (Win+Tab)"),
            _ => None,
        };
    }

    if mods == (MOD_WIN_BITS | MOD_SHIFT_BITS) && vk == 0x53 {
        return Some("系统截图工具 (Win+Shift+S)");
    }

    None
}

fn iclip_panel_reserved_name(s: &WinHotKeyShortcut) -> Option<&'static str> {
    let vk = s.vk;
    let mods = s.modifiers & MOD_ALL_MASK;

    if (mods == MOD_CONTROL_BITS
        || mods == (MOD_CONTROL_BITS | MOD_ALT_BITS)
        || mods == (MOD_CONTROL_BITS | MOD_SHIFT_BITS))
        && (0x31..=0x39).contains(&vk)
    {
        return Some("顺位快速粘贴 (Ctrl+1~9)");
    }

    if mods == MOD_ALT_BITS && (0x31..=0x36).contains(&vk) {
        return Some("分类直达切换 (Alt+1~6)");
    }

    if mods == MOD_ALT_BITS && vk == 0x20 {
        return Some("原位差异比对 (Alt+Space)");
    }

    if mods == MOD_CONTROL_BITS {
        return match vk {
            0x50 => Some("窗口始终在前 (Ctrl+P)"),
            0x45 => Some("极简模式切换 (Ctrl+E)"),
            0x52 => Some("修改备注 (Ctrl+R)"),
            0x4F => Some("直达打开链接/路径 (Ctrl+O)"),
            0x44 => Some("收藏切换 (Ctrl+D)"),
            0xBC => Some("打开面板设置 (Ctrl+,)"),
            _ => None,
        };
    }

    if mods == (MOD_CONTROL_BITS | MOD_SHIFT_BITS) && vk == 0x43 {
        return Some("面板连环追加复制 (Ctrl+Shift+C)");
    }

    None
}

/// 无激活零失焦悬浮态下的键盘事件路由决策
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NonActiveKeyRoute {
    /// 放行给系统（如纯修饰键、全局呼出热键本身或系统级快捷键）
    PassThrough,
    /// 作为面板导航/功能键拦截转发（方向键、回车、Esc、Tab、Space、Backspace、面板组合键），全程不抢夺宿主窗口焦点
    DispatchPanelCommand,
    /// 用户敲击普通字符盲搜：按需激活面板输入焦点并将首字符送入搜索框
    ActivateAndTypeChar(char),
}

pub fn classify_non_active_panel_key(
    vk: u32,
    mods: u32,
    in_main_list: bool,
    show_quick_look: bool,
    is_recording: bool,
) -> NonActiveKeyRoute {
    if WinSingleModifier::from_vk(vk).is_some() {
        return NonActiveKeyRoute::PassThrough;
    }
    let clean_mods = mods & MOD_ALL_MASK;
    if (clean_mods & MOD_WIN_BITS) != 0 {
        return NonActiveKeyRoute::PassThrough;
    }
    if is_recording {
        return NonActiveKeyRoute::DispatchPanelCommand;
    }

    // 放行 Alt+Tab / Alt+F4 / Ctrl+Shift+Esc / Ctrl+Alt+Del 等系统组合键
    if (clean_mods == MOD_ALT_BITS && (vk == 0x09 || vk == 0x73))
        || (clean_mods == (MOD_CONTROL_BITS | MOD_SHIFT_BITS) && vk == 0x1B)
        || (clean_mods == (MOD_CONTROL_BITS | MOD_ALT_BITS) && vk == 0x2E)
    {
        return NonActiveKeyRoute::PassThrough;
    }

    // 面板核心导航键：Esc / Enter / 方向键 / Tab / Space / Backspace / Delete
    if matches!(
        vk,
        0x1B | 0x0D | 0x25 | 0x26 | 0x27 | 0x28 | 0x09 | 0x20 | 0x08 | 0x2E
    ) {
        return NonActiveKeyRoute::DispatchPanelCommand;
    }

    // 顺位快速粘贴与分类切换：Ctrl(+Shift/+Alt)+1~9, Alt+1~7
    if (0x31..=0x39).contains(&vk)
        && (clean_mods == MOD_CONTROL_BITS
            || clean_mods == (MOD_CONTROL_BITS | MOD_SHIFT_BITS)
            || clean_mods == (MOD_CONTROL_BITS | MOD_ALT_BITS)
            || clean_mods == MOD_ALT_BITS)
    {
        return NonActiveKeyRoute::DispatchPanelCommand;
    }

    // 面板功能快捷键：Ctrl + B/C/D/E/F/K/M/O/P/R/S/T/V/W/Y/Z/, 及 Ctrl+Shift+C
    if clean_mods == MOD_CONTROL_BITS
        && matches!(
            vk,
            0x42 | 0x43
                | 0x44
                | 0x45
                | 0x46
                | 0x4B
                | 0x4D
                | 0x4F
                | 0x50
                | 0x52
                | 0x53
                | 0x54
                | 0x56
                | 0x57
                | 0x59
                | 0x5A
                | 0xBC
        )
    {
        return NonActiveKeyRoute::DispatchPanelCommand;
    }
    if clean_mods == (MOD_CONTROL_BITS | MOD_SHIFT_BITS) && vk == 0x43 {
        return NonActiveKeyRoute::DispatchPanelCommand;
    }

    // 主列表下直接敲击无修饰（或 Shift）可打印字符时，按需激活面板并填入首字符盲搜
    if in_main_list && !show_quick_look && (clean_mods == 0 || clean_mods == MOD_SHIFT_BITS) {
        if let Some(ch) = vk_to_search_ascii(vk, clean_mods == MOD_SHIFT_BITS) {
            return NonActiveKeyRoute::ActivateAndTypeChar(ch);
        }
    }

    NonActiveKeyRoute::PassThrough
}

fn vk_to_search_ascii(vk: u32, shift: bool) -> Option<char> {
    match vk {
        0x41..=0x5A => {
            let base = (vk as u8) - b'A';
            Some((if shift { b'A' + base } else { b'a' + base }) as char)
        }
        0x30..=0x39 => {
            if !shift {
                Some((vk as u8) as char)
            } else {
                const SHIFTED: [char; 10] = [')', '!', '@', '#', '$', '%', '^', '&', '*', '('];
                Some(SHIFTED[(vk - 0x30) as usize])
            }
        }
        0x60..=0x69 if !shift => Some((b'0' + (vk - 0x60) as u8) as char),
        0x6A => Some('*'),
        0x6B => Some('+'),
        0x6D => Some('-'),
        0x6E => Some('.'),
        0x6F => Some('/'),
        0xBA => Some(if shift { ':' } else { ';' }),
        0xBB => Some(if shift { '+' } else { '=' }),
        0xBC => Some(if shift { '<' } else { ',' }),
        0xBD => Some(if shift { '_' } else { '-' }),
        0xBE => Some(if shift { '>' } else { '.' }),
        0xBF => Some(if shift { '?' } else { '/' }),
        0xC0 => Some(if shift { '~' } else { '`' }),
        0xDB => Some(if shift { '{' } else { '[' }),
        0xDC => Some(if shift { '|' } else { '\\' }),
        0xDD => Some(if shift { '}' } else { ']' }),
        0xDE => Some(if shift { '"' } else { '\'' }),
        _ => None,
    }
}

/// 仅当前台窗口不是原宿主窗口时才调用 SetForegroundWindow，避免重复激活冲掉宿主应用内已聚焦控件
pub fn should_restore_foreground_window(current_fg: isize, target_fg: isize) -> bool {
    target_fg != 0 && current_fg != target_fg
}
