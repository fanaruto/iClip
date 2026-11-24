#![cfg(target_os = "windows")]

use iclip_core::canvas_ui::{
    build_display_rows_ext, estimate_text_px, grid_move_selection, image_grid_row_height,
    standard_card_height, Color4, DisplayRow, GlassPalette, GridMoveDir, PixelCanvas,
};
use iclip_core::engines::{
    analyze_file_actions, analyze_text_actions, clean_tracking_url, compress_png_to_white_bg_jpeg,
    render_dynamic_template, render_mockup_frame_png, strip_file_metadata_to_clean_png,
};
use iclip_core::hotkey::{
    classify_non_active_panel_key, should_restore_foreground_window, static_hotkey_conflict_reason,
    DoubleTapOutcome, NonActiveKeyRoute, WinHotKeyShortcut, WinHotKeySlot,
    WinModifierDoubleTapMachine, WinSingleModifier, MOD_ALT_BITS, MOD_CONTROL_BITS, MOD_SHIFT_BITS,
    MOD_WIN_BITS,
};
use iclip_core::intelligence::{
    compute_clipboard_diff, evaluate_instant_math, extract_clean_share_url,
    extract_suggestion_payload, format_relative_time, is_code_editor_or_terminal_app,
    parse_quick_capture, DiffLineKind,
};
use iclip_core::model::{
    now_unix_secs, ClipContentType, ClipFilterTab, ClipItem, PinCategory, QuickAction,
};
use iclip_core::store::{ClipboardStore, GlassAppearance};
use iclip_core::updater::{OtaReleaseInfo, OtaState};
use image::{codecs::png::PngEncoder, imageops::FilterType, ColorType, ImageEncoder};
use std::cell::RefCell;
use std::ffi::OsString;
use std::mem::{size_of, zeroed};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use windows_sys::Win32::Foundation::{
    CloseHandle, FALSE, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM,
};
use windows_sys::Win32::Graphics::Dwm::{DwmExtendFrameIntoClientArea, DwmSetWindowAttribute};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, BitBlt, CreateCompatibleDC, CreateDIBSection, CreateFontW, DeleteDC, DeleteObject,
    DrawTextW, EndPaint, EnumFontFamiliesExW, GdiFlush, GetDC, GetMonitorInfoW,
    GetTextExtentPoint32W, InvalidateRect, MonitorFromPoint, ReleaseDC, SelectObject, SetBkMode,
    SetTextColor, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CLEARTYPE_NATURAL_QUALITY,
    CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DIB_RGB_COLORS, DT_CENTER, DT_END_ELLIPSIS, DT_LEFT,
    DT_NOPREFIX, DT_RIGHT, DT_SINGLELINE, DT_VCENTER, DT_WORDBREAK, FW_BOLD, FW_MEDIUM, FW_NORMAL,
    FW_SEMIBOLD, HDC, LOGFONTW, MONITORINFO, MONITOR_DEFAULTTONEAREST, OUT_DEFAULT_PRECIS,
    PAINTSTRUCT, SRCCOPY, TEXTMETRICW, TRANSPARENT,
};
use windows_sys::Win32::System::DataExchange::{
    AddClipboardFormatListener, CloseClipboard, EmptyClipboard, GetClipboardData,
    GetClipboardOwner, GetClipboardSequenceNumber, IsClipboardFormatAvailable, OpenClipboard,
    RegisterClipboardFormatW, RemoveClipboardFormatListener, SetClipboardData,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Memory::{
    GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE, GMEM_ZEROINIT,
};
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW,
    HKEY_CURRENT_USER, KEY_READ, KEY_SET_VALUE, REG_SZ,
};
use windows_sys::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows_sys::Win32::UI::Controls::Dialogs::{
    GetOpenFileNameW, GetSaveFileNameW, OFN_EXPLORER, OFN_FILEMUSTEXIST, OFN_NOCHANGEDIR,
    OFN_OVERWRITEPROMPT, OFN_PATHMUSTEXIST, OPENFILENAMEW,
};
use windows_sys::Win32::UI::Controls::MARGINS;
use windows_sys::Win32::UI::HiDpi::{
    GetDpiForWindow, SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyState, RegisterHotKey, ReleaseCapture, SendInput, SetFocus, UnregisterHotKey, INPUT,
    INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, MOD_NOREPEAT, VK_BACK, VK_CONTROL,
    VK_DELETE, VK_DOWN, VK_ESCAPE, VK_LEFT, VK_MENU, VK_RETURN, VK_RIGHT, VK_SHIFT, VK_SPACE,
    VK_TAB, VK_UP,
};
use windows_sys::Win32::UI::Shell::{
    DragQueryFileW, ShellExecuteW, Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD,
    NIM_DELETE, NIM_MODIFY, NOTIFYICONDATAW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

// 标准面板逻辑尺寸（1:1 对齐 macOS ClipboardPopoverView 420×560）
const PANEL_BASE_W: i32 = 420;
const PANEL_BASE_H: i32 = 560;

const WM_TRAYICON: u32 = WM_USER + 101;
const WM_APP_DOUBLETAP: u32 = WM_USER + 102;
const WM_APP_PANEL_KEY: u32 = WM_USER + 103;
const WM_APP_PANEL_TYPE_CHAR: u32 = WM_USER + 104;
const WM_APP_OUTSIDE_CLICK: u32 = WM_USER + 105;
const WM_APP_OTA_STATE: u32 = WM_USER + 106;
const WM_APP_OTA_RESTART: u32 = WM_USER + 107;
const WS_EX_NOACTIVATE_VAL: u32 = 0x0800_0000;
const SWP_NOACTIVATE_VAL: u32 = 0x0010;
const WM_MOUSEACTIVATE_MSG: u32 = 0x0021;
const MA_NOACTIVATE_RES: LRESULT = 3;
const WM_CLIPBOARDUPDATE_MSG: u32 = 0x031D;
const WM_POWERBROADCAST_MSG: u32 = 0x0218;
const PBT_APMSUSPEND_VAL: usize = 0x0004;
const WM_WTSSESSION_CHANGE_MSG: u32 = 0x02B1;
const WTS_SESSION_LOCK_VAL: usize = 0x0007;

#[link(name = "wtsapi32")]
extern "system" {
    fn WTSRegisterSessionNotification(hwnd: HWND, dw_flags: u32) -> i32;
    fn WTSUnRegisterSessionNotification(hwnd: HWND) -> i32;
}

const HOTKEY_ID_TOGGLE: i32 = 1001;
const HOTKEY_ID_QUEUE_POP: i32 = 1002;
const HOTKEY_ID_COPY_APPEND: i32 = 1003;
const HOTKEY_ID_PROBE: i32 = 1099;

const TIMER_ID_OTP_SWEEP: usize = 2001;
const TIMER_ID_TOAST_CLEAR: usize = 2002;
const TIMER_ID_COPY_FLASH_CLEAR: usize = 2003;
const TIMER_ID_DEFERRED_APPEND: usize = 2004;
const TIMER_ID_SPRING_ANIM: usize = 2005;
const TIMER_ID_CONCEALED_SCRUB: usize = 2006;
const TIMER_ID_SILENT_OTA_CHECK: usize = 2007;

const WDA_NONE_AFFINITY: u32 = 0x0000_0000;
const WDA_EXCLUDEFROMCAPTURE_AFFINITY: u32 = 0x0000_0011;

const CMD_OPEN_PANEL: usize = 3001;
const CMD_OPEN_SETTINGS: usize = 3002;
const CMD_TOGGLE_MINIMAL: usize = 3003;
const CMD_TOGGLE_PIN_WINDOW: usize = 3004;
const CMD_TOGGLE_OTP_EXPIRE: usize = 3005;
const CMD_EXPORT_ARCHIVE: usize = 3006;
const CMD_IMPORT_ARCHIVE: usize = 3007;
const CMD_TOGGLE_PAUSE: usize = 3008;
const CMD_TOGGLE_AUTOSTART: usize = 3009;
const CMD_CLEAR_UNPINNED: usize = 3010;
const CMD_QUIT_APP: usize = 3011;
const CMD_TOGGLE_QUEUE_MODE: usize = 3012;
const CMD_OPEN_TODO_LIST: usize = 3013;
const CMD_PIN_TODO_BOARD: usize = 3014;
const CMD_INSTALL_TO_SYSTEM: usize = 3015;
const CMD_PAUSE_15M: usize = 3016;
const CMD_PAUSE_60M: usize = 3017;
const CMD_CHECK_UPDATES: usize = 3018;

const CF_UNICODETEXT_ID: u32 = 13;
const CF_DIB_ID: u32 = 8;
const CF_HDROP_ID: u32 = 15;

// DWM 属性常量（Windows 11 原生连续圆角与 Acrylic/Mica 分档材质）
const DWMWA_USE_IMMERSIVE_DARK_MODE_ATTR: u32 = 20;
const DWMWA_WINDOW_CORNER_PREFERENCE_ATTR: u32 = 33;
const DWMWA_SYSTEMBACKDROP_TYPE_ATTR: u32 = 38;
const DWMWCP_ROUND_VAL: u32 = 2;
const DWMSBT_NONE_VAL: u32 = 1;
const DWMSBT_MAINWINDOW_VAL: u32 = 2;
const DWMSBT_TRANSIENTWINDOW_VAL: u32 = 3;

static MAIN_HWND_RAW: AtomicIsize = AtomicIsize::new(0);

#[derive(Clone, Copy, PartialEq, Eq)]
enum ActiveViewMode {
    MainList,
    Settings,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ThemePreference {
    System,
    Light,
    Dark,
}

#[derive(Clone)]
struct HitRegion {
    rect: RECT,
    interactive_cursor: bool,
    action: HitAction,
}

#[derive(Clone)]
enum HitAction {
    FocusSearch,
    ClearSearch,
    ToggleMinimalMode,
    ToggleAlwaysOnTop,
    ToggleSettingsView,
    SelectTab(ClipFilterTab),
    SelectPinCategory(Option<PinCategory>),
    CommitMathResult(String),
    CommitEphemeralSecret {
        secret: String,
        toast: String,
    },
    CommitLockedCapsule {
        plain: String,
        passphrase: String,
    },
    PinGeneratedSecret {
        secret: String,
        alias: String,
    },
    CommitQuickCapture,
    CommitSuggestion(String),
    SelectCard(usize),
    OpenExternalTarget(usize),
    TriggerQuickAction {
        item_idx: usize,
        action: QuickAction,
    },
    CompressImageJpeg(usize),
    MockupImagePng(usize),
    TogglePin(String),
    ToggleTodo(String),
    ArchiveCompletedTodos,
    CopyTodosMarkdown,
    SweepUnpinnedSensitive,
    CreateInlineTodo,
    ClearQueue,
    DeleteItem(String),
    UndoDelete,
    CloseOverlay,
    ToggleQuickLookDiffMode,
    SaveAliasEdit,
    // 内嵌设置页交互热区
    StartRecordHotkey(WinHotKeySlot),
    ResetHotkeyDefault(WinHotKeySlot),
    SetBlurPreset(u8),
    AdjustBlurConcentration {
        track_left: i32,
        track_width: i32,
    },
    ToggleAutoPaste,
    ToggleCopyAppend,
    ToggleDoubleCopySpark,
    ToggleStripRichFormat,
    ToggleAutoCleanUrl,
    ToggleAutoExpireOtp,
    ToggleScreenSharePrivacy,
    ToggleSensitiveVeil,
    ToggleAutoClearConcealed,
    ToggleAutoExpireSecrets,
    ToggleQueueMode,
    ToggleQueueAutoTab,
    ToggleAutostart,
    SelectMaxHistory(usize),
    ExportArchive,
    ImportArchive,
    ClearUnpinnedHistory,
    TogglePauseCapture,
    ShowHighlightsOverlay,
    DismissHighlightsOverlay,
    CheckForUpdates,
    StartOtaDownload,
    CancelOtaDownload,
    ToggleShortcutRef,
    QuitApp,
}

struct DecodedThumb {
    file_name: String,
    width: u32,
    height: u32,
    rgba: Vec<u8>,
}

struct WinAppState {
    store: ClipboardStore,
    visible: bool,
    view_mode: ActiveViewMode,
    theme_pref: ThemePreference,
    is_dark_mode: bool,
    previous_foreground: HWND,
    active_target_app_name: Option<String>,
    ignore_next_clipboard_seq: bool,
    pending_append_capture: bool,
    last_copy_hash: String,
    last_copy_at_ms: u64,
    selected_tab: ClipFilterTab,
    seg_pill_ratio: f32,
    seg_pill_target_ratio: f32,
    selected_pin_category: Option<PinCategory>,
    search_query: String,
    selected_visible_pos: usize,
    scroll_row_offset: usize,
    settings_scroll_px: i32,
    settings_max_scroll_px: i32,
    show_shortcut_ref: bool,
    dragging_slider_track: Option<(i32, i32)>,
    hovered_visible_pos: Option<usize>,
    hovered_link_badge_store_idx: Option<usize>,
    copied_flash_item_id: Option<String>,
    recording_slot: Option<WinHotKeySlot>,
    hotkey_conflict_error: Option<String>,
    hotkey_recording_hint: Option<String>,
    show_quick_look: bool,
    show_highlights_overlay: bool,
    quick_look_diff_mode: bool,
    quick_look_scroll: usize,
    editing_alias_item_id: Option<String>,
    alias_draft: String,
    toast_message: Option<String>,
    hit_regions: Vec<HitRegion>,
    thumb_cache: Vec<DecodedThumb>,
    cf_html_format: u32,
    cf_exclude_monitor: u32,
    cf_viewer_ignore: u32,
    cf_can_include_history: u32,
    cf_can_upload_cloud: u32,
    suppress_deactivate_hide: bool,
    autostart_cached: bool,
    kbd_hook: HHOOK,
    mouse_hook: HHOOK,
    boot_instant: Instant,
    scrub_expected_seq_num: u32,
    double_tap_machine: WinModifierDoubleTapMachine,
    ota_state: OtaState,
    ota_shared: Arc<Mutex<OtaState>>,
    ota_cancel: Arc<AtomicBool>,
}

thread_local! {
    static APP_STATE: RefCell<Option<WinAppState>> = const { RefCell::new(None) };
}

fn to_wide(s: &str) -> Vec<u16> {
    OsString::from(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

fn from_wide_slice(slice: &[u16]) -> String {
    let len = slice.iter().position(|&c| c == 0).unwrap_or(slice.len());
    OsString::from_wide(&slice[..len])
        .to_string_lossy()
        .into_owned()
}

unsafe fn query_windows_system_dark_mode() -> bool {
    let subkey = to_wide("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    let val_name = to_wide("AppsUseLightTheme");
    let mut hkey = null_mut();
    if RegOpenKeyExW(HKEY_CURRENT_USER, subkey.as_ptr(), 0, KEY_READ, &mut hkey) != 0 {
        return false; // 默认采用 macOS 清爽冰晶浅色外观
    }
    let mut data: u32 = 1;
    let mut data_size = size_of::<u32>() as u32;
    let status = RegQueryValueExW(
        hkey,
        val_name.as_ptr(),
        null_mut(),
        null_mut(),
        &mut data as *mut u32 as *mut u8,
        &mut data_size,
    );
    let _ = RegCloseKey(hkey);
    status == 0 && data == 0
}

unsafe fn load_embedded_app_icon(hinstance: HINSTANCE, metric: SYSTEM_METRICS_INDEX) -> HICON {
    let sz = GetSystemMetrics(metric).max(16);
    let h = LoadImageW(hinstance, 1usize as *const u16, IMAGE_ICON, sz, sz, 0) as HICON;
    if !h.is_null() {
        return h;
    }
    let fallback = LoadIconW(hinstance, 1usize as *const u16);
    if !fallback.is_null() {
        return fallback;
    }
    LoadIconW(null_mut(), IDI_APPLICATION)
}

fn strip_self_zone_identifier() {
    if let Ok(exe) = std::env::current_exe() {
        let ads = format!("{}:Zone.Identifier", exe.display());
        let _ = std::fs::remove_file(ads);
    }
}

fn preferred_windows_install_exe() -> Option<std::path::PathBuf> {
    let local_app_data = std::env::var_os("LOCALAPPDATA")?;
    Some(
        std::path::PathBuf::from(local_app_data)
            .join("Programs")
            .join("iClip")
            .join("iClip.exe"),
    )
}

fn is_installed_in_system_dir() -> bool {
    let Ok(cur) = std::env::current_exe() else {
        return true;
    };
    let Some(target) = preferred_windows_install_exe() else {
        return true;
    };
    cur.to_string_lossy()
        .eq_ignore_ascii_case(&target.to_string_lossy())
}

pub fn run_windows_app() -> i32 {
    unsafe {
        strip_self_zone_identifier();
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let hinstance = GetModuleHandleW(null());
        let class_name = to_wide("iClipNativeWindowClass");

        let wc = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS,
            lpfnWndProc: Some(wnd_proc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: hinstance,
            hIcon: load_embedded_app_icon(hinstance, SM_CXICON),
            hCursor: LoadCursorW(null_mut(), IDC_ARROW),
            hbrBackground: null_mut(),
            lpszMenuName: null(),
            lpszClassName: class_name.as_ptr(),
            hIconSm: load_embedded_app_icon(hinstance, SM_CXSMICON),
        };
        RegisterClassExW(&wc);

        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE_VAL,
            class_name.as_ptr(),
            to_wide("iClip").as_ptr(),
            WS_POPUP,
            100,
            100,
            PANEL_BASE_W,
            PANEL_BASE_H,
            null_mut(),
            null_mut(),
            hinstance,
            null(),
        );
        if hwnd.is_null() {
            return 1;
        }
        MAIN_HWND_RAW.store(hwnd as isize, Ordering::SeqCst);

        iclip_core::updater::win_runtime::cleanup_stale_old_binary();
        iclip_core::security::wipe_all_temp_previews();
        let store = ClipboardStore::new(ClipboardStore::default_app_data_dir());
        let init_highlights = !store.config.has_seen_highlights_v27;
        let sys_dark = query_windows_system_dark_mode();
        apply_dwm_glass_style(hwnd, sys_dark, store.config.blur_concentration_pct);
        apply_screen_capture_shield(hwnd, store.config.screen_share_privacy);

        let cf_html = RegisterClipboardFormatW(to_wide("HTML Format").as_ptr());
        let cf_excl = RegisterClipboardFormatW(
            to_wide("ExcludeClipboardContentFromMonitorProcessing").as_ptr(),
        );
        let cf_ignore = RegisterClipboardFormatW(to_wide("Clipboard Viewer Ignore").as_ptr());
        let cf_can_hist =
            RegisterClipboardFormatW(to_wide("CanIncludeInClipboardHistory").as_ptr());
        let cf_can_cloud = RegisterClipboardFormatW(to_wide("CanUploadToCloudClipboard").as_ptr());
        let autostart = is_autostart_enabled();

        APP_STATE.with(|cell| {
            *cell.borrow_mut() = Some(WinAppState {
                store,
                visible: false,
                view_mode: ActiveViewMode::MainList,
                theme_pref: ThemePreference::System,
                is_dark_mode: sys_dark,
                previous_foreground: null_mut(),
                active_target_app_name: None,
                ignore_next_clipboard_seq: false,
                pending_append_capture: false,
                last_copy_hash: String::new(),
                last_copy_at_ms: 0,
                selected_tab: ClipFilterTab::All,
                seg_pill_ratio: 0.0,
                seg_pill_target_ratio: 0.0,
                selected_pin_category: None,
                search_query: String::new(),
                selected_visible_pos: 0,
                scroll_row_offset: 0,
                settings_scroll_px: 0,
                settings_max_scroll_px: 0,
                show_shortcut_ref: false,
                dragging_slider_track: None,
                hovered_visible_pos: None,
                hovered_link_badge_store_idx: None,
                copied_flash_item_id: None,
                recording_slot: None,
                hotkey_conflict_error: None,
                hotkey_recording_hint: None,
                show_quick_look: false,
                show_highlights_overlay: init_highlights,
                quick_look_diff_mode: false,
                quick_look_scroll: 0,
                editing_alias_item_id: None,
                alias_draft: String::new(),
                toast_message: None,
                hit_regions: Vec::new(),
                thumb_cache: Vec::new(),
                cf_html_format: cf_html,
                cf_exclude_monitor: cf_excl,
                cf_viewer_ignore: cf_ignore,
                cf_can_include_history: cf_can_hist,
                cf_can_upload_cloud: cf_can_cloud,
                suppress_deactivate_hide: false,
                autostart_cached: autostart,
                kbd_hook: null_mut(),
                mouse_hook: null_mut(),
                boot_instant: Instant::now(),
                scrub_expected_seq_num: 0,
                double_tap_machine: WinModifierDoubleTapMachine::default(),
                ota_state: OtaState::Idle,
                ota_shared: Arc::new(Mutex::new(OtaState::Idle)),
                ota_cancel: Arc::new(AtomicBool::new(false)),
            });
        });

        let _ = AddClipboardFormatListener(hwnd);
        let _ = WTSRegisterSessionNotification(hwnd, 0);
        reload_global_hotkeys_and_hooks(hwnd);
        SetTimer(hwnd, TIMER_ID_OTP_SWEEP, 5_000, None);
        SetTimer(hwnd, TIMER_ID_SILENT_OTA_CHECK, 4_000, None);
        install_or_update_tray_icon(hwnd, false);

        show_panel_near_cursor(hwnd);

        let mut msg: MSG = zeroed();
        while GetMessageW(&mut msg, null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        uninstall_low_level_hooks();
        remove_tray_icon(hwnd);
        let _ = UnregisterHotKey(hwnd, HOTKEY_ID_TOGGLE);
        let _ = UnregisterHotKey(hwnd, HOTKEY_ID_QUEUE_POP);
        let _ = UnregisterHotKey(hwnd, HOTKEY_ID_COPY_APPEND);
        let _ = WTSUnRegisterSessionNotification(hwnd);
        let _ = RemoveClipboardFormatListener(hwnd);
        MAIN_HWND_RAW.store(0, Ordering::SeqCst);
        0
    }
}

/// 真机自检（含 @2x 浅色/深色主面板、3列图片宫格、分组式设置页 PNG 实拍导出）
pub fn run_windows_self_test() -> Result<(), String> {
    unsafe {
        let t0 = Instant::now();
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let hinstance = GetModuleHandleW(null());
        let embedded_ico = LoadImageW(hinstance, 1usize as *const u16, IMAGE_ICON, 32, 32, 0);
        if embedded_ico.is_null() {
            return Err("Embedded iClip.ico PE resource (ID 1) missing".to_string());
        }
        let class_name = to_wide("iClipSelfTestWindowClass");

        let wc = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(DefWindowProcW),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: hinstance,
            hIcon: null_mut(),
            hCursor: null_mut(),
            hbrBackground: null_mut(),
            lpszMenuName: null(),
            lpszClassName: class_name.as_ptr(),
            hIconSm: null_mut(),
        };
        RegisterClassExW(&wc);

        let hwnd = CreateWindowExW(
            WS_EX_TOOLWINDOW,
            class_name.as_ptr(),
            to_wide("iClipSelfTest").as_ptr(),
            WS_POPUP,
            0,
            0,
            PANEL_BASE_W,
            PANEL_BASE_H,
            null_mut(),
            null_mut(),
            hinstance,
            null(),
        );
        if hwnd.is_null() {
            return Err("CreateWindowExW failed".to_string());
        }
        apply_dwm_glass_style(hwnd, false, 38);

        if AddClipboardFormatListener(hwnd) == FALSE {
            DestroyWindow(hwnd);
            return Err("AddClipboardFormatListener failed".to_string());
        }

        let tmp_dir = std::env::temp_dir().join(format!("iclip-selftest-{}", now_unix_secs()));
        let mut store = ClipboardStore::new(tmp_dir.clone());
        let fin_id = store.insert_or_promote(ClipItem::new_text(
            "公司名称：怀道科技（Webfooo）\n纳税人识别号：91310115MA1K99882X".to_string(),
            Some("WeChat".to_string()),
        ));
        store.set_custom_alias(&fin_id, "上海总公司开票资料");

        let todo_id = store.insert_or_promote(ClipItem::new_text(
            "周五前核对 Windows 与 macOS 双端液态玻璃视觉像素细节".to_string(),
            Some("Feishu".to_string()),
        ));
        let _ = store.toggle_todo(&todo_id);

        store.insert_or_promote(ClipItem::new_text(
            "https://app.webfooo.com/iClip?utm_source=xhs".to_string(),
            Some("Chrome".to_string()),
        ));
        store.insert_or_promote(ClipItem::new_text(
            "| 模块 | 体积 | 待机 CPU |\n| --- | --- | --- |\n| iClip Win | 570 KB | 0.00% |"
                .to_string(),
            Some("Cursor".to_string()),
        ));

        let cf_html = RegisterClipboardFormatW(to_wide("HTML Format").as_ptr());
        let mut state = WinAppState {
            store,
            visible: true,
            view_mode: ActiveViewMode::MainList,
            theme_pref: ThemePreference::Light,
            is_dark_mode: false,
            previous_foreground: null_mut(),
            active_target_app_name: Some("EXCEL".to_string()),
            ignore_next_clipboard_seq: false,
            pending_append_capture: false,
            last_copy_hash: String::new(),
            last_copy_at_ms: 0,
            selected_tab: ClipFilterTab::All,
            seg_pill_ratio: 0.0,
            seg_pill_target_ratio: 0.0,
            selected_pin_category: None,
            search_query: String::new(),
            selected_visible_pos: 0,
            scroll_row_offset: 0,
            settings_scroll_px: 0,
            settings_max_scroll_px: 0,
            show_shortcut_ref: false,
            dragging_slider_track: None,
            hovered_visible_pos: Some(1),
            hovered_link_badge_store_idx: None,
            copied_flash_item_id: None,
            recording_slot: None,
            hotkey_conflict_error: None,
            hotkey_recording_hint: None,
            show_quick_look: false,
            show_highlights_overlay: false,
            quick_look_diff_mode: false,
            quick_look_scroll: 0,
            editing_alias_item_id: None,
            alias_draft: String::new(),
            toast_message: None,
            hit_regions: Vec::new(),
            thumb_cache: Vec::new(),
            cf_html_format: cf_html,
            cf_exclude_monitor: 0,
            cf_viewer_ignore: 0,
            cf_can_include_history: 0,
            cf_can_upload_cloud: 0,
            suppress_deactivate_hide: true,
            autostart_cached: true,
            kbd_hook: null_mut(),
            mouse_hook: null_mut(),
            boot_instant: Instant::now(),
            scrub_expected_seq_num: 0,
            double_tap_machine: WinModifierDoubleTapMachine::default(),
            ota_state: OtaState::UpToDate {
                latest: env!("CARGO_PKG_VERSION").to_string(),
            },
            ota_shared: Arc::new(Mutex::new(OtaState::Idle)),
            ota_cancel: Arc::new(AtomicBool::new(false)),
        };

        // 检测可选截图输出目录（从命令行 `--self-test <json_path>` 推断同级目录）
        let snap_dir: Option<PathBuf> = std::env::args()
            .skip_while(|a| a != "--self-test")
            .nth(1)
            .and_then(|p| Path::new(&p).parent().map(|d| d.to_path_buf()));

        let rw = PANEL_BASE_W * 2;
        let rh = PANEL_BASE_H * 2;
        let screen_dc = GetDC(hwnd);

        // 1) 浅色冰晶液态玻璃主面板 (@2x)
        let light_main = render_to_dib_and_capture(
            screen_dc,
            rw,
            rh,
            2.0,
            &mut state,
            Some(Color4::rgb(226, 234, 246)),
        )?;
        let main_hits = state.hit_regions.len();
        if main_hits < 12 {
            ReleaseDC(hwnd, screen_dc);
            let _ = RemoveClipboardFormatListener(hwnd);
            DestroyWindow(hwnd);
            let _ = std::fs::remove_dir_all(&tmp_dir);
            return Err(format!(
                "Expected main panel hit regions >= 12, got {main_hits}"
            ));
        }
        if let Some(dir) = &snap_dir {
            save_rgba_png(
                &dir.join(format!(
                    "preview-{}-light-main.png",
                    ClipboardStore::edition_key()
                )),
                rw as u32,
                rh as u32,
                &light_main,
            );
        }

        // 2) 深色冷曜石液态玻璃主面板 + 即时速算横幅 + 底部 Toast 胶囊 (@2x)
        state.is_dark_mode = true;
        state.search_query = "= 12800 * 1.06".to_string();
        state.toast_message = Some("已复制并自动剥离营销追踪参数".to_string());
        let dark_main = render_to_dib_and_capture(
            screen_dc,
            rw,
            rh,
            2.0,
            &mut state,
            Some(Color4::rgb(16, 22, 36)),
        )?;
        if let Some(dir) = &snap_dir {
            save_rgba_png(
                &dir.join(format!(
                    "preview-{}-dark-main.png",
                    ClipboardStore::edition_key()
                )),
                rw as u32,
                rh as u32,
                &dark_main,
            );
        }

        // 3) 分组式偏好设置页 + Tahoe 流光色带实景折射预览窗 (@2x 浅色 & 深色)
        state.search_query.clear();
        state.toast_message = None;
        state.is_dark_mode = false;
        state.view_mode = ActiveViewMode::Settings;
        let light_settings = render_to_dib_and_capture(
            screen_dc,
            rw,
            rh,
            2.0,
            &mut state,
            Some(Color4::rgb(226, 234, 246)),
        )?;
        let settings_hits = state.hit_regions.len();
        let has_ota_btn = state
            .hit_regions
            .iter()
            .any(|h| matches!(h.action, HitAction::CheckForUpdates));
        if settings_hits < 8 || !has_ota_btn {
            ReleaseDC(hwnd, screen_dc);
            let _ = RemoveClipboardFormatListener(hwnd);
            DestroyWindow(hwnd);
            let _ = std::fs::remove_dir_all(&tmp_dir);
            return Err(format!(
                "Expected settings hit regions >= 8 with OTA button, got {settings_hits} (has_ota={has_ota_btn})"
            ));
        }
        if let Some(dir) = &snap_dir {
            save_rgba_png(
                &dir.join(format!(
                    "preview-{}-light-settings.png",
                    ClipboardStore::edition_key()
                )),
                rw as u32,
                rh as u32,
                &light_settings,
            );
        }

        state.is_dark_mode = true;
        let dark_settings = render_to_dib_and_capture(
            screen_dc,
            rw,
            rh,
            2.0,
            &mut state,
            Some(Color4::rgb(16, 22, 36)),
        )?;
        if let Some(dir) = &snap_dir {
            save_rgba_png(
                &dir.join(format!(
                    "preview-{}-dark-settings.png",
                    ClipboardStore::edition_key()
                )),
                rw as u32,
                rh as u32,
                &dark_settings,
            );

            // 额外补拍设置页下半屏（验证 Ctrl+E 微键帽与紧凑物理热键录制胶囊）
            state.settings_scroll_px = 180;
            let dark_settings_scrolled = render_to_dib_and_capture(
                screen_dc,
                rw,
                rh,
                2.0,
                &mut state,
                Some(Color4::rgb(16, 22, 36)),
            )?;
            save_rgba_png(
                &dir.join(format!(
                    "preview-{}-dark-settings-scrolled.png",
                    ClipboardStore::edition_key()
                )),
                rw as u32,
                rh as u32,
                &dark_settings_scrolled,
            );
            state.settings_scroll_px = 0;
        }

        ReleaseDC(hwnd, screen_dc);

        if light_main.iter().all(|&b| b == 0) {
            let _ = RemoveClipboardFormatListener(hwnd);
            DestroyWindow(hwnd);
            let _ = std::fs::remove_dir_all(&tmp_dir);
            return Err("Rendered DIB pixels were unexpectedly empty".to_string());
        }

        // 4) 验证真实 Win32 剪贴板写入与回读（UTF-16 文本 + CF_HTML 双协议）
        let test_marker = "iClip-Win32-macOS-Style-v2.4-测试通过";
        let html_payload = iclip_core::engines::build_windows_cf_html_payload(
            "<table><tr><td>OK</td></tr></table>",
        );
        let mut clip_ok = false;
        for _ in 0..5 {
            if write_text_and_html_to_clipboard(hwnd, test_marker, Some((cf_html, &html_payload))) {
                if let Some(read_back) = read_unicode_text_from_clipboard(hwnd) {
                    if read_back == test_marker {
                        clip_ok = true;
                        break;
                    }
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(30));
        }

        let _ = RemoveClipboardFormatListener(hwnd);
        DestroyWindow(hwnd);
        let _ = std::fs::remove_dir_all(&tmp_dir);

        if !clip_ok {
            return Err(
                "Win32 clipboard UTF-16 + CF_HTML roundtrip verification failed".to_string(),
            );
        }

        let elapsed_ms = t0.elapsed().as_secs_f64() * 1000.0;
        println!(
            "{{\"status\":\"PASS\",\"edition\":\"{}\",\"version\":\"{}\",\"main_hit_regions\":{},\"settings_hit_regions\":{},\"startup_and_render_ms\":{:.2}}}",
            ClipboardStore::edition_key(),
            env!("CARGO_PKG_VERSION"),
            main_hits,
            settings_hits,
            elapsed_ms
        );
        Ok(())
    }
}

fn save_rgba_png(path: &Path, w: u32, h: u32, rgba: &[u8]) {
    let mut out = Vec::new();
    if PngEncoder::new(&mut out)
        .write_image(rgba, w, h, ColorType::Rgba8.into())
        .is_ok()
    {
        let _ = std::fs::write(path, out);
    }
}

unsafe fn render_to_dib_and_capture(
    ref_dc: HDC,
    w: i32,
    h: i32,
    scale: f32,
    st: &mut WinAppState,
    wallpaper_sim_bg: Option<Color4>,
) -> Result<Vec<u8>, String> {
    let mem_dc = CreateCompatibleDC(ref_dc);
    let mut bmi: BITMAPINFO = zeroed();
    bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    let mut bits_ptr: *mut core::ffi::c_void = null_mut();
    let hbmp = CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &mut bits_ptr, null_mut(), 0);
    if hbmp.is_null() || bits_ptr.is_null() {
        DeleteDC(mem_dc);
        return Err("CreateDIBSection failed".to_string());
    }
    let old_bmp = SelectObject(mem_dc, hbmp);
    let pixel_count = (w * h) as usize;
    let dib_slice = std::slice::from_raw_parts_mut(bits_ptr as *mut u32, pixel_count);

    render_panel_frame_dib(mem_dc, dib_slice, w, h, scale, st, wallpaper_sim_bg);

    // 反预乘或合成实底导出标准 RGBA PNG 供视觉审阅
    let mut rgba = vec![0u8; pixel_count * 4];
    for (i, &px) in dib_slice.iter().enumerate() {
        let b = (px & 0xFF) as u32;
        let g = ((px >> 8) & 0xFF) as u32;
        let r = ((px >> 16) & 0xFF) as u32;
        let a = ((px >> 24) & 0xFF) as u32;
        if a > 0 && a < 255 {
            rgba[i * 4] = ((r * 255) / a).min(255) as u8;
            rgba[i * 4 + 1] = ((g * 255) / a).min(255) as u8;
            rgba[i * 4 + 2] = ((b * 255) / a).min(255) as u8;
            rgba[i * 4 + 3] = a as u8;
        } else {
            rgba[i * 4] = r as u8;
            rgba[i * 4 + 1] = g as u8;
            rgba[i * 4 + 2] = b as u8;
            rgba[i * 4 + 3] = a as u8;
        }
    }

    SelectObject(mem_dc, old_bmp);
    DeleteObject(hbmp);
    DeleteDC(mem_dc);
    Ok(rgba)
}

unsafe fn apply_dwm_glass_style(hwnd: HWND, is_dark: bool, blur_pct: u8) {
    let dark_val: i32 = if is_dark { 1 } else { 0 };
    let _ = DwmSetWindowAttribute(
        hwnd,
        DWMWA_USE_IMMERSIVE_DARK_MODE_ATTR,
        &dark_val as *const _ as *const _,
        size_of::<i32>() as u32,
    );
    let corner: u32 = DWMWCP_ROUND_VAL;
    let _ = DwmSetWindowAttribute(
        hwnd,
        DWMWA_WINDOW_CORNER_PREFERENCE_ATTR,
        &corner as *const _ as *const _,
        size_of::<u32>() as u32,
    );
    let backdrop: u32 = if blur_pct >= 94 {
        DWMSBT_NONE_VAL
    } else if blur_pct >= 62 {
        DWMSBT_MAINWINDOW_VAL
    } else {
        DWMSBT_TRANSIENTWINDOW_VAL
    };
    let _ = DwmSetWindowAttribute(
        hwnd,
        DWMWA_SYSTEMBACKDROP_TYPE_ATTR,
        &backdrop as *const _ as *const _,
        size_of::<u32>() as u32,
    );
    let margins = MARGINS {
        cxLeftWidth: -1,
        cxRightWidth: -1,
        cyTopHeight: -1,
        cyBottomHeight: -1,
    };
    let _ = DwmExtendFrameIntoClientArea(hwnd, &margins);
}

unsafe fn apply_screen_capture_shield(hwnd: HWND, enabled: bool) {
    let affinity = if enabled {
        WDA_EXCLUDEFROMCAPTURE_AFFINITY
    } else {
        WDA_NONE_AFFINITY
    };
    let _ = SetWindowDisplayAffinity(hwnd, affinity);
}

unsafe fn is_disallowed_by_clipboard_history_flag(hwnd: HWND, cf_can_include: u32) -> bool {
    if cf_can_include == 0 || IsClipboardFormatAvailable(cf_can_include) == FALSE {
        return false;
    }
    if OpenClipboard(hwnd) == FALSE {
        return false;
    }
    let mut disallowed = false;
    let hdata = GetClipboardData(cf_can_include);
    if !hdata.is_null() {
        let ptr = GlobalLock(hdata) as *const u32;
        if !ptr.is_null() {
            if GlobalSize(hdata) >= 4 && *ptr == 0 {
                disallowed = true;
            }
            let _ = GlobalUnlock(hdata);
        }
    }
    let _ = CloseClipboard();
    disallowed
}

unsafe fn get_dpi_scale(hwnd: HWND) -> f32 {
    let dpi = GetDpiForWindow(hwnd);
    if dpi == 0 {
        1.0
    } else {
        (dpi as f32 / 96.0).clamp(1.0, 3.0)
    }
}

unsafe fn sync_effective_theme(hwnd: HWND) {
    let sys_dark = query_windows_system_dark_mode();
    let mut changed = false;
    let mut cur_dark = sys_dark;
    let mut blur_pct = 38u8;
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            let next = match st.theme_pref {
                ThemePreference::System => sys_dark,
                ThemePreference::Light => false,
                ThemePreference::Dark => true,
            };
            blur_pct = st.store.config.blur_concentration_pct;
            if st.is_dark_mode != next {
                st.is_dark_mode = next;
                changed = true;
            }
            cur_dark = st.is_dark_mode;
        }
    });
    if changed {
        apply_dwm_glass_style(hwnd, cur_dark, blur_pct);
        let _ = InvalidateRect(hwnd, null(), FALSE);
    }
}

unsafe fn start_tab_spring_to(hwnd: HWND, next_tab: ClipFilterTab) {
    let mut need_timer = false;
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            st.selected_tab = next_tab;
            st.selected_visible_pos = 0;
            st.scroll_row_offset = 0;
            let tabs = ClipFilterTab::visible_tabs(st.store.config.minimal_mode_enabled);
            let idx = tabs.iter().position(|&t| t == next_tab).unwrap_or(0);
            st.seg_pill_target_ratio = idx as f32;
            if (st.seg_pill_target_ratio - st.seg_pill_ratio).abs() > 0.01 {
                need_timer = true;
            } else {
                st.seg_pill_ratio = st.seg_pill_target_ratio;
            }
        }
    });
    if need_timer {
        SetTimer(hwnd, TIMER_ID_SPRING_ANIM, 8, None);
    }
    let _ = InvalidateRect(hwnd, null(), FALSE);
}

// ============================================================================
// 全局快捷键热重载、Win32 排他冲突实测与按需低级键鼠双击钩子
// ============================================================================

fn win32_mod_flags(mods: u32) -> u32 {
    let mut out = MOD_NOREPEAT;
    if (mods & MOD_ALT_BITS) != 0 {
        out |= 0x0001;
    }
    if (mods & MOD_CONTROL_BITS) != 0 {
        out |= 0x0002;
    }
    if (mods & MOD_SHIFT_BITS) != 0 {
        out |= 0x0004;
    }
    if (mods & MOD_WIN_BITS) != 0 {
        out |= 0x0008;
    }
    out
}

unsafe fn reload_global_hotkeys_and_hooks(hwnd: HWND) {
    let _ = UnregisterHotKey(hwnd, HOTKEY_ID_TOGGLE);
    let _ = UnregisterHotKey(hwnd, HOTKEY_ID_QUEUE_POP);
    let _ = UnregisterHotKey(hwnd, HOTKEY_ID_COPY_APPEND);

    let (hk_toggle, hk_queue, append_on, recording, is_visible) = APP_STATE.with(|c| {
        let b = c.borrow();
        let st = b.as_ref().unwrap();
        (
            st.store.config.hotkey_toggle.clone(),
            st.store.config.hotkey_queue_pop.clone(),
            st.store.config.copy_append_enabled,
            st.recording_slot.is_some(),
            st.visible,
        )
    });

    if !hk_toggle.is_double_tap() {
        let _ = RegisterHotKey(
            hwnd,
            HOTKEY_ID_TOGGLE,
            win32_mod_flags(hk_toggle.modifiers),
            hk_toggle.vk,
        );
    }
    if !hk_queue.is_double_tap() {
        let _ = RegisterHotKey(
            hwnd,
            HOTKEY_ID_QUEUE_POP,
            win32_mod_flags(hk_queue.modifiers),
            hk_queue.vk,
        );
    }
    if append_on {
        let hk_append = WinHotKeyShortcut::default_copy_append();
        if hk_append != hk_toggle && hk_append != hk_queue {
            let _ = RegisterHotKey(
                hwnd,
                HOTKEY_ID_COPY_APPEND,
                win32_mod_flags(hk_append.modifiers),
                hk_append.vk,
            );
        }
    }

    let need_hooks =
        hk_toggle.is_double_tap() || hk_queue.is_double_tap() || recording || is_visible;
    if need_hooks {
        install_low_level_hooks_if_needed();
    } else {
        uninstall_low_level_hooks();
    }
    install_or_update_tray_icon(hwnd, true);
}

unsafe fn validate_candidate_hotkey(
    hwnd: HWND,
    slot: WinHotKeySlot,
    candidate: &WinHotKeyShortcut,
) -> Option<String> {
    let (own, other_hk, other_label, append_on) = APP_STATE.with(|c| {
        let b = c.borrow();
        let st = b.as_ref().unwrap();
        match slot {
            WinHotKeySlot::MainToggle => (
                st.store.config.hotkey_toggle.clone(),
                st.store.config.hotkey_queue_pop.clone(),
                "顺序出队热键",
                st.store.config.copy_append_enabled,
            ),
            WinHotKeySlot::QueuePop | WinHotKeySlot::CopyAppend => (
                st.store.config.hotkey_queue_pop.clone(),
                st.store.config.hotkey_toggle.clone(),
                "面板呼出热键",
                st.store.config.copy_append_enabled,
            ),
        }
    });

    let append_hk = WinHotKeyShortcut::default_copy_append();
    let mut others: Vec<(&WinHotKeyShortcut, &str)> = vec![(&other_hk, other_label)];
    if append_on {
        others.push((&append_hk, "跨处续接复制 (Ctrl+Alt+C)"));
    }

    if let Some(reason) = static_hotkey_conflict_reason(candidate, slot, &own, &others) {
        return Some(reason);
    }

    if candidate == &own || candidate.is_double_tap() {
        return None;
    }

    let ok = RegisterHotKey(
        hwnd,
        HOTKEY_ID_PROBE,
        win32_mod_flags(candidate.modifiers),
        candidate.vk,
    ) != FALSE;
    if ok {
        let _ = UnregisterHotKey(hwnd, HOTKEY_ID_PROBE);
        None
    } else {
        Some(format!(
            "「{}」已被系统或其他软件占用，禁止设定",
            candidate.display_string()
        ))
    }
}

unsafe fn install_low_level_hooks_if_needed() {
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            let hmod = GetModuleHandleW(null());
            if st.kbd_hook.is_null() {
                st.kbd_hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(ll_kbd_proc), hmod, 0);
            }
            if st.mouse_hook.is_null() {
                st.mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, Some(ll_mouse_proc), hmod, 0);
            }
        }
    });
}

unsafe fn uninstall_low_level_hooks() {
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            if !st.kbd_hook.is_null() {
                let _ = UnhookWindowsHookEx(st.kbd_hook);
                st.kbd_hook = null_mut();
            }
            if !st.mouse_hook.is_null() {
                let _ = UnhookWindowsHookEx(st.mouse_hook);
                st.mouse_hook = null_mut();
            }
            st.double_tap_machine.reset();
        }
    });
}

fn current_async_mod_bits_excluding(released_vk: Option<u32>) -> u32 {
    unsafe {
        let is_down = |vks: &[i32]| -> bool {
            vks.iter().any(|&vk| {
                if released_vk == Some(vk as u32) {
                    false
                } else {
                    (GetKeyState(vk) as u16 & 0x8000) != 0
                }
            })
        };
        let mut bits = 0u32;
        if is_down(&[0xA2, 0xA3, VK_CONTROL as i32]) {
            bits |= MOD_CONTROL_BITS;
        }
        if is_down(&[0xA4, 0xA5, VK_MENU as i32]) {
            bits |= MOD_ALT_BITS;
        }
        if is_down(&[0xA0, 0xA1, VK_SHIFT as i32]) {
            bits |= MOD_SHIFT_BITS;
        }
        if is_down(&[0x5B, 0x5C]) {
            bits |= MOD_WIN_BITS;
        }
        bits
    }
}

unsafe extern "system" fn ll_kbd_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 && lparam != 0 {
        let kb = &*(lparam as *const KBDLLHOOKSTRUCT);
        if (kb.flags & 0x10) == 0 {
            let msg = wparam as u32;
            let is_down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
            let is_up = msg == WM_KEYUP || msg == WM_SYSKEYUP;
            if is_down || is_up {
                let vk = kb.vkCode;
                let mut triggered: Option<WinSingleModifier> = None;
                let mut first_tap_hint: Option<WinSingleModifier> = None;

                APP_STATE.with(|c| {
                    if let Some(st) = c.borrow_mut().as_mut() {
                        let now_ms = st.boot_instant.elapsed().as_millis() as u64;
                        if WinSingleModifier::from_vk(vk).is_some() {
                            let mod_bits = if is_up {
                                current_async_mod_bits_excluding(Some(vk))
                            } else {
                                current_async_mod_bits_excluding(None)
                            };
                            match st
                                .double_tap_machine
                                .handle_modifier_transition(vk, is_down, mod_bits, now_ms)
                            {
                                DoubleTapOutcome::DoubleTapTriggered(kind) => {
                                    triggered = Some(kind);
                                }
                                DoubleTapOutcome::FirstTapCompleted(kind) => {
                                    if st.recording_slot.is_some() {
                                        first_tap_hint = Some(kind);
                                    }
                                }
                                DoubleTapOutcome::None => {}
                            }
                        } else if is_down {
                            st.double_tap_machine.mark_interfering_event();
                        }
                    }
                });

                let hwnd = MAIN_HWND_RAW.load(Ordering::SeqCst) as HWND;
                if !hwnd.is_null() {
                    if let Some(kind) = triggered {
                        let code_val = match kind {
                            WinSingleModifier::Control => 1usize,
                            WinSingleModifier::Alt => 2usize,
                            WinSingleModifier::Shift => 3usize,
                            WinSingleModifier::Win => 4usize,
                        };
                        let _ = PostMessageW(hwnd, WM_APP_DOUBLETAP, code_val, 1);
                    } else if let Some(kind) = first_tap_hint {
                        let code_val = match kind {
                            WinSingleModifier::Control => 1usize,
                            WinSingleModifier::Alt => 2usize,
                            WinSingleModifier::Shift => 3usize,
                            WinSingleModifier::Win => 4usize,
                        };
                        let _ = PostMessageW(hwnd, WM_APP_DOUBLETAP, code_val, 0);
                    } else if is_down && GetForegroundWindow() != hwnd {
                        let mod_bits = current_async_mod_bits_excluding(None);
                        let route = APP_STATE.with(|c| {
                            let b = c.borrow();
                            let Some(st) = b.as_ref() else {
                                return NonActiveKeyRoute::PassThrough;
                            };
                            if !st.visible {
                                return NonActiveKeyRoute::PassThrough;
                            }
                            let cur_combo = WinHotKeyShortcut::combo(vk, mod_bits);
                            if st.recording_slot.is_none()
                                && ((!st.store.config.hotkey_toggle.is_double_tap()
                                    && cur_combo == st.store.config.hotkey_toggle)
                                    || (!st.store.config.hotkey_queue_pop.is_double_tap()
                                        && cur_combo == st.store.config.hotkey_queue_pop))
                            {
                                return NonActiveKeyRoute::PassThrough;
                            }
                            classify_non_active_panel_key(
                                vk,
                                mod_bits,
                                st.view_mode == ActiveViewMode::MainList,
                                st.show_quick_look,
                                st.recording_slot.is_some(),
                            )
                        });
                        match route {
                            NonActiveKeyRoute::PassThrough => {}
                            NonActiveKeyRoute::DispatchPanelCommand => {
                                let _ = PostMessageW(hwnd, WM_APP_PANEL_KEY, vk as usize, 0);
                                return 1;
                            }
                            NonActiveKeyRoute::ActivateAndTypeChar(ch) => {
                                let _ = PostMessageW(hwnd, WM_APP_PANEL_TYPE_CHAR, ch as usize, 0);
                                return 1;
                            }
                        }
                    }
                }
            }
        }
    }
    CallNextHookEx(null_mut(), code, wparam, lparam)
}

unsafe extern "system" fn ll_mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let m = wparam as u32;
        if matches!(
            m,
            WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN | WM_MOUSEWHEEL
        ) {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.double_tap_machine.mark_interfering_event();
                }
            });
        }
        if matches!(m, WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN) && lparam != 0 {
            let hwnd = MAIN_HWND_RAW.load(Ordering::SeqCst) as HWND;
            if !hwnd.is_null() {
                let should_check = APP_STATE.with(|c| {
                    c.borrow()
                        .as_ref()
                        .map(|s| {
                            s.visible
                                && !s.store.config.always_on_top
                                && !s.suppress_deactivate_hide
                                && s.recording_slot.is_none()
                        })
                        .unwrap_or(false)
                });
                if should_check {
                    let ms = &*(lparam as *const MSLLHOOKSTRUCT);
                    let mut rc: RECT = zeroed();
                    if GetWindowRect(hwnd, &mut rc) != FALSE
                        && (ms.pt.x < rc.left
                            || ms.pt.x >= rc.right
                            || ms.pt.y < rc.top
                            || ms.pt.y >= rc.bottom)
                    {
                        let _ = PostMessageW(hwnd, WM_APP_OUTSIDE_CLICK, 0, 0);
                    }
                }
            }
        }
    }
    CallNextHookEx(null_mut(), code, wparam, lparam)
}

unsafe fn handle_double_tap_message(hwnd: HWND, mod_code: usize, is_completed_double: isize) {
    let kind = match mod_code {
        1 => WinSingleModifier::Control,
        2 => WinSingleModifier::Alt,
        3 => WinSingleModifier::Shift,
        4 => WinSingleModifier::Win,
        _ => return,
    };

    if is_completed_double == 0 {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                if st.recording_slot.is_some() {
                    st.hotkey_recording_hint = Some(format!(
                        "已捕获第 1 次 {}，请再按一次完成「双击 {}」设定",
                        kind.label(),
                        kind.label()
                    ));
                    st.hotkey_conflict_error = None;
                }
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
        return;
    }

    let active_slot = APP_STATE.with(|c| c.borrow().as_ref().and_then(|s| s.recording_slot));
    if let Some(slot) = active_slot {
        let candidate = WinHotKeyShortcut::double_tap(kind);
        apply_recorded_hotkey_candidate(hwnd, slot, candidate);
        return;
    }

    let (match_toggle, match_queue) = APP_STATE.with(|c| {
        let b = c.borrow();
        let Some(st) = b.as_ref() else {
            return (false, false);
        };
        (
            st.store.config.hotkey_toggle.double_tap == Some(kind),
            st.store.config.hotkey_queue_pop.double_tap == Some(kind),
        )
    });

    if match_toggle {
        let is_vis = APP_STATE.with(|c| c.borrow().as_ref().map(|s| s.visible).unwrap_or(false));
        if is_vis {
            hide_panel(hwnd, true);
        } else {
            show_panel_near_cursor(hwnd);
        }
    } else if match_queue {
        handle_queue_pop_shortcut(hwnd);
    }
}

unsafe fn apply_recorded_hotkey_candidate(
    hwnd: HWND,
    slot: WinHotKeySlot,
    candidate: WinHotKeyShortcut,
) {
    if let Some(conflict_msg) = validate_candidate_hotkey(hwnd, slot, &candidate) {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.hotkey_conflict_error = Some(conflict_msg);
                st.hotkey_recording_hint = None;
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
        return;
    }

    let disp = candidate.display_string();
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            match slot {
                WinHotKeySlot::MainToggle => st.store.config.hotkey_toggle = candidate,
                WinHotKeySlot::QueuePop | WinHotKeySlot::CopyAppend => {
                    st.store.config.hotkey_queue_pop = candidate
                }
            }
            st.store.save_config();
            st.recording_slot = None;
            st.hotkey_conflict_error = None;
            st.hotkey_recording_hint = None;
        }
    });
    reload_global_hotkeys_and_hooks(hwnd);
    set_toast(hwnd, format!("快捷键已更新为 {disp}"));
}

// ============================================================================
// 面板显示定位与窗口消息分发
// ============================================================================

unsafe fn show_panel_near_cursor(hwnd: HWND) {
    sync_effective_theme(hwnd);
    let prev_fg = GetForegroundWindow();
    let fg_app = if prev_fg != hwnd && !prev_fg.is_null() {
        query_process_name_from_hwnd(prev_fg)
    } else {
        None
    };

    let scale = get_dpi_scale(hwnd);
    let win_w = ((PANEL_BASE_W as f32) * scale).round() as i32;
    let win_h = ((PANEL_BASE_H as f32) * scale).round() as i32;

    let saved_pin_pos = APP_STATE.with(|c| {
        c.borrow().as_ref().and_then(|s| {
            if s.store.config.always_on_top {
                s.store.config.pinned_panel_pos
            } else {
                None
            }
        })
    });

    let mut pt = POINT { x: 240, y: 240 };
    if let Some((px, py)) = saved_pin_pos {
        pt.x = px;
        pt.y = py;
    } else {
        let _ = GetCursorPos(&mut pt);
    }

    let hmon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    let mut mi: MONITORINFO = zeroed();
    mi.cbSize = size_of::<MONITORINFO>() as u32;
    let (work_l, work_t, work_r, work_b) = if GetMonitorInfoW(hmon, &mut mi) != FALSE {
        (
            mi.rcWork.left,
            mi.rcWork.top,
            mi.rcWork.right,
            mi.rcWork.bottom,
        )
    } else {
        (0, 0, 1920, 1040)
    };

    let (x, y) = if let Some((px, py)) = saved_pin_pos {
        (
            px.clamp(work_l + 8, (work_r - win_w - 8).max(work_l + 8)),
            py.clamp(work_t + 8, (work_b - win_h - 8).max(work_t + 8)),
        )
    } else {
        let gap = (14.0 * scale).round() as i32;
        let mut nx = if pt.x + gap + win_w <= work_r - 10 {
            pt.x + gap
        } else {
            pt.x - gap - win_w
        };
        nx = nx.clamp(work_l + 10, (work_r - win_w - 10).max(work_l + 10));
        let mut ny = pt.y - (46.0 * scale).round() as i32;
        ny = ny.clamp(work_t + 10, (work_b - win_h - 10).max(work_t + 10));
        (nx, ny)
    };

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            if prev_fg != hwnd && !prev_fg.is_null() {
                st.previous_foreground = prev_fg;
                if fg_app.is_some() {
                    st.active_target_app_name = fg_app;
                }
            }
            st.visible = true;
            st.view_mode = ActiveViewMode::MainList;
            st.search_query.clear();
            st.selected_visible_pos = 0;
            st.scroll_row_offset = 0;
            st.show_quick_look = false;
            st.editing_alias_item_id = None;
            st.recording_slot = None;
            st.hotkey_conflict_error = None;
            st.hotkey_recording_hint = None;
            st.dragging_slider_track = None;
            st.autostart_cached = is_autostart_enabled();
            let tabs = ClipFilterTab::visible_tabs(st.store.config.minimal_mode_enabled);
            let idx = tabs.iter().position(|&t| t == st.selected_tab).unwrap_or(0);
            st.seg_pill_ratio = idx as f32;
            st.seg_pill_target_ratio = idx as f32;
        }
    });

    SetWindowPos(
        hwnd,
        HWND_TOPMOST,
        x,
        y,
        win_w,
        win_h,
        SWP_NOACTIVATE_VAL | SWP_SHOWWINDOW,
    );
    reload_global_hotkeys_and_hooks(hwnd);
    let _ = InvalidateRect(hwnd, null(), FALSE);
}

unsafe fn activate_panel_for_input(hwnd: HWND) {
    let _ = SetForegroundWindow(hwnd);
    let _ = SetFocus(hwnd);
}

unsafe fn restore_target_foreground_if_needed(target_fg: HWND) {
    if !target_fg.is_null() && IsWindow(target_fg) != FALSE {
        let cur_fg = GetForegroundWindow();
        if should_restore_foreground_window(cur_fg as isize, target_fg as isize) {
            let _ = SetForegroundWindow(target_fg);
        }
    }
}

unsafe fn hide_panel(hwnd: HWND, restore_focus: bool) {
    let mut target_fg: HWND = null_mut();
    KillTimer(hwnd, TIMER_ID_SPRING_ANIM);
    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            st.visible = false;
            st.hovered_visible_pos = None;
            st.hovered_link_badge_store_idx = None;
            st.dragging_slider_track = None;
            st.show_quick_look = false;
            st.editing_alias_item_id = None;
            if st.recording_slot.is_some() {
                st.recording_slot = None;
                st.hotkey_conflict_error = None;
                st.hotkey_recording_hint = None;
            }
            if restore_focus {
                target_fg = st.previous_foreground;
            }
        }
    });
    reload_global_hotkeys_and_hooks(hwnd);
    iclip_core::security::wipe_all_temp_previews();
    ShowWindow(hwnd, SW_HIDE);
    if restore_focus {
        restore_target_foreground_if_needed(target_fg);
    }
}

unsafe fn set_toast(hwnd: HWND, msg: String) {
    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            st.toast_message = Some(msg);
        }
    });
    SetTimer(hwnd, TIMER_ID_TOAST_CLEAR, 2_200, None);
    let _ = InvalidateRect(hwnd, null(), FALSE);
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_CLIPBOARDUPDATE_MSG => {
            handle_clipboard_update(hwnd);
            0
        }
        WM_WTSSESSION_CHANGE_MSG => {
            if wparam == WTS_SESSION_LOCK_VAL {
                iclip_core::security::wipe_all_temp_previews();
                APP_STATE.with(|c| {
                    if let Some(st) = c.borrow_mut().as_mut() {
                        st.store.lock_down_ephemeral_buffers();
                        st.search_query.clear();
                        st.show_quick_look = false;
                        st.editing_alias_item_id = None;
                        st.alias_draft.clear();
                    }
                });
                hide_panel(hwnd, false);
            }
            0
        }
        WM_POWERBROADCAST_MSG => {
            if wparam == PBT_APMSUSPEND_VAL {
                iclip_core::security::wipe_all_temp_previews();
                APP_STATE.with(|c| {
                    if let Some(st) = c.borrow_mut().as_mut() {
                        st.store.lock_down_ephemeral_buffers();
                        st.search_query.clear();
                        st.show_quick_look = false;
                        st.editing_alias_item_id = None;
                        st.alias_draft.clear();
                    }
                });
                hide_panel(hwnd, false);
            }
            0
        }
        WM_SETTINGCHANGE => {
            sync_effective_theme(hwnd);
            0
        }
        WM_HOTKEY => {
            let id = wparam as i32;
            if id == HOTKEY_ID_TOGGLE {
                let is_vis =
                    APP_STATE.with(|c| c.borrow().as_ref().map(|s| s.visible).unwrap_or(false));
                if is_vis {
                    hide_panel(hwnd, true);
                } else {
                    show_panel_near_cursor(hwnd);
                }
            } else if id == HOTKEY_ID_QUEUE_POP {
                handle_queue_pop_shortcut(hwnd);
            } else if id == HOTKEY_ID_COPY_APPEND {
                trigger_global_copy_append(hwnd);
            }
            0
        }
        WM_APP_DOUBLETAP => {
            handle_double_tap_message(hwnd, wparam, lparam);
            0
        }
        WM_MOUSEACTIVATE_MSG => MA_NOACTIVATE_RES,
        WM_APP_PANEL_KEY => {
            let vk = wparam as u32;
            let ctrl_down = (GetKeyState(VK_CONTROL as i32) as u16 & 0x8000) != 0;
            if vk == VK_BACK as u32 && !ctrl_down {
                handle_char_input(hwnd, VK_BACK as u32);
            } else if vk == 0x46 && ctrl_down {
                activate_panel_for_input(hwnd);
            } else {
                handle_key_down(hwnd, vk);
                let entered_alias = APP_STATE.with(|c| {
                    c.borrow()
                        .as_ref()
                        .map(|s| s.editing_alias_item_id.is_some())
                        .unwrap_or(false)
                });
                if entered_alias {
                    activate_panel_for_input(hwnd);
                }
            }
            0
        }
        WM_APP_PANEL_TYPE_CHAR => {
            activate_panel_for_input(hwnd);
            handle_char_input(hwnd, wparam as u32);
            0
        }
        WM_APP_OUTSIDE_CLICK => {
            let should_hide = APP_STATE.with(|c| {
                c.borrow()
                    .as_ref()
                    .map(|s| {
                        s.visible
                            && !s.store.config.always_on_top
                            && !s.suppress_deactivate_hide
                            && s.recording_slot.is_none()
                    })
                    .unwrap_or(false)
            });
            if should_hide {
                hide_panel(hwnd, false);
            }
            0
        }
        WM_APP_OTA_STATE => {
            let notify_toast: Option<String> = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let Some(st) = b.as_mut() else { return None };
                let latest_state = st
                    .ota_shared
                    .lock()
                    .map(|g| g.clone())
                    .unwrap_or(OtaState::Idle);
                let prev_was_checking = matches!(st.ota_state, OtaState::Checking);
                let silent = wparam != 0;
                st.ota_state = latest_state.clone();
                if silent {
                    None
                } else {
                    match latest_state {
                        OtaState::Available(info) => Some(format!(
                            "发现新版本 v{}，点击「立即更新」秒装",
                            info.version
                        )),
                        OtaState::UpToDate { latest } if prev_was_checking => {
                            Some(format!("当前已是最新版本 v{latest}"))
                        }
                        OtaState::Failed(msg) => Some(msg),
                        _ => None,
                    }
                }
            });
            if let Some(msg) = notify_toast {
                set_toast(hwnd, msg);
            } else {
                let _ = InvalidateRect(hwnd, null(), FALSE);
            }
            0
        }
        WM_APP_OTA_RESTART => {
            DestroyWindow(hwnd);
            0
        }
        WM_TIMER => {
            if wparam == TIMER_ID_SPRING_ANIM {
                let mut stop = true;
                APP_STATE.with(|c| {
                    if let Some(st) = c.borrow_mut().as_mut() {
                        let diff = st.seg_pill_target_ratio - st.seg_pill_ratio;
                        if diff.abs() > 0.008 {
                            st.seg_pill_ratio += diff * 0.36;
                            stop = false;
                        } else {
                            st.seg_pill_ratio = st.seg_pill_target_ratio;
                        }
                    }
                });
                if stop {
                    KillTimer(hwnd, TIMER_ID_SPRING_ANIM);
                }
                let _ = InvalidateRect(hwnd, null(), FALSE);
            } else if wparam == TIMER_ID_OTP_SWEEP {
                let changed = APP_STATE.with(|c| {
                    c.borrow_mut()
                        .as_mut()
                        .map(|s| {
                            let n = now_unix_secs();
                            let auto_resumed = s.store.check_auto_resume_pause(n);
                            let cnt = s.store.sweep_expired_otps(n)
                                + s.store.archive_expired_completed_todos(n);
                            if cnt > 0 && s.show_quick_look {
                                s.show_quick_look = false;
                            }
                            cnt > 0 || auto_resumed
                        })
                        .unwrap_or(false)
                });
                if changed {
                    let _ = InvalidateRect(hwnd, null(), FALSE);
                }
            } else if wparam == TIMER_ID_TOAST_CLEAR {
                KillTimer(hwnd, TIMER_ID_TOAST_CLEAR);
                APP_STATE.with(|c| {
                    if let Some(s) = c.borrow_mut().as_mut() {
                        s.toast_message = None;
                    }
                });
                let _ = InvalidateRect(hwnd, null(), FALSE);
            } else if wparam == TIMER_ID_COPY_FLASH_CLEAR {
                KillTimer(hwnd, TIMER_ID_COPY_FLASH_CLEAR);
                APP_STATE.with(|c| {
                    if let Some(s) = c.borrow_mut().as_mut() {
                        s.copied_flash_item_id = None;
                    }
                });
                let _ = InvalidateRect(hwnd, null(), FALSE);
            } else if wparam == TIMER_ID_DEFERRED_APPEND {
                KillTimer(hwnd, TIMER_ID_DEFERRED_APPEND);
                simulate_ctrl_c();
            } else if wparam == TIMER_ID_CONCEALED_SCRUB {
                KillTimer(hwnd, TIMER_ID_CONCEALED_SCRUB);
                let cur_seq = GetClipboardSequenceNumber();
                let do_scrub = APP_STATE.with(|c| {
                    let mut b = c.borrow_mut();
                    let Some(st) = b.as_mut() else { return false };
                    if st.store.config.auto_clear_concealed_clipboard
                        && st.scrub_expected_seq_num != 0
                        && cur_seq == st.scrub_expected_seq_num
                    {
                        st.scrub_expected_seq_num = 0;
                        st.ignore_next_clipboard_seq = true;
                        true
                    } else {
                        false
                    }
                });
                if do_scrub && OpenClipboard(hwnd) != FALSE {
                    let _ = EmptyClipboard();
                    let _ = CloseClipboard();
                }
            } else if wparam == TIMER_ID_SILENT_OTA_CHECK {
                KillTimer(hwnd, TIMER_ID_SILENT_OTA_CHECK);
                trigger_ota_check(hwnd, true);
            }
            0
        }
        WM_ACTIVATE => {
            let active_state = (wparam & 0xFFFF) as u32;
            if active_state == WA_INACTIVE {
                let keep_open = APP_STATE.with(|c| {
                    c.borrow()
                        .as_ref()
                        .map(|s| s.suppress_deactivate_hide || s.store.config.always_on_top)
                        .unwrap_or(false)
                });
                if !keep_open {
                    hide_panel(hwnd, false);
                } else {
                    let fg = GetForegroundWindow();
                    if !fg.is_null() && fg != hwnd {
                        let app = query_process_name_from_hwnd(fg);
                        APP_STATE.with(|c| {
                            if let Some(st) = c.borrow_mut().as_mut() {
                                st.previous_foreground = fg;
                                if app.is_some() {
                                    st.active_target_app_name = app;
                                }
                            }
                        });
                    }
                }
            }
            0
        }
        WM_EXITSIZEMOVE => {
            let mut rc: RECT = zeroed();
            if GetWindowRect(hwnd, &mut rc) != FALSE {
                APP_STATE.with(|c| {
                    if let Some(st) = c.borrow_mut().as_mut() {
                        if st.store.config.always_on_top {
                            st.store.config.pinned_panel_pos = Some((rc.left, rc.top));
                            st.store.save_config();
                        }
                    }
                });
            }
            0
        }
        WM_ERASEBKGND => 1,
        WM_PAINT => {
            let mut ps: PAINTSTRUCT = zeroed();
            let hdc = BeginPaint(hwnd, &mut ps);
            let mut rc: RECT = zeroed();
            GetClientRect(hwnd, &mut rc);
            let w = (rc.right - rc.left).max(1);
            let h = (rc.bottom - rc.top).max(1);
            let scale = get_dpi_scale(hwnd);

            let mem_dc = CreateCompatibleDC(hdc);
            let mut bmi: BITMAPINFO = zeroed();
            bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
            bmi.bmiHeader.biWidth = w;
            bmi.bmiHeader.biHeight = -h;
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = BI_RGB;

            let mut bits_ptr: *mut core::ffi::c_void = null_mut();
            let hbmp = CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &mut bits_ptr, null_mut(), 0);
            if !hbmp.is_null() && !bits_ptr.is_null() {
                let old_bmp = SelectObject(mem_dc, hbmp);
                let dib_slice =
                    std::slice::from_raw_parts_mut(bits_ptr as *mut u32, (w * h) as usize);

                APP_STATE.with(|cell| {
                    if let Some(st) = cell.borrow_mut().as_mut() {
                        render_panel_frame_dib(mem_dc, dib_slice, w, h, scale, st, None);
                    }
                });

                let _ = BitBlt(hdc, 0, 0, w, h, mem_dc, 0, 0, SRCCOPY);
                SelectObject(mem_dc, old_bmp);
                DeleteObject(hbmp);
            }
            DeleteDC(mem_dc);
            EndPaint(hwnd, &ps);
            0
        }
        WM_MOUSEMOVE => {
            let x = (lparam & 0xFFFF) as i16 as i32;
            let y = ((lparam >> 16) & 0xFFFF) as i16 as i32;
            let left_held = (wparam & 0x0001) != 0;
            handle_mouse_move(hwnd, x, y, left_held);
            0
        }
        WM_LBUTTONUP => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.dragging_slider_track = None;
                }
            });
            0
        }
        WM_LBUTTONDOWN => {
            let x = (lparam & 0xFFFF) as i16 as i32;
            let y = ((lparam >> 16) & 0xFFFF) as i16 as i32;
            handle_left_click(hwnd, x, y, false);
            0
        }
        WM_LBUTTONDBLCLK => {
            let x = (lparam & 0xFFFF) as i16 as i32;
            let y = ((lparam >> 16) & 0xFFFF) as i16 as i32;
            handle_left_click(hwnd, x, y, true);
            0
        }
        WM_MOUSEWHEEL => {
            let delta = ((wparam >> 16) & 0xFFFF) as i16;
            APP_STATE.with(|cell| {
                if let Some(st) = cell.borrow_mut().as_mut() {
                    if st.show_quick_look {
                        if delta < 0 {
                            st.quick_look_scroll = st.quick_look_scroll.saturating_add(3);
                        } else if delta > 0 {
                            st.quick_look_scroll = st.quick_look_scroll.saturating_sub(3);
                        }
                    } else if st.view_mode == ActiveViewMode::Settings {
                        let step = 48;
                        if delta < 0 {
                            st.settings_scroll_px =
                                (st.settings_scroll_px + step).min(st.settings_max_scroll_px);
                        } else if delta > 0 {
                            st.settings_scroll_px = (st.settings_scroll_px - step).max(0);
                        }
                    } else {
                        let filtered = st.store.filtered_indices_ext(
                            st.selected_tab,
                            st.selected_pin_category,
                            &st.search_query,
                            st.active_target_app_name.as_deref(),
                        );
                        let rows = build_display_rows_ext(
                            &filtered,
                            &st.store.items,
                            st.selected_tab != ClipFilterTab::Todo,
                        );
                        if delta < 0 && st.scroll_row_offset + 3 < rows.len() {
                            st.scroll_row_offset += 1;
                        } else if delta > 0 && st.scroll_row_offset > 0 {
                            st.scroll_row_offset -= 1;
                        }
                    }
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
            0
        }
        WM_KEYDOWN | WM_SYSKEYDOWN => {
            handle_key_down(hwnd, wparam as u32);
            0
        }
        WM_CHAR => {
            handle_char_input(hwnd, wparam as u32);
            0
        }
        WM_TRAYICON => {
            let mouse_msg = (lparam & 0xFFFF) as u32;
            if mouse_msg == WM_LBUTTONUP {
                show_panel_near_cursor(hwnd);
            } else if mouse_msg == WM_RBUTTONUP {
                show_tray_context_menu(hwnd);
            }
            0
        }
        WM_COMMAND => {
            let cmd = wparam & 0xFFFF;
            handle_menu_command(hwnd, cmd);
            0
        }
        WM_DESTROY => {
            iclip_core::security::wipe_all_temp_previews();
            iclip_core::security::wipe_privacy_twins();
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ============================================================================
// 零轮询剪贴板捕获、来源进程名嗅探、富文本智变、链接直达与模拟粘贴
// ============================================================================

unsafe fn query_process_name_from_hwnd(target_hwnd: HWND) -> Option<String> {
    if target_hwnd.is_null() {
        return None;
    }
    let mut pid: u32 = 0;
    GetWindowThreadProcessId(target_hwnd, &mut pid);
    if pid == 0 {
        return None;
    }
    let hproc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if hproc.is_null() {
        return None;
    }
    let mut buf = [0u16; 260];
    let mut size = buf.len() as u32;
    let ok = QueryFullProcessImageNameW(hproc, 0, buf.as_mut_ptr(), &mut size) != FALSE;
    let _ = CloseHandle(hproc);
    if !ok || size == 0 {
        return None;
    }
    let full = OsString::from_wide(&buf[..size as usize])
        .to_string_lossy()
        .into_owned();
    let stem = Path::new(&full)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .trim();
    if stem.is_empty() || stem.eq_ignore_ascii_case("iClip") {
        None
    } else {
        Some(stem.to_string())
    }
}

unsafe fn detect_clipboard_source_app(self_hwnd: HWND) -> Option<String> {
    let owner = GetClipboardOwner();
    if !owner.is_null() && owner != self_hwnd {
        if let Some(name) = query_process_name_from_hwnd(owner) {
            return Some(name);
        }
    }
    let fg = GetForegroundWindow();
    if !fg.is_null() && fg != self_hwnd {
        return query_process_name_from_hwnd(fg);
    }
    None
}

unsafe fn trigger_global_copy_append(hwnd: HWND) {
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            if !st.store.config.minimal_mode_enabled && st.store.config.copy_append_enabled {
                st.pending_append_capture = true;
            }
        }
    });
    SetTimer(hwnd, TIMER_ID_DEFERRED_APPEND, 55, None);
}

unsafe fn simulate_ctrl_c() {
    let make_key = |vk: u16, up: bool| -> INPUT {
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: vk,
                    wScan: 0,
                    dwFlags: if up { KEYEVENTF_KEYUP } else { 0 },
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        }
    };
    let seq = [
        make_key(VK_CONTROL, false),
        make_key(0x43, false),
        make_key(0x43, true),
        make_key(VK_CONTROL, true),
    ];
    let _ = SendInput(seq.len() as u32, seq.as_ptr(), size_of::<INPUT>() as i32);
}

unsafe fn handle_clipboard_update(hwnd: HWND) {
    let should_skip = APP_STATE.with(|cell| {
        let mut borrow = cell.borrow_mut();
        let Some(st) = borrow.as_mut() else {
            return true;
        };
        if st.ignore_next_clipboard_seq {
            st.ignore_next_clipboard_seq = false;
            return true;
        }
        let _ = st.store.check_auto_resume_pause(now_unix_secs());
        if st.store.is_paused {
            st.pending_append_capture = false;
            return true;
        }
        if (st.cf_exclude_monitor != 0
            && IsClipboardFormatAvailable(st.cf_exclude_monitor) != FALSE)
            || (st.cf_viewer_ignore != 0
                && IsClipboardFormatAvailable(st.cf_viewer_ignore) != FALSE)
            || is_disallowed_by_clipboard_history_flag(hwnd, st.cf_can_include_history)
        {
            st.pending_append_capture = false;
            if st.store.config.auto_clear_concealed_clipboard {
                st.scrub_expected_seq_num = GetClipboardSequenceNumber();
                SetTimer(hwnd, TIMER_ID_CONCEALED_SCRUB, 60_000, None);
            }
            return true;
        }
        false
    });
    if should_skip {
        return;
    }

    let source_app = detect_clipboard_source_app(hwnd);
    let source_ignored = APP_STATE.with(|c| {
        c.borrow()
            .as_ref()
            .map(|st| st.store.is_app_ignored(source_app.as_deref()))
            .unwrap_or(false)
    });
    if source_ignored {
        let auto_scrub = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let Some(st) = b.as_mut() else { return false };
            st.pending_append_capture = false;
            if st.store.config.auto_clear_concealed_clipboard {
                st.scrub_expected_seq_num = GetClipboardSequenceNumber();
                true
            } else {
                false
            }
        });
        if auto_scrub {
            SetTimer(hwnd, TIMER_ID_CONCEALED_SCRUB, 60_000, None);
        }
        return;
    }

    // 用户正常复制了非密码新内容，立即取消此前挂起的残留清擦定时器，防止误清正常剪贴板
    KillTimer(hwnd, TIMER_ID_CONCEALED_SCRUB);

    if IsClipboardFormatAvailable(CF_HDROP_ID) != FALSE {
        if let Some(paths) = read_files_from_clipboard(hwnd) {
            if !paths.is_empty() {
                APP_STATE.with(|cell| {
                    if let Some(st) = cell.borrow_mut().as_mut() {
                        st.pending_append_capture = false;
                        st.store.insert_or_promote(ClipItem::new_files(
                            paths,
                            source_app.or_else(|| Some("Explorer".to_string())),
                        ));
                    }
                });
                let _ = InvalidateRect(hwnd, null(), FALSE);
                return;
            }
        }
    }

    if IsClipboardFormatAvailable(CF_UNICODETEXT_ID) != FALSE {
        if let Some(mut raw_text) = read_unicode_text_from_clipboard(hwnd) {
            if !raw_text.trim().is_empty() {
                let mut rewrite_clipboard_text: Option<String> = None;
                let mut rewrite_scrub_ms: Option<u32> = None;
                let mut feedback_toast: Option<String> = None;

                APP_STATE.with(|cell| {
                    if let Some(st) = cell.borrow_mut().as_mut() {
                        let minimal = st.store.config.minimal_mode_enabled;
                        let has_html = st.cf_html_format != 0
                            && IsClipboardFormatAvailable(st.cf_html_format) != FALSE;
                        let from_ide = is_code_editor_or_terminal_app(source_app.as_deref());

                        if st.pending_append_capture {
                            st.pending_append_capture = false;
                            let target_was_burn = st
                                .store
                                .items
                                .iter()
                                .find(|it| {
                                    !it.is_pinned
                                        && !it.is_pending_todo()
                                        && matches!(
                                            it.kind,
                                            iclip_core::model::ClipContentType::Text
                                                | iclip_core::model::ClipContentType::Link
                                        )
                                        && it.text.is_some()
                                })
                                .map(|it| it.is_burn_after_paste())
                                .unwrap_or(false);
                            if let Some(merged) = st.store.append_to_latest_text(&raw_text, "\n") {
                                if target_was_burn {
                                    rewrite_scrub_ms = Some(5_000);
                                }
                                rewrite_clipboard_text = Some(merged);
                                feedback_toast = Some("已跨处续接追加至首条记录".to_string());
                            }
                            return;
                        }

                        let now_ms = st.boot_instant.elapsed().as_millis() as u64;
                        let cur_hash = iclip_core::model::sha256_hex(raw_text.as_bytes());
                        let is_double_copy = !minimal
                            && st.store.config.double_copy_spark_enabled
                            && !st.last_copy_hash.is_empty()
                            && st.last_copy_hash == cur_hash
                            && now_ms.saturating_sub(st.last_copy_at_ms) <= 1_150;

                        st.last_copy_hash = cur_hash;
                        st.last_copy_at_ms = now_ms;

                        if is_double_copy {
                            let acts: Vec<QuickAction> = st
                                .store
                                .rank_actions_for_context(
                                    &ClipItem::new_text(raw_text.clone(), source_app.clone()),
                                    st.active_target_app_name.as_deref(),
                                    analyze_text_actions(&raw_text, false),
                                )
                                .into_iter()
                                .filter(|a| {
                                    a.id != "todo-split-checklist"
                                        && a.id != "contact-split-queue"
                                        && a.id != "query-to-json"
                                        && a.id != "json-to-query"
                                        && a.id != "kv-to-json"
                                        && a.id != "list-strip-markers"
                                        && a.id != "list-add-numbers"
                                })
                                .collect();
                            if let Some(top_act) = acts.first() {
                                if let Some(scrub_ms) =
                                    iclip_core::security::ephemeral_scrub_ms_for_action(top_act.id)
                                {
                                    if scrub_ms == 30_000 {
                                        // 保留原始 otpauth:// 或 WIFI: 分享串入库，剪贴板仅无痕替换为动态码/纯密码并 30s 自动擦除
                                        rewrite_clipboard_text = Some(top_act.result_text.clone());
                                        rewrite_scrub_ms = Some(scrub_ms);
                                    } else {
                                        raw_text = top_act.result_text.clone();
                                        rewrite_clipboard_text = Some(raw_text.clone());
                                        rewrite_scrub_ms = Some(scrub_ms);
                                    }
                                    feedback_toast =
                                        Some(format!("双按复制智变：{}", top_act.toast_text));
                                } else {
                                    raw_text = top_act.result_text.clone();
                                    rewrite_clipboard_text = Some(raw_text.clone());
                                    feedback_toast =
                                        Some(format!("双按复制智变：{}", top_act.toast_text));
                                }
                            } else if has_html && !from_ide {
                                rewrite_clipboard_text = Some(raw_text.clone());
                                feedback_toast = Some("双按复制：已剥离富文本脏样式".to_string());
                            }
                        } else if !minimal {
                            if st.store.config.auto_strip_zero_width
                                && iclip_core::security::inspect_clipboard_poison(&raw_text)
                                    .is_some()
                            {
                                let clean =
                                    iclip_core::security::sanitize_clipboard_poison(&raw_text);
                                if clean != raw_text && !clean.is_empty() {
                                    raw_text = clean;
                                    rewrite_clipboard_text = Some(raw_text.clone());
                                    feedback_toast =
                                        Some("智能契约：已自动清除隐形幽灵与控制符".to_string());
                                }
                            }
                            if st.store.config.auto_clean_tracking_url {
                                if let Some(clean) = clean_tracking_url(raw_text.trim()) {
                                    raw_text = clean.clone();
                                    rewrite_clipboard_text = Some(clean);
                                }
                            }
                            if rewrite_clipboard_text.is_none()
                                && st.store.config.auto_strip_rich_formatting
                                && has_html
                                && !from_ide
                            {
                                rewrite_clipboard_text = Some(raw_text.clone());
                            }
                        }

                        st.store
                            .insert_or_promote(ClipItem::new_text(raw_text, source_app));
                    }
                });

                if let Some(clean_out) = rewrite_clipboard_text {
                    let is_sens = rewrite_scrub_ms.is_some()
                        || iclip_core::security::classify_sensitive_text(&clean_out).is_some();
                    let (rw_guard, scrub_delay) = APP_STATE.with(|c| {
                        let mut b = c.borrow_mut();
                        let Some(st) = b.as_mut() else {
                            return (WinClipboardLocalOnlyGuard::default(), None);
                        };
                        st.ignore_next_clipboard_seq = true;
                        let delay = if let Some(explicit_ms) = rewrite_scrub_ms {
                            Some(explicit_ms)
                        } else if is_sens && st.store.config.auto_clear_concealed_clipboard {
                            Some(45_000)
                        } else {
                            None
                        };
                        (
                            WinClipboardLocalOnlyGuard {
                                block_cloud_and_history: is_sens,
                                cf_excl: st.cf_exclude_monitor,
                                cf_can_hist: st.cf_can_include_history,
                                cf_can_cloud: st.cf_can_upload_cloud,
                            },
                            delay,
                        )
                    });
                    let _ = write_text_and_html_to_clipboard_ext(hwnd, &clean_out, None, rw_guard);
                    if let Some(ms) = scrub_delay {
                        let seq = GetClipboardSequenceNumber();
                        APP_STATE.with(|c| {
                            if let Some(st) = c.borrow_mut().as_mut() {
                                st.scrub_expected_seq_num = seq;
                            }
                        });
                        SetTimer(hwnd, TIMER_ID_CONCEALED_SCRUB, ms, None);
                    }
                }
                if let Some(msg) = feedback_toast {
                    set_toast(hwnd, msg);
                } else {
                    let _ = InvalidateRect(hwnd, null(), FALSE);
                }
                return;
            }
        }
    }

    if IsClipboardFormatAvailable(CF_DIB_ID) != FALSE {
        if let Some((png_bytes, w, h)) = read_dib_as_png_from_clipboard(hwnd) {
            APP_STATE.with(|cell| {
                if let Some(st) = cell.borrow_mut().as_mut() {
                    st.pending_append_capture = false;
                    let hash = iclip_core::model::sha256_hex(&png_bytes);
                    let file_name = format!("{}.png", &hash[0..24]);
                    if st.store.write_image_bytes(&file_name, &png_bytes).is_ok() {
                        st.store.insert_or_promote(ClipItem::new_image(
                            file_name,
                            w,
                            h,
                            &png_bytes,
                            source_app.or_else(|| Some("截图".to_string())),
                        ));
                    }
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
    }
}

unsafe fn open_item_external_target(hwnd: HWND, store_idx: usize) {
    let item_opt = APP_STATE.with(|c| {
        c.borrow()
            .as_ref()
            .and_then(|st| st.store.items.get(store_idx).cloned())
    });
    let Some(item) = item_opt else { return };

    let op_open = to_wide("open");
    match item.kind {
        ClipContentType::Link | ClipContentType::Text => {
            let Some(raw) = &item.text else { return };
            let candidate = if item.kind == ClipContentType::Link {
                clean_tracking_url(raw.trim()).unwrap_or_else(|| raw.trim().to_string())
            } else if let Some(extracted) = extract_clean_share_url(raw) {
                extracted
            } else {
                return;
            };
            if iclip_core::security::inspect_link_risk(&candidate)
                == Some(iclip_core::security::LinkRiskKind::HomographPhishing)
            {
                set_toast(
                    hwnd,
                    "已拦截同形异义伪装钓鱼域名，请核对真实地址".to_string(),
                );
                return;
            }
            let Some(safe_url) = iclip_core::security::sanitize_safe_browser_url(&candidate) else {
                set_toast(hwnd, "已拦截非网页安全协议".to_string());
                return;
            };
            let url_w = to_wide(&safe_url);
            let always_top = APP_STATE.with(|c| {
                c.borrow()
                    .as_ref()
                    .map(|s| s.store.config.always_on_top)
                    .unwrap_or(false)
            });
            if !always_top {
                hide_panel(hwnd, false);
            } else {
                set_toast(hwnd, "已在默认浏览器中打开链接".to_string());
            }
            let _ = ShellExecuteW(
                null_mut(),
                op_open.as_ptr(),
                url_w.as_ptr(),
                null(),
                null(),
                SW_SHOWNORMAL,
            );
        }
        ClipContentType::File => {
            if let Some(first_path) = item.file_paths.as_ref().and_then(|p| p.first()) {
                let Some(safe_param) =
                    iclip_core::security::sanitize_safe_local_explorer_param(first_path)
                else {
                    set_toast(
                        hwnd,
                        "已拦截远程网络共享路径或异常参数，保护本机凭据".to_string(),
                    );
                    return;
                };
                let explorer = to_wide("explorer.exe");
                let param = to_wide(&safe_param);
                let always_top = APP_STATE.with(|c| {
                    c.borrow()
                        .as_ref()
                        .map(|s| s.store.config.always_on_top)
                        .unwrap_or(false)
                });
                if !always_top {
                    hide_panel(hwnd, false);
                }
                let _ = ShellExecuteW(
                    null_mut(),
                    op_open.as_ptr(),
                    explorer.as_ptr(),
                    param.as_ptr(),
                    null(),
                    SW_SHOWNORMAL,
                );
            }
        }
        ClipContentType::Image => {
            let img_path = APP_STATE.with(|c| {
                c.borrow().as_ref().and_then(|st| {
                    item.image_file_name.as_ref().and_then(|f| {
                        iclip_core::security::materialize_temp_preview_image(
                            &st.store.images_dir,
                            f,
                        )
                    })
                })
            });
            if let Some(p) = img_path {
                if let Some(safe_param) =
                    iclip_core::security::sanitize_safe_local_explorer_param(&p.to_string_lossy())
                {
                    let explorer = to_wide("explorer.exe");
                    let param = to_wide(&safe_param);
                    let _ = ShellExecuteW(
                        null_mut(),
                        op_open.as_ptr(),
                        explorer.as_ptr(),
                        param.as_ptr(),
                        null(),
                        SW_SHOWNORMAL,
                    );
                }
            }
        }
    }
}

fn item_supports_external_jump(item: &ClipItem) -> bool {
    match item.kind {
        ClipContentType::Link => item
            .text
            .as_deref()
            .and_then(iclip_core::security::sanitize_safe_browser_url)
            .is_some(),
        ClipContentType::File => true,
        ClipContentType::Text => item
            .text
            .as_deref()
            .and_then(|t| {
                let head = iclip_core::model::safe_utf8_prefix(t, 2048);
                if head.contains("http://") || head.contains("https://") {
                    extract_clean_share_url(head)
                        .and_then(|u| iclip_core::security::sanitize_safe_browser_url(&u))
                } else {
                    None
                }
            })
            .is_some(),
        ClipContentType::Image => false,
    }
}

fn item_quick_actions_for_ui(st: &WinAppState, item: &ClipItem) -> Vec<QuickAction> {
    if st.store.config.minimal_mode_enabled {
        return Vec::new();
    }
    if item.kind == ClipContentType::File {
        if let Some(paths) = &item.file_paths {
            return st.store.rank_actions_for_context(
                item,
                st.active_target_app_name.as_deref(),
                analyze_file_actions(paths, false),
            );
        }
        return Vec::new();
    }
    if let Some(raw) = &item.text {
        return st.store.rank_actions_for_context(
            item,
            st.active_target_app_name.as_deref(),
            analyze_text_actions(raw, false),
        );
    }
    Vec::new()
}

/// 所删即所净：删除敏感记录时同步关闭速览预览，并校验擦除系统剪贴板中的同内容敏感明文残留
unsafe fn delete_item_and_scrub_clipboard_if_needed(hwnd: HWND, id: &str) {
    let mut sensitive_text_to_scrub: Option<String> = None;
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            if let Some(target) = st.store.items.iter().find(|it| it.id == id) {
                if target.detected_sensitive_kind().is_some() || target.is_burn_after_paste() {
                    sensitive_text_to_scrub = target.text.clone();
                }
            }
            if st.show_quick_look {
                st.show_quick_look = false;
                st.editing_alias_item_id = None;
                st.alias_draft.clear();
            }
            st.store.delete_by_id(id);
        }
    });

    if let Some(target_text) = sensitive_text_to_scrub {
        if let Some(current_clip) = read_unicode_text_from_clipboard(hwnd) {
            if current_clip == target_text {
                APP_STATE.with(|c| {
                    if let Some(st) = c.borrow_mut().as_mut() {
                        st.ignore_next_clipboard_seq = true;
                    }
                });
                if OpenClipboard(hwnd) != FALSE {
                    let _ = EmptyClipboard();
                    let _ = CloseClipboard();
                }
            }
        }
    }
}

unsafe fn read_unicode_text_from_clipboard(hwnd: HWND) -> Option<String> {
    if OpenClipboard(hwnd) == FALSE {
        return None;
    }
    let handle = GetClipboardData(CF_UNICODETEXT_ID);
    if handle.is_null() {
        let _ = CloseClipboard();
        return None;
    }
    let ptr = GlobalLock(handle) as *const u16;
    let byte_len = GlobalSize(handle);
    let out = if !ptr.is_null() && byte_len >= 2 {
        // 保护进程堆内存：读取全局句柄最多截取前 8 MB UTF-16 单元（跳过末尾孤立 UTF-16 高代理项）
        let max_u16_units = 4 * 1024 * 1024;
        let mut units = (byte_len / 2).min(max_u16_units);
        let raw_slice = std::slice::from_raw_parts(ptr, units);
        if units == max_u16_units && units > 0 {
            let last_u = raw_slice[units - 1];
            if (0xD800..=0xDBFF).contains(&last_u) {
                units -= 1;
            }
        }
        Some(from_wide_slice(&raw_slice[..units]))
    } else {
        None
    };
    let _ = GlobalUnlock(handle);
    let _ = CloseClipboard();
    out
}

unsafe fn read_files_from_clipboard(hwnd: HWND) -> Option<Vec<String>> {
    if OpenClipboard(hwnd) == FALSE {
        return None;
    }
    let hdrop = GetClipboardData(CF_HDROP_ID);
    if hdrop.is_null() {
        let _ = CloseClipboard();
        return None;
    }
    let count = DragQueryFileW(hdrop as _, u32::MAX, null_mut(), 0);
    let mut paths = Vec::with_capacity(count as usize);
    for idx in 0..count {
        let needed = DragQueryFileW(hdrop as _, idx, null_mut(), 0);
        if needed > 0 {
            let mut buf = vec![0u16; (needed + 1) as usize];
            DragQueryFileW(hdrop as _, idx, buf.as_mut_ptr(), needed + 1);
            paths.push(from_wide_slice(&buf));
        }
    }
    let _ = CloseClipboard();
    Some(paths)
}

unsafe fn read_dib_as_png_from_clipboard(hwnd: HWND) -> Option<(Vec<u8>, u32, u32)> {
    if OpenClipboard(hwnd) == FALSE {
        return None;
    }
    let hdib = GetClipboardData(CF_DIB_ID);
    if hdib.is_null() {
        let _ = CloseClipboard();
        return None;
    }
    let ptr = GlobalLock(hdib) as *const u8;
    let total_size = GlobalSize(hdib);
    if ptr.is_null() || total_size < size_of::<BITMAPINFOHEADER>() {
        let _ = GlobalUnlock(hdib);
        let _ = CloseClipboard();
        return None;
    }
    let hdr = &*(ptr as *const BITMAPINFOHEADER);
    let w = hdr.biWidth.unsigned_abs();
    let top_down = hdr.biHeight < 0;
    let h = hdr.biHeight.unsigned_abs();
    let bpp = hdr.biBitCount;

    let mut result = None;
    let is_uncompressed = hdr.biCompression == BI_RGB || hdr.biCompression == 3;
    if is_uncompressed && (bpp == 32 || bpp == 24) && w > 0 && h > 0 && w <= 8192 && h <= 8192 {
        let mask_extra =
            if hdr.biCompression == 3 && hdr.biSize == size_of::<BITMAPINFOHEADER>() as u32 {
                12usize
            } else {
                0usize
            };
        let header_bytes = (hdr.biSize as usize).saturating_add(mask_extra);
        let stride = (((w as usize * bpp as usize) + 31) & !31) / 8;
        let pixel_span = stride.checked_mul(h as usize);
        let rgba_len = (w as usize)
            .checked_mul(h as usize)
            .and_then(|px| px.checked_mul(4));
        if let (Some(span), Some(out_len)) = (pixel_span, rgba_len) {
            if header_bytes >= size_of::<BITMAPINFOHEADER>()
                && header_bytes
                    .checked_add(span)
                    .is_some_and(|end| end <= total_size)
            {
                let pixels = std::slice::from_raw_parts(ptr.add(header_bytes), span);
                let mut rgba = vec![0u8; out_len];
                for y in 0..h as usize {
                    let src_row = if top_down { y } else { (h as usize) - 1 - y };
                    let row_slice = &pixels[src_row * stride..];
                    for x in 0..w as usize {
                        let dst_idx = (y * w as usize + x) * 4;
                        if bpp == 32 {
                            let s = x * 4;
                            rgba[dst_idx] = row_slice[s + 2];
                            rgba[dst_idx + 1] = row_slice[s + 1];
                            rgba[dst_idx + 2] = row_slice[s];
                            let a = row_slice[s + 3];
                            rgba[dst_idx + 3] = if a == 0 { 255 } else { a };
                        } else {
                            let s = x * 3;
                            rgba[dst_idx] = row_slice[s + 2];
                            rgba[dst_idx + 1] = row_slice[s + 1];
                            rgba[dst_idx + 2] = row_slice[s];
                            rgba[dst_idx + 3] = 255;
                        }
                    }
                }
                let mut png_out = Vec::new();
                if PngEncoder::new(&mut png_out)
                    .write_image(&rgba, w, h, ColorType::Rgba8.into())
                    .is_ok()
                {
                    result = Some((png_out, w, h));
                }
            }
        }
    }

    let _ = GlobalUnlock(hdib);
    let _ = CloseClipboard();
    result
}

#[derive(Clone, Copy, Default)]
struct WinClipboardLocalOnlyGuard {
    block_cloud_and_history: bool,
    cf_excl: u32,
    cf_can_hist: u32,
    cf_can_cloud: u32,
}

unsafe fn apply_win32_local_only_privacy_formats(guard: WinClipboardLocalOnlyGuard) {
    if !guard.block_cloud_and_history {
        return;
    }
    let write_dword_zero = |fmt_id: u32| {
        if fmt_id == 0 {
            return;
        }
        let h = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, 4);
        if !h.is_null() {
            let p = GlobalLock(h) as *mut u32;
            if !p.is_null() {
                *p = 0u32;
                let _ = GlobalUnlock(h);
                let _ = SetClipboardData(fmt_id, h);
            }
        }
    };
    // 物理阻断 Windows `Win+V` 明文历史入库与微软云剪贴板同步上传
    write_dword_zero(guard.cf_can_hist);
    write_dword_zero(guard.cf_can_cloud);
    if guard.cf_excl != 0 {
        let h_excl = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, 4);
        if !h_excl.is_null() {
            let _ = SetClipboardData(guard.cf_excl, h_excl);
        }
    }
}

unsafe fn write_text_and_html_to_clipboard(
    hwnd: HWND,
    text: &str,
    html_format_pair: Option<(u32, &str)>,
) -> bool {
    write_text_and_html_to_clipboard_ext(
        hwnd,
        text,
        html_format_pair,
        WinClipboardLocalOnlyGuard::default(),
    )
}

unsafe fn write_text_and_html_to_clipboard_ext(
    hwnd: HWND,
    text: &str,
    html_format_pair: Option<(u32, &str)>,
    privacy_guard: WinClipboardLocalOnlyGuard,
) -> bool {
    if OpenClipboard(hwnd) == FALSE {
        return false;
    }
    let _ = EmptyClipboard();

    let wide = to_wide(text);
    let byte_len = wide.len() * 2;
    let hmem = GlobalAlloc(GMEM_MOVEABLE, byte_len);
    if !hmem.is_null() {
        let dst = GlobalLock(hmem) as *mut u8;
        if !dst.is_null() {
            std::ptr::copy_nonoverlapping(wide.as_ptr() as *const u8, dst, byte_len);
            let _ = GlobalUnlock(hmem);
            let _ = SetClipboardData(CF_UNICODETEXT_ID, hmem);
        }
    }

    if let Some((fmt_id, cf_html_utf8)) = html_format_pair {
        if fmt_id != 0 {
            let bytes = cf_html_utf8.as_bytes();
            let h_html = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes.len() + 1);
            if !h_html.is_null() {
                let dst = GlobalLock(h_html) as *mut u8;
                if !dst.is_null() {
                    std::ptr::copy_nonoverlapping(bytes.as_ptr(), dst, bytes.len());
                    let _ = GlobalUnlock(h_html);
                    let _ = SetClipboardData(fmt_id, h_html);
                }
            }
        }
    }

    apply_win32_local_only_privacy_formats(privacy_guard);
    let _ = CloseClipboard();
    true
}

unsafe fn write_image_bytes_to_clipboard(hwnd: HWND, encoded_img: &[u8]) -> bool {
    write_image_bytes_to_clipboard_ext(hwnd, encoded_img, WinClipboardLocalOnlyGuard::default())
}

unsafe fn write_image_bytes_to_clipboard_ext(
    hwnd: HWND,
    encoded_img: &[u8],
    privacy_guard: WinClipboardLocalOnlyGuard,
) -> bool {
    if !iclip_core::engines::has_safe_raster_dimensions_in_memory(encoded_img) {
        return false;
    }
    let Ok(dyn_img) = image::load_from_memory(encoded_img) else {
        return false;
    };
    let rgba = dyn_img.to_rgba8();
    let (w, h) = rgba.dimensions();
    let hdr_size = size_of::<BITMAPINFOHEADER>();
    let Some(pixel_bytes) = (w as usize)
        .checked_mul(h as usize)
        .and_then(|px| px.checked_mul(4))
    else {
        return false;
    };
    let Some(alloc_bytes) = hdr_size.checked_add(pixel_bytes) else {
        return false;
    };
    if pixel_bytes > u32::MAX as usize {
        return false;
    }

    if OpenClipboard(hwnd) == FALSE {
        return false;
    };
    let _ = EmptyClipboard();
    let hdib = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, alloc_bytes);
    if !hdib.is_null() {
        let ptr = GlobalLock(hdib) as *mut u8;
        if !ptr.is_null() {
            let hdr = &mut *(ptr as *mut BITMAPINFOHEADER);
            hdr.biSize = hdr_size as u32;
            hdr.biWidth = w as i32;
            hdr.biHeight = h as i32;
            hdr.biPlanes = 1;
            hdr.biBitCount = 32;
            hdr.biCompression = BI_RGB;
            hdr.biSizeImage = pixel_bytes as u32;

            let dst_pixels = std::slice::from_raw_parts_mut(ptr.add(hdr_size), pixel_bytes);
            for y in 0..h as usize {
                let src_y = (h as usize) - 1 - y;
                for x in 0..w as usize {
                    let p = rgba.get_pixel(x as u32, src_y as u32);
                    let d = (y * w as usize + x) * 4;
                    dst_pixels[d] = p[2];
                    dst_pixels[d + 1] = p[1];
                    dst_pixels[d + 2] = p[0];
                    dst_pixels[d + 3] = p[3];
                }
            }
            let _ = GlobalUnlock(hdib);
            let _ = SetClipboardData(CF_DIB_ID, hdib);
        }
    }
    apply_win32_local_only_privacy_formats(privacy_guard);
    let _ = CloseClipboard();
    true
}

unsafe fn simulate_ctrl_v(send_tab_after: bool) {
    let make_key = |vk: u16, up: bool| -> INPUT {
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: vk,
                    wScan: 0,
                    dwFlags: if up { KEYEVENTF_KEYUP } else { 0 },
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        }
    };
    let mut seq = vec![
        make_key(VK_CONTROL, false),
        make_key(0x56, false),
        make_key(0x56, true),
        make_key(VK_CONTROL, true),
    ];
    if send_tab_after {
        seq.push(make_key(VK_TAB, false));
        seq.push(make_key(VK_TAB, true));
    }
    let _ = SendInput(seq.len() as u32, seq.as_ptr(), size_of::<INPUT>() as i32);
}

unsafe fn copy_only_item_in_place(hwnd: HWND, item_idx: usize) {
    let mut text_to_write: Option<String> = None;
    let mut image_path_to_write: Option<PathBuf> = None;
    let mut privacy_guard = WinClipboardLocalOnlyGuard::default();
    let mut scrub_45s = false;

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            st.ignore_next_clipboard_seq = true;
            if let Some(item) = st.store.items.get(item_idx).cloned() {
                let is_sensitive =
                    item.detected_sensitive_kind().is_some() || item.is_burn_after_paste();
                privacy_guard = WinClipboardLocalOnlyGuard {
                    block_cloud_and_history: is_sensitive,
                    cf_excl: st.cf_exclude_monitor,
                    cf_can_hist: st.cf_can_include_history,
                    cf_can_cloud: st.cf_can_upload_cloud,
                };
                if st.store.config.auto_clear_concealed_clipboard && !item.is_pinned && is_sensitive
                {
                    scrub_45s = true;
                }
                st.copied_flash_item_id = Some(item.id.clone());
                let target_app = st.active_target_app_name.clone();
                st.store
                    .record_paste_usage(&item.content_hash, target_app.as_deref());
                match item.kind {
                    ClipContentType::Text | ClipContentType::Link => {
                        text_to_write = item.text.clone();
                    }
                    ClipContentType::Image => {
                        if let Some(f) = &item.image_file_name {
                            image_path_to_write = Some(st.store.images_dir.join(f));
                        }
                    }
                    ClipContentType::File => {
                        if let Some(paths) = &item.file_paths {
                            text_to_write = Some(paths.join("\r\n"));
                        }
                    }
                }
            }
        }
    });

    if let Some(txt) = text_to_write {
        let _ = write_text_and_html_to_clipboard_ext(hwnd, &txt, None, privacy_guard);
    } else if let Some(img_path) = image_path_to_write {
        if let (Some(dir), Some(fname)) = (
            img_path.parent(),
            img_path.file_name().and_then(|s| s.to_str()),
        ) {
            if let Some(bytes) = iclip_core::security::read_decrypted_image_from_dir(dir, fname) {
                let _ = write_image_bytes_to_clipboard_ext(hwnd, &bytes, privacy_guard);
            }
        }
    }

    if scrub_45s {
        let seq = GetClipboardSequenceNumber();
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.scrub_expected_seq_num = seq;
            }
        });
        SetTimer(hwnd, TIMER_ID_CONCEALED_SCRUB, 45_000, None);
    }

    SetTimer(hwnd, TIMER_ID_COPY_FLASH_CLEAR, 1_150, None);
    let _ = InvalidateRect(hwnd, null(), FALSE);
}

unsafe fn commit_paste_item_by_index(hwnd: HWND, item_idx: usize, force_plain: bool) {
    let mut auto_paste = true;
    let mut always_top = false;
    let mut target_fg: HWND = null_mut();
    let mut text_to_write: Option<String> = None;
    let mut image_path_to_write: Option<PathBuf> = None;
    let mut item_id_for_otp: Option<String> = None;
    let mut privacy_guard = WinClipboardLocalOnlyGuard::default();

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            auto_paste = st.store.config.auto_paste_enabled;
            always_top = st.store.config.always_on_top;
            target_fg = st.previous_foreground;
            st.ignore_next_clipboard_seq = true;
            if let Some(item) = st.store.items.get(item_idx).cloned() {
                let is_sensitive =
                    item.detected_sensitive_kind().is_some() || item.is_burn_after_paste();
                privacy_guard = WinClipboardLocalOnlyGuard {
                    block_cloud_and_history: is_sensitive,
                    cf_excl: st.cf_exclude_monitor,
                    cf_can_hist: st.cf_can_include_history,
                    cf_can_cloud: st.cf_can_upload_cloud,
                };
                item_id_for_otp = Some(item.id.clone());
                let target_app = st.active_target_app_name.clone();
                st.store
                    .record_paste_usage(&item.content_hash, target_app.as_deref());
                let _ = st.store.mark_todo_completed_silently(&item.id);
                match item.kind {
                    ClipContentType::Text | ClipContentType::Link => {
                        if let Some(raw) = &item.text {
                            if !force_plain
                                && !st.store.config.minimal_mode_enabled
                                && iclip_core::engines::contains_dynamic_template_placeholders(raw)
                            {
                                let ctx = st
                                    .store
                                    .items
                                    .iter()
                                    .find(|c| {
                                        c.id != item.id
                                            && !c.is_burn_after_paste()
                                            && c.text
                                                .as_deref()
                                                .map(|t| {
                                                    !iclip_core::engines::contains_dynamic_template_placeholders(t)
                                                        && !t.trim().starts_with("ICLPMSG1:")
                                                })
                                                .unwrap_or(false)
                                    })
                                    .and_then(|c| c.text.as_deref());
                                let rendered = render_dynamic_template(raw, ctx);
                                if iclip_core::security::classify_sensitive_text(&rendered).is_some()
                                {
                                    privacy_guard.block_cloud_and_history = true;
                                }
                                text_to_write = Some(rendered);
                            } else if !force_plain
                                && matches!(
                                    item.detected_poison_threat(),
                                    Some(
                                        iclip_core::security::PoisonThreatKind::PastejackingOrBidi(
                                            _
                                        )
                                    )
                                )
                                && iclip_core::security::is_terminal_app(target_app.as_deref())
                            {
                                let safe_cmd = iclip_core::security::sanitize_clipboard_poison(raw);
                                if safe_cmd != *raw && !safe_cmd.is_empty() {
                                    text_to_write = Some(safe_cmd);
                                    st.toast_message =
                                        Some("已拦截隐藏终端控制符劫持并安全键入".to_string());
                                } else {
                                    text_to_write = Some(raw.clone());
                                }
                            } else {
                                text_to_write = Some(raw.clone());
                            }
                        }
                    }
                    ClipContentType::Image => {
                        if let Some(f) = &item.image_file_name {
                            image_path_to_write = Some(st.store.images_dir.join(f));
                        }
                    }
                    ClipContentType::File => {
                        if let Some(paths) = &item.file_paths {
                            text_to_write = Some(paths.join("\r\n"));
                        }
                    }
                }
            }
        }
    });

    if let Some(txt) = text_to_write {
        let _ = write_text_and_html_to_clipboard_ext(hwnd, &txt, None, privacy_guard);
    } else if let Some(img_path) = image_path_to_write {
        if let (Some(dir), Some(fname)) = (
            img_path.parent(),
            img_path.file_name().and_then(|s| s.to_str()),
        ) {
            if let Some(bytes) = iclip_core::security::read_decrypted_image_from_dir(dir, fname) {
                let _ = write_image_bytes_to_clipboard_ext(hwnd, &bytes, privacy_guard);
            }
        }
    }

    let mut scrub_delay_ms: Option<u32> = None;
    if let Some(id) = item_id_for_otp {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.store.schedule_otp_expire_if_needed(&id, 30);
                let is_burn = st.store.schedule_burn_after_paste_if_needed(&id, 5);
                if is_burn {
                    // 粘贴即焚 5 秒后同步擦除 Windows 系统剪贴板（序号锁保证不误删后续新复制）
                    scrub_delay_ms = Some(5_000);
                } else if st.store.config.auto_clear_concealed_clipboard {
                    if let Some(cur) = st.store.items.iter().find(|i| i.id == id) {
                        if !cur.is_pinned && cur.detected_sensitive_kind().is_some() {
                            scrub_delay_ms = Some(45_000);
                        }
                    }
                }
            }
        });
    }
    if let Some(delay_ms) = scrub_delay_ms {
        let seq = GetClipboardSequenceNumber();
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.scrub_expected_seq_num = seq;
            }
        });
        SetTimer(hwnd, TIMER_ID_CONCEALED_SCRUB, delay_ms, None);
    }

    if always_top {
        restore_target_foreground_if_needed(target_fg);
        set_toast(hwnd, "✓ 已键入目标窗口".to_string());
    } else {
        hide_panel(hwnd, true);
    }

    if auto_paste {
        std::thread::sleep(std::time::Duration::from_millis(35));
        simulate_ctrl_v(false);
    }
}

unsafe fn commit_ephemeral_secret_paste_with_delay(
    hwnd: HWND,
    secret: &str,
    toast: String,
    scrub_ms: u32,
) {
    iclip_core::security::bump_password_generation_salt();
    let (auto_paste, always_top, target_fg, guard) = APP_STATE.with(|c| {
        let mut b = c.borrow_mut();
        let st = b.as_mut().unwrap();
        st.ignore_next_clipboard_seq = true;
        st.search_query.clear();
        (
            st.store.config.auto_paste_enabled,
            st.store.config.always_on_top,
            st.previous_foreground,
            WinClipboardLocalOnlyGuard {
                block_cloud_and_history: true,
                cf_excl: st.cf_exclude_monitor,
                cf_can_hist: st.cf_can_include_history,
                cf_can_cloud: st.cf_can_upload_cloud,
            },
        )
    });
    let _ = write_text_and_html_to_clipboard_ext(hwnd, secret, None, guard);
    let seq = GetClipboardSequenceNumber();
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            st.scrub_expected_seq_num = seq;
        }
    });
    SetTimer(hwnd, TIMER_ID_CONCEALED_SCRUB, scrub_ms, None);

    if always_top {
        restore_target_foreground_if_needed(target_fg);
        set_toast(hwnd, toast);
    } else {
        hide_panel(hwnd, true);
    }
    if auto_paste {
        std::thread::sleep(std::time::Duration::from_millis(35));
        simulate_ctrl_v(false);
    }
}

unsafe fn commit_ephemeral_secret_paste(hwnd: HWND, secret: &str, toast: String) {
    commit_ephemeral_secret_paste_with_delay(hwnd, secret, toast, 45_000);
}

unsafe fn commit_direct_text_paste(hwnd: HWND, text: &str, toast: String) {
    let is_sens = iclip_core::security::classify_sensitive_text(text).is_some();
    let (auto_paste, always_top, target_fg, guard, scrub_45s) = APP_STATE.with(|c| {
        let mut b = c.borrow_mut();
        let st = b.as_mut().unwrap();
        st.ignore_next_clipboard_seq = true;
        st.search_query.clear();
        (
            st.store.config.auto_paste_enabled,
            st.store.config.always_on_top,
            st.previous_foreground,
            WinClipboardLocalOnlyGuard {
                block_cloud_and_history: is_sens,
                cf_excl: st.cf_exclude_monitor,
                cf_can_hist: st.cf_can_include_history,
                cf_can_cloud: st.cf_can_upload_cloud,
            },
            is_sens && st.store.config.auto_clear_concealed_clipboard,
        )
    });
    let _ = write_text_and_html_to_clipboard_ext(hwnd, text, None, guard);
    if scrub_45s {
        let seq = GetClipboardSequenceNumber();
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.scrub_expected_seq_num = seq;
            }
        });
        SetTimer(hwnd, TIMER_ID_CONCEALED_SCRUB, 45_000, None);
    }
    if always_top {
        restore_target_foreground_if_needed(target_fg);
        set_toast(hwnd, toast);
    } else {
        hide_panel(hwnd, true);
    }
    if auto_paste {
        std::thread::sleep(std::time::Duration::from_millis(35));
        simulate_ctrl_v(false);
    }
}

unsafe fn commit_quick_action(hwnd: HWND, item_idx: usize, action: &QuickAction) {
    let mut auto_paste = true;
    let mut always_top = false;
    let mut target_fg: HWND = null_mut();
    let mut cf_html_id = 0u32;
    let mut item_id: Option<String> = None;
    let mut raw_item_text: Option<String> = None;
    let mut source_pinned = false;
    let mut source_burn = false;

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            auto_paste = st.store.config.auto_paste_enabled;
            always_top = st.store.config.always_on_top;
            target_fg = st.previous_foreground;
            cf_html_id = st.cf_html_format;
            st.ignore_next_clipboard_seq = true;
            if let Some(it) = st.store.items.get(item_idx).cloned() {
                raw_item_text = it.text.clone();
                source_pinned = it.is_pinned;
                source_burn = it.is_burn_after_paste();
                item_id = Some(it.id);
                st.store
                    .record_action_habit(it.source_app_name.as_deref(), action.id);
            }
        }
    });

    if action.id == "totp-live-code" {
        if let Some(raw) = raw_item_text.as_deref() {
            let now_secs = iclip_core::model::now_unix_secs();
            if let Some(fresh) = iclip_core::security::evaluate_totp_uri(raw, now_secs) {
                commit_ephemeral_secret_paste_with_delay(
                    hwnd,
                    &fresh.code,
                    format!(
                        "已键入 2FA 动态码 {}（剩 {}s · 30s后擦除）",
                        fresh.formatted_code, fresh.remaining_seconds
                    ),
                    30_000,
                );
                return;
            }
        }
    }

    if action.id == "wifi-extract-password" {
        commit_ephemeral_secret_paste_with_delay(
            hwnd,
            &action.result_text,
            "已键入纯 Wi-Fi 密码（本机云隔离 · 30s后自动擦除）".to_string(),
            30_000,
        );
        return;
    }

    if action.id == "todo-split-checklist" {
        if let Some(id) = item_id {
            let created = APP_STATE.with(|c| {
                c.borrow_mut()
                    .as_mut()
                    .map(|st| st.store.split_checklist_into_todos(&id))
                    .unwrap_or(0)
            });
            if created > 0 {
                set_toast(hwnd, format!("✓ 已拆解为 {created} 条待办（Alt+2 查看）"));
            }
        }
        return;
    }

    if action.id == "contact-split-queue" {
        if let Some(id) = item_id {
            let queued = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut()?;
                let raw = st.store.items.iter().find(|it| it.id == id)?.text.clone()?;
                let shipping = iclip_core::intelligence::parse_shipping_contact(&raw)?;
                Some(
                    st.store
                        .enqueue_contact_fields_for_sequential_paste(&shipping.queue_fields()),
                )
            });
            if let Some(cnt) = queued.filter(|&n| n > 0) {
                set_toast(
                    hwnd,
                    format!("✓ 已拆入连填队列（共 {cnt} 项 · 连按 Ctrl+Alt+V 填入）"),
                );
            }
        }
        return;
    }

    if action.id == "file-strip-exif" {
        if let Some(clean_png) = strip_file_metadata_to_clean_png(Path::new(&action.result_text)) {
            let _ = write_image_bytes_to_clipboard(hwnd, &clean_png);
            if always_top {
                restore_target_foreground_if_needed(target_fg);
                set_toast(hwnd, action.toast_text.clone());
            } else {
                hide_panel(hwnd, true);
            }
            if auto_paste {
                std::thread::sleep(std::time::Duration::from_millis(35));
                simulate_ctrl_v(false);
            }
        } else {
            set_toast(hwnd, "无法读取或净化该图片文件".to_string());
        }
        return;
    }

    let html_pair = action
        .html_table_payload
        .as_deref()
        .map(|h| (cf_html_id, h));
    let out_is_sens = source_burn
        || iclip_core::security::ephemeral_scrub_ms_for_action(action.id).is_some()
        || iclip_core::security::classify_sensitive_text(&action.result_text).is_some();
    let (out_guard, scrub_45s) = APP_STATE.with(|c| {
        c.borrow()
            .as_ref()
            .map(|st| {
                (
                    WinClipboardLocalOnlyGuard {
                        block_cloud_and_history: out_is_sens,
                        cf_excl: st.cf_exclude_monitor,
                        cf_can_hist: st.cf_can_include_history,
                        cf_can_cloud: st.cf_can_upload_cloud,
                    },
                    out_is_sens && !source_pinned && st.store.config.auto_clear_concealed_clipboard,
                )
            })
            .unwrap_or((WinClipboardLocalOnlyGuard::default(), false))
    });
    let _ = write_text_and_html_to_clipboard_ext(hwnd, &action.result_text, html_pair, out_guard);
    if scrub_45s || source_burn {
        let seq = GetClipboardSequenceNumber();
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.scrub_expected_seq_num = seq;
            }
        });
        let scrub_ms = if source_burn { 5_000 } else { 45_000 };
        SetTimer(hwnd, TIMER_ID_CONCEALED_SCRUB, scrub_ms, None);
    }

    if let Some(id) = item_id {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                let _ = st.store.schedule_burn_after_paste_if_needed(&id, 5);
                st.store.schedule_otp_expire_if_needed(&id, 30);
            }
        });
    }

    if always_top {
        restore_target_foreground_if_needed(target_fg);
        set_toast(hwnd, action.toast_text.clone());
    } else {
        hide_panel(hwnd, true);
    }
    if auto_paste {
        std::thread::sleep(std::time::Duration::from_millis(35));
        simulate_ctrl_v(false);
    }
}

unsafe fn handle_queue_pop_shortcut(hwnd: HWND) {
    let mut next_item: Option<ClipItem> = None;
    let mut auto_tab = false;
    let mut img_dir = PathBuf::new();
    let mut target_app_name: Option<String> = None;
    let mut minimal_mode = false;

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            if st.store.config.minimal_mode_enabled {
                return;
            }
            minimal_mode = st.store.config.minimal_mode_enabled;
            auto_tab = st.store.config.queue_auto_tab;
            img_dir = st.store.images_dir.clone();
            target_app_name = st.active_target_app_name.clone();
            next_item = st.store.dequeue_next_item();
            if next_item.is_some() {
                st.ignore_next_clipboard_seq = true;
            }
        }
    });

    let Some(item) = next_item else {
        return;
    };
    let always_top = APP_STATE.with(|c| {
        c.borrow()
            .as_ref()
            .map(|s| s.store.config.always_on_top)
            .unwrap_or(false)
    });
    if !always_top {
        hide_panel(hwnd, true);
    }

    let is_sens = item.detected_sensitive_kind().is_some() || item.is_burn_after_paste();
    let q_privacy_guard = APP_STATE.with(|c| {
        c.borrow()
            .as_ref()
            .map(|st| WinClipboardLocalOnlyGuard {
                block_cloud_and_history: is_sens,
                cf_excl: st.cf_exclude_monitor,
                cf_can_hist: st.cf_can_include_history,
                cf_can_cloud: st.cf_can_upload_cloud,
            })
            .unwrap_or_default()
    });
    if let Some(txt) = &item.text {
        let out_txt = if !minimal_mode
            && matches!(
                item.detected_poison_threat(),
                Some(iclip_core::security::PoisonThreatKind::PastejackingOrBidi(
                    _
                ))
            )
            && iclip_core::security::is_terminal_app(target_app_name.as_deref())
        {
            let cleaned = iclip_core::security::sanitize_clipboard_poison(txt);
            if cleaned != *txt && !cleaned.is_empty() {
                cleaned
            } else {
                txt.clone()
            }
        } else {
            txt.clone()
        };
        let _ = write_text_and_html_to_clipboard_ext(hwnd, &out_txt, None, q_privacy_guard);
    } else if item.kind == ClipContentType::Image {
        if let Some(f) = &item.image_file_name {
            if let Some(bytes) = iclip_core::security::read_decrypted_image_from_dir(&img_dir, f) {
                let _ = write_image_bytes_to_clipboard_ext(hwnd, &bytes, q_privacy_guard);
            }
        }
    }

    let mut scrub_delay_ms: Option<u32> = None;
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            st.store.schedule_otp_expire_if_needed(&item.id, 30);
            let is_burn = st.store.schedule_burn_after_paste_if_needed(&item.id, 5);
            if is_burn {
                scrub_delay_ms = Some(5_000);
            } else if st.store.config.auto_clear_concealed_clipboard && !item.is_pinned && is_sens {
                scrub_delay_ms = Some(45_000);
            }
        }
    });
    if let Some(delay_ms) = scrub_delay_ms {
        let seq = GetClipboardSequenceNumber();
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.scrub_expected_seq_num = seq;
            }
        });
        SetTimer(hwnd, TIMER_ID_CONCEALED_SCRUB, delay_ms, None);
    }

    std::thread::sleep(std::time::Duration::from_millis(35));
    simulate_ctrl_v(auto_tab);
}

// ============================================================================
// 离屏灰阶 Alpha 字体光栅合成引擎 + 1:1 macOS 液态玻璃面板排版渲染器
// ============================================================================

struct TextDrawCmd {
    text: String,
    rect: RECT,
    color: Color4,
    font_kind: FontKind,
    flags: u32,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum FontKind {
    Display,
    Headline,
    CardTitle,
    Body,
    Meta,
    BadgeBold,
    KeyCap,
    Mono,
}

#[derive(Clone)]
struct ResolvedFontFamilies {
    latin_display: String,
    latin_ui: String,
    cjk_ui: String,
    mono: String,
}

thread_local! {
    static RESOLVED_FONTS: RefCell<Option<ResolvedFontFamilies>> = const { RefCell::new(None) };
}

unsafe extern "system" fn collect_font_family_proc(
    lpelfe: *const LOGFONTW,
    _lpntme: *const TEXTMETRICW,
    _font_type: u32,
    lparam: LPARAM,
) -> i32 {
    if lpelfe.is_null() || lparam == 0 {
        return 1;
    }
    let set = &mut *(lparam as *mut std::collections::HashSet<String>);
    let face = &(*lpelfe).lfFaceName;
    let len = face.iter().position(|&c| c == 0).unwrap_or(face.len());
    if len > 0 {
        let name = String::from_utf16_lossy(&face[..len]);
        if !name.starts_with('@') {
            set.insert(name);
        }
    }
    1
}

unsafe fn resolve_font_families(ref_dc: HDC) -> ResolvedFontFamilies {
    if let Some(cached) = RESOLVED_FONTS.with(|c| c.borrow().clone()) {
        return cached;
    }
    let mut installed: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut lf: LOGFONTW = zeroed();
    lf.lfCharSet = DEFAULT_CHARSET as u8;
    let _ = EnumFontFamiliesExW(
        ref_dc,
        &lf,
        Some(collect_font_family_proc),
        (&mut installed as *mut std::collections::HashSet<String>) as LPARAM,
        0,
    );
    let pick = |candidates: &[&str], fallback: &str| -> String {
        for cand in candidates {
            if installed.contains(*cand) {
                return (*cand).to_string();
            }
        }
        fallback.to_string()
    };
    let resolved = ResolvedFontFamilies {
        latin_display: pick(
            &[
                "Segoe UI Variable Display",
                "Segoe UI Variable Text",
                "Segoe UI",
            ],
            "Segoe UI",
        ),
        latin_ui: pick(&["Segoe UI Variable Text", "Segoe UI"], "Segoe UI"),
        cjk_ui: pick(
            &[
                "HarmonyOS Sans SC",
                "MiSans",
                "PingFang SC",
                "Noto Sans SC",
                "Microsoft YaHei UI",
            ],
            "Microsoft YaHei UI",
        ),
        mono: pick(&["Cascadia Mono", "JetBrains Mono", "Consolas"], "Consolas"),
    };
    RESOLVED_FONTS.with(|c| {
        *c.borrow_mut() = Some(resolved.clone());
    });
    resolved
}

unsafe fn make_cleartype_font(face_name: &str, px: i32, weight: i32) -> *mut core::ffi::c_void {
    let face = to_wide(face_name);
    CreateFontW(
        -px.max(8),
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        DEFAULT_CHARSET as u32,
        OUT_DEFAULT_PRECIS as u32,
        CLIP_DEFAULT_PRECIS as u32,
        CLEARTYPE_NATURAL_QUALITY,
        0,
        face.as_ptr(),
    )
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ScriptClass {
    Latin,
    Cjk,
}

fn char_script_class(ch: char) -> ScriptClass {
    if ch.is_ascii()
        || matches!(
            ch,
            '¥' | '€'
                | '£'
                | '·'
                | '×'
                | '÷'
                | '±'
                | '°'
                | '–'
                | '—'
                | '…'
                | '✓'
                | '•'
                | '‹'
                | '›'
        )
    {
        ScriptClass::Latin
    } else {
        ScriptClass::Cjk
    }
}

/// 将单行文本切分为西文/数字段与中文段，实现真正双字族混排与盘古光学微距
fn split_script_runs(text: &str) -> Vec<(ScriptClass, String)> {
    let mut runs: Vec<(ScriptClass, String)> = Vec::new();
    let mut cur_class: Option<ScriptClass> = None;
    let mut cur_buf = String::new();
    for ch in text.chars() {
        let cls = if ch == ' ' {
            cur_class.unwrap_or(ScriptClass::Latin)
        } else {
            char_script_class(ch)
        };
        if Some(cls) == cur_class {
            cur_buf.push(ch);
        } else {
            if let Some(prev) = cur_class {
                if !cur_buf.is_empty() {
                    runs.push((prev, std::mem::take(&mut cur_buf)));
                }
            }
            cur_class = Some(cls);
            cur_buf.push(ch);
        }
    }
    if let Some(prev) = cur_class {
        if !cur_buf.is_empty() {
            runs.push((prev, cur_buf));
        }
    }
    runs
}

/// 判断相邻两段是否需要插入轻微中英盘古光学间距（两侧已有空格或标点时不重复加宽）
fn needs_pangu_gap(
    prev_txt: &str,
    prev_cls: ScriptClass,
    next_txt: &str,
    next_cls: ScriptClass,
) -> bool {
    if prev_cls == next_cls {
        return false;
    }
    let Some(last) = prev_txt.chars().last() else {
        return false;
    };
    let Some(first) = next_txt.chars().next() else {
        return false;
    };
    if last.is_whitespace() || first.is_whitespace() {
        return false;
    }
    let is_sep = |c: char| {
        matches!(
            c,
            '·' | '•'
                | '/'
                | ':'
                | '：'
                | '（'
                | '）'
                | '('
                | ')'
                | '['
                | ']'
                | '「'
                | '」'
                | '，'
                | '。'
                | '、'
                | '-'
                | '—'
                | '…'
        )
    };
    !(is_sep(last) || is_sep(first))
}

unsafe fn measure_wide_px(dc: HDC, text: &str) -> i32 {
    if text.is_empty() {
        return 0;
    }
    let wide = to_wide(text);
    let mut sz = SIZE { cx: 0, cy: 0 };
    let _ = GetTextExtentPoint32W(
        dc,
        wide.as_ptr(),
        (wide.len().saturating_sub(1)) as i32,
        &mut sz,
    );
    sz.cx
}

/// 在 2x 超采样离屏缓冲中以双字族精准混排绘制单行文本（支持左/中/右对齐与像素级省略号截断）
#[allow(clippy::too_many_arguments)]
unsafe fn draw_mixed_singleline_2x(
    dc: HDC,
    text: &str,
    latin_font: *mut core::ffi::c_void,
    cjk_font: *mut core::ffi::c_void,
    box_w_2x: i32,
    box_h_2x: i32,
    flags: u32,
    scale: f32,
) {
    let pangu_gap_2x = (2.6 * scale).round() as i32;
    let runs = split_script_runs(text);
    if runs.is_empty() {
        return;
    }

    let mut measured: Vec<(ScriptClass, String, i32, i32)> = Vec::with_capacity(runs.len());
    let mut total_w = 0i32;
    for (idx, (cls, seg)) in runs.into_iter().enumerate() {
        let gap = if idx > 0 {
            let (p_cls, ref p_txt, _, _) = measured[idx - 1];
            if needs_pangu_gap(p_txt, p_cls, &seg, cls) {
                pangu_gap_2x
            } else {
                0
            }
        } else {
            0
        };
        SelectObject(
            dc,
            if cls == ScriptClass::Latin {
                latin_font
            } else {
                cjk_font
            },
        );
        let seg_w = measure_wide_px(dc, &seg);
        total_w += gap + seg_w;
        measured.push((cls, seg, gap, seg_w));
    }

    // 超出矩形宽度且要求省略号时，按字符级精确截断并追加 `…`
    if total_w > box_w_2x && (flags & DT_END_ELLIPSIS) != 0 {
        SelectObject(dc, latin_font);
        let ell_w = measure_wide_px(dc, "…");
        let budget = (box_w_2x - ell_w).max(0);
        let mut trimmed: Vec<(ScriptClass, String, i32, i32)> = Vec::new();
        let mut acc = 0i32;
        for (cls, seg, gap, seg_w) in measured {
            if acc + gap + seg_w <= budget {
                acc += gap + seg_w;
                trimmed.push((cls, seg, gap, seg_w));
            } else {
                let rem = (budget - acc - gap).max(0);
                if rem > 0 {
                    SelectObject(
                        dc,
                        if cls == ScriptClass::Latin {
                            latin_font
                        } else {
                            cjk_font
                        },
                    );
                    let mut kept = String::new();
                    let mut kw = 0i32;
                    for ch in seg.chars() {
                        let mut trial = kept.clone();
                        trial.push(ch);
                        let tw = measure_wide_px(dc, &trial);
                        if tw > rem {
                            break;
                        }
                        kept = trial;
                        kw = tw;
                    }
                    if !kept.is_empty() {
                        acc += gap + kw;
                        trimmed.push((cls, kept, gap, kw));
                    }
                }
                break;
            }
        }
        trimmed.push((ScriptClass::Latin, "…".to_string(), 0, ell_w));
        total_w = acc + ell_w;
        measured = trimmed;
    }

    let start_x = if (flags & DT_CENTER) != 0 {
        ((box_w_2x - total_w) / 2).max(0)
    } else if (flags & DT_RIGHT) != 0 {
        (box_w_2x - total_w).max(0)
    } else {
        0
    };

    let cjk_y_comp = if (flags & DT_VCENTER) != 0 {
        -(1.8 * scale).round() as i32
    } else {
        0
    };
    let latin_y_comp = if (flags & DT_VCENTER) != 0 {
        -(0.6 * scale).round() as i32
    } else {
        0
    };

    let mut cur_x = start_x;
    for (cls, seg, gap, seg_w) in measured {
        cur_x += gap;
        if cur_x >= box_w_2x {
            break;
        }
        SelectObject(
            dc,
            if cls == ScriptClass::Latin {
                latin_font
            } else {
                cjk_font
            },
        );
        let y_comp = if cls == ScriptClass::Latin {
            latin_y_comp
        } else {
            cjk_y_comp
        };
        let mut r = RECT {
            left: cur_x,
            top: y_comp,
            right: (cur_x + seg_w + 4).min(box_w_2x),
            bottom: box_h_2x,
        };
        let mut wide = to_wide(&seg);
        let _ = DrawTextW(
            dc,
            wide.as_mut_ptr(),
            (wide.len().saturating_sub(1)) as i32,
            &mut r,
            DT_LEFT | (flags & DT_VCENTER) | DT_SINGLELINE | DT_NOPREFIX,
        );
        cur_x += seg_w;
    }
}

fn load_or_get_thumbnail<'a>(
    cache: &'a mut Vec<DecodedThumb>,
    images_dir: &Path,
    file_name: &str,
) -> Option<(u32, u32, &'a [u8])> {
    if let Some(pos) = cache.iter().position(|t| t.file_name == file_name) {
        let item = &cache[pos];
        return Some((item.width, item.height, item.rgba.as_slice()));
    }
    let raw = iclip_core::security::read_decrypted_image_from_dir(images_dir, file_name)?;
    if !iclip_core::engines::has_safe_raster_dimensions_in_memory(&raw) {
        return None;
    }
    let dyn_img = image::load_from_memory(&raw).ok()?;
    let (ow, oh) = (dyn_img.width(), dyn_img.height());
    let thumb = if ow > 260 || oh > 260 {
        dyn_img.resize(260, 260, FilterType::Triangle)
    } else {
        dyn_img
    };
    let rgba_img = thumb.to_rgba8();
    let (tw, th) = rgba_img.dimensions();
    if cache.len() >= 24 {
        cache.remove(0);
    }
    cache.push(DecodedThumb {
        file_name: file_name.to_string(),
        width: tw,
        height: th,
        rgba: rgba_img.into_raw(),
    });
    let last = cache.last()?;
    Some((last.width, last.height, last.rgba.as_slice()))
}

unsafe fn composite_texts_premultiplied_alpha(
    ref_dc: HDC,
    canvas: &mut PixelCanvas,
    texts: &[TextDrawCmd],
    scale: f32,
    scroll_clip: Option<(usize, i32, i32)>,
) {
    if texts.is_empty() {
        return;
    }
    let w = canvas.width;
    let h = canvas.height;
    let families = resolve_font_families(ref_dc);
    let mask_dc = CreateCompatibleDC(ref_dc);
    if mask_dc.is_null() {
        return;
    }
    SetBkMode(mask_dc, TRANSPARENT as i32);
    SetTextColor(mask_dc, 0x00FF_FFFF);

    // 2x 超采样字号映射（配合 CLEARTYPE_NATURAL_QUALITY 3 通道亚像素 2x2 盒滤 = 有效 6x 横向 × 2x 纵向采样）
    let s2 = |pt: f32| (pt * scale * 2.0).round() as i32;
    let cjk_is_yahei = families.cjk_ui.eq_ignore_ascii_case("Microsoft YaHei UI");
    let cjk_title_weight = if cjk_is_yahei {
        FW_NORMAL as i32
    } else {
        FW_MEDIUM as i32
    };
    let cjk_head_weight = if cjk_is_yahei {
        FW_BOLD as i32
    } else {
        FW_SEMIBOLD as i32
    };

    let f_disp_lat = make_cleartype_font(&families.latin_display, s2(16.5), FW_BOLD as i32);
    let f_disp_cjk = make_cleartype_font(&families.cjk_ui, s2(16.0), cjk_head_weight);
    let f_head_lat = make_cleartype_font(&families.latin_display, s2(15.0), FW_SEMIBOLD as i32);
    let f_head_cjk = make_cleartype_font(&families.cjk_ui, s2(14.5), cjk_head_weight);
    let f_title_lat = make_cleartype_font(&families.latin_ui, s2(13.5), FW_SEMIBOLD as i32);
    let f_title_cjk = make_cleartype_font(&families.cjk_ui, s2(13.5), cjk_title_weight);
    let f_body_lat = make_cleartype_font(&families.latin_ui, s2(13.0), FW_NORMAL as i32);
    let f_body_cjk = make_cleartype_font(&families.cjk_ui, s2(13.0), FW_NORMAL as i32);
    let f_meta_lat = make_cleartype_font(&families.latin_ui, s2(11.5), FW_NORMAL as i32);
    let f_meta_cjk = make_cleartype_font(&families.cjk_ui, s2(11.5), FW_NORMAL as i32);
    let f_badge_lat = make_cleartype_font(&families.latin_ui, s2(11.5), FW_SEMIBOLD as i32);
    let f_badge_cjk = make_cleartype_font(&families.cjk_ui, s2(11.2), cjk_title_weight);
    let f_keycap = make_cleartype_font(&families.mono, s2(10.5), FW_SEMIBOLD as i32);
    let f_mono = make_cleartype_font(&families.mono, s2(11.5), FW_MEDIUM as i32);

    // 三档感知 Gamma LUT：暗底浅字适度增肉(0.76)、浅底主标题自然微增墨(0.84 代替微软雅黑 700 糊块)、浅底常规正文锐利清透(0.95)
    let mut lut_light_on_dark = [0.0f32; 256];
    let mut lut_medium_ink = [0.0f32; 256];
    let mut lut_crisp_dark = [0.0f32; 256];
    for i in 1..256 {
        let v = (i as f32) / 255.0;
        lut_light_on_dark[i] = v.powf(0.76);
        lut_medium_ink[i] = v.powf(0.82);
        lut_crisp_dark[i] = v.powf(0.95);
    }

    // 局部按需扩容复用的 2x 离屏光栅 DIB（远小于全屏 4x 缓冲，兼顾极致画质与毫秒级帧耗时）
    let mut scratch_w: i32 = 0;
    let mut scratch_h: i32 = 0;
    let mut scratch_bmp: *mut core::ffi::c_void = null_mut();
    let mut scratch_old: *mut core::ffi::c_void = null_mut();
    let mut scratch_ptr: *mut u32 = null_mut();

    canvas.reset_vertical_clip();
    let old_font = SelectObject(mask_dc, f_title_cjk);
    for (cmd_idx, cmd) in texts.iter().enumerate() {
        if let Some((start_idx, cy0, cy1)) = scroll_clip {
            if cmd_idx >= start_idx {
                canvas.set_vertical_clip(cy0, cy1);
            }
        }
        if cmd.text.is_empty() || cmd.color.a == 0 {
            continue;
        }
        let x0 = cmd.rect.left.max(0);
        let y0 = cmd.rect.top.max(0);
        let x1 = cmd.rect.right.min(w);
        let y1 = cmd.rect.bottom.min(h);
        if x0 >= x1 || y0 >= y1 {
            continue;
        }
        let rw = x1 - x0;
        let rh = y1 - y0;
        let sw = rw * 2;
        let sh = rh * 2;

        if sw > scratch_w || sh > scratch_h {
            if !scratch_bmp.is_null() {
                SelectObject(mask_dc, scratch_old);
                DeleteObject(scratch_bmp);
                scratch_bmp = null_mut();
                scratch_ptr = null_mut();
            }
            let nw = sw.max(scratch_w).max(256);
            let nh = sh.max(scratch_h).max(96);
            let mut bmi: BITMAPINFO = zeroed();
            bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
            bmi.bmiHeader.biWidth = nw;
            bmi.bmiHeader.biHeight = -nh;
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = BI_RGB;
            let mut raw_ptr: *mut core::ffi::c_void = null_mut();
            let bmp = CreateDIBSection(mask_dc, &bmi, DIB_RGB_COLORS, &mut raw_ptr, null_mut(), 0);
            if bmp.is_null() || raw_ptr.is_null() {
                continue;
            }
            scratch_old = SelectObject(mask_dc, bmp);
            scratch_bmp = bmp;
            scratch_ptr = raw_ptr as *mut u32;
            scratch_w = nw;
            scratch_h = nh;
        }

        let buf = std::slice::from_raw_parts_mut(scratch_ptr, (scratch_w * scratch_h) as usize);
        for row in 0..sh {
            let start = (row * scratch_w) as usize;
            buf[start..start + (sw as usize)].fill(0);
        }

        let (lat_f, cjk_f, is_mono_role) = match cmd.font_kind {
            FontKind::Display => (f_disp_lat, f_disp_cjk, false),
            FontKind::Headline => (f_head_lat, f_head_cjk, false),
            FontKind::CardTitle => (f_title_lat, f_title_cjk, false),
            FontKind::Body => (f_body_lat, f_body_cjk, false),
            FontKind::Meta => (f_meta_lat, f_meta_cjk, false),
            FontKind::BadgeBold => (f_badge_lat, f_badge_cjk, false),
            FontKind::KeyCap => (f_keycap, f_keycap, true),
            FontKind::Mono => (f_mono, f_mono, true),
        };

        let is_singleline = (cmd.flags & DT_SINGLELINE) != 0 && (cmd.flags & DT_WORDBREAK) == 0;
        if is_singleline && !is_mono_role {
            draw_mixed_singleline_2x(mask_dc, &cmd.text, lat_f, cjk_f, sw, sh, cmd.flags, scale);
        } else {
            SelectObject(mask_dc, if is_mono_role { lat_f } else { cjk_f });
            let mut wide = to_wide(&cmd.text);
            let mut r = RECT {
                left: 0,
                top: if (cmd.flags & DT_VCENTER) != 0 && is_singleline {
                    -(1.0 * scale).round() as i32
                } else {
                    0
                },
                right: sw,
                bottom: sh,
            };
            let _ = DrawTextW(
                mask_dc,
                wide.as_mut_ptr(),
                (wide.len().saturating_sub(1)) as i32,
                &mut r,
                cmd.flags | DT_NOPREFIX,
            );
        }
        let _ = GdiFlush();

        let luma =
            (cmd.color.r as u32 * 77 + cmd.color.g as u32 * 150 + cmd.color.b as u32 * 29) >> 8;
        let lut = if luma > 155 {
            &lut_light_on_dark
        } else if cjk_is_yahei && matches!(cmd.font_kind, FontKind::CardTitle | FontKind::BadgeBold)
        {
            &lut_medium_ink
        } else {
            &lut_crisp_dark
        };

        let stride = scratch_w as usize;
        for ly in 0..rh {
            let py = y0 + ly;
            let r0 = ((ly * 2) as usize) * stride;
            let r1 = r0 + stride;
            for lx in 0..rw {
                let c0 = (lx * 2) as usize;
                let p00 = buf[r0 + c0];
                let p10 = buf[r0 + c0 + 1];
                let p01 = buf[r1 + c0];
                let p11 = buf[r1 + c0 + 1];
                if (p00 | p10 | p01 | p11) == 0 {
                    continue;
                }
                let rgb_sum =
                    |p: u32| -> u32 { (p & 0xFF) + ((p >> 8) & 0xFF) + ((p >> 16) & 0xFF) };
                let cov = ((rgb_sum(p00) + rgb_sum(p10) + rgb_sum(p01) + rgb_sum(p11) + 6) / 12)
                    .min(255) as usize;
                if cov > 0 {
                    canvas.blend_pixel(x0 + lx, py, cmd.color, lut[cov]);
                }
            }
        }
    }
    canvas.reset_vertical_clip();

    SelectObject(mask_dc, old_font);
    for f in [
        f_disp_lat,
        f_disp_cjk,
        f_head_lat,
        f_head_cjk,
        f_title_lat,
        f_title_cjk,
        f_body_lat,
        f_body_cjk,
        f_meta_lat,
        f_meta_cjk,
        f_badge_lat,
        f_badge_cjk,
        f_keycap,
        f_mono,
    ] {
        DeleteObject(f);
    }
    if !scratch_bmp.is_null() {
        SelectObject(mask_dc, scratch_old);
        DeleteObject(scratch_bmp);
    }
    DeleteDC(mask_dc);
}

unsafe fn render_panel_frame_dib(
    hdc: HDC,
    dib_pixels: &mut [u32],
    w: i32,
    h: i32,
    scale: f32,
    st: &mut WinAppState,
    wallpaper_sim_bg: Option<Color4>,
) {
    st.hit_regions.clear();
    let sf = |v: f32| v * scale;

    let palette = GlassPalette::for_macos_liquid_glass(
        st.is_dark_mode,
        st.store.config.blur_concentration_pct,
    );

    let mut base_texts: Vec<TextDrawCmd> = Vec::with_capacity(110);
    let mut overlay_texts: Vec<TextDrawCmd> = Vec::with_capacity(32);

    let mut base_scroll_clip: Option<(usize, i32, i32)> = None;

    {
        let mut canvas = PixelCanvas::new(dib_pixels, w, h);
        if let Some(bg) = wallpaper_sim_bg {
            let bot = Color4::rgb(
                bg.r.saturating_sub(14),
                bg.g.saturating_sub(10),
                bg.b.saturating_add(8),
            );
            canvas.fill_vgrad_round_rect(0, 0, w, h, 0.0, bg, bot);
        } else {
            canvas.clear(Color4::rgba(0, 0, 0, 0));
        }

        // 面板根液态玻璃表面（顶亮底暗 1px 镜面高光折射边，呈现真实液态玻璃厚度）
        canvas.fill_round_rect(0, 0, w, h, sf(18.0), palette.window_bg);
        canvas.stroke_glass_bevel_round_rect(
            0,
            0,
            w,
            h,
            sf(18.0),
            sf(0.95),
            palette.glass_top_highlight,
            palette.window_border,
        );

        match st.view_mode {
            ActiveViewMode::MainList => {
                layout_and_draw_main_view(&mut canvas, &mut base_texts, w, h, scale, &palette, st);
            }
            ActiveViewMode::Settings => {
                base_scroll_clip = Some(layout_and_draw_settings_view(
                    &mut canvas,
                    &mut base_texts,
                    w,
                    h,
                    scale,
                    &palette,
                    st,
                ));
            }
        }
    }

    // 先将主视图/设置页文字以无黑边灰阶 Alpha 合成进画布
    {
        let mut canvas = PixelCanvas::new(dib_pixels, w, h);
        composite_texts_premultiplied_alpha(hdc, &mut canvas, &base_texts, scale, base_scroll_clip);
    }

    // 再叠加悬浮 Toast 灵动胶囊或原位速览浮层（确保浮层遮罩自然压暗下层正文！）
    {
        let mut canvas = PixelCanvas::new(dib_pixels, w, h);
        if st.show_highlights_overlay && st.view_mode == ActiveViewMode::MainList {
            layout_and_draw_highlights_overlay(
                &mut canvas,
                &mut overlay_texts,
                w,
                h,
                scale,
                &palette,
                st,
            );
        } else if st.show_quick_look {
            layout_and_draw_quick_look_overlay(
                &mut canvas,
                &mut overlay_texts,
                w,
                h,
                scale,
                &palette,
                st,
            );
        } else if let Some(toast) = st.toast_message.clone() {
            layout_and_draw_toast_pill(
                &mut canvas,
                &mut overlay_texts,
                w,
                h,
                scale,
                &palette,
                st,
                &toast,
            );
        } else if st.store.has_active_undo(now_unix_secs()) {
            layout_and_draw_toast_pill(
                &mut canvas,
                &mut overlay_texts,
                w,
                h,
                scale,
                &palette,
                st,
                "已删除记录 · Ctrl+Z 可恢复",
            );
        }
        composite_texts_premultiplied_alpha(hdc, &mut canvas, &overlay_texts, scale, None);
    }

    let _ = GdiFlush();
}

// ============================================================================
// 1:1 复刻 macOS `ClipboardPopoverView` 主视图布局
// ============================================================================

fn layout_and_draw_main_view(
    canvas: &mut PixelCanvas,
    texts: &mut Vec<TextDrawCmd>,
    w: i32,
    h: i32,
    scale: f32,
    palette: &GlassPalette,
    st: &mut WinAppState,
) {
    let s = |v: i32| ((v as f32) * scale).round() as i32;
    let sf = |v: f32| v * scale;

    let pad = s(14);
    let track_w = w - pad * 2;
    let minimal = st.store.config.minimal_mode_enabled;
    let always_top = st.store.config.always_on_top;

    // 1. 顶栏 `headerBar`：左侧全圆胶囊搜索栏 + 右侧圆形玻璃按钮簇（复刻 ClipboardPopoverView.swift:580-712）
    let btn_sz = s(32);
    let btn_gap = s(6);
    let btn_count = if minimal { 4 } else { 5 };
    let cluster_w = btn_sz * btn_count + btn_gap * (btn_count - 1);
    let search_w = track_w - cluster_w - s(8);
    let top_y = s(14);

    canvas.fill_round_rect(pad, top_y, search_w, btn_sz, sf(16.0), palette.search_bg);
    canvas.stroke_round_rect(
        pad,
        top_y,
        search_w,
        btn_sz,
        sf(16.0),
        sf(0.8),
        if st.search_query.is_empty() {
            palette.search_border
        } else {
            palette.cobalt.with_alpha(135)
        },
    );
    canvas.draw_icon_search(
        (pad + s(16)) as f32,
        (top_y + btn_sz / 2) as f32,
        sf(13.5),
        sf(1.55),
        palette.text_secondary,
    );

    let search_text_right = if st.search_query.is_empty() {
        pad + search_w - s(10)
    } else {
        let clear_rc = RECT {
            left: pad + search_w - s(26),
            top: top_y + s(5),
            right: pad + search_w - s(6),
            bottom: top_y + btn_sz - s(5),
        };
        let ccx = (clear_rc.left + clear_rc.right) as f32 * 0.5;
        let ccy = (clear_rc.top + clear_rc.bottom) as f32 * 0.5;
        canvas.fill_circle(ccx, ccy, sf(7.5), palette.text_muted.with_alpha(95));
        canvas.draw_icon_close(ccx, ccy, sf(8.2), sf(1.18), Color4::rgb(255, 255, 255));
        st.hit_regions.push(HitRegion {
            rect: clear_rc,
            interactive_cursor: true,
            action: HitAction::ClearSearch,
        });
        clear_rc.left - s(4)
    };

    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: pad,
            top: top_y,
            right: search_text_right,
            bottom: top_y + btn_sz,
        },
        interactive_cursor: true,
        action: HitAction::FocusSearch,
    });

    texts.push(TextDrawCmd {
        text: if st.search_query.is_empty() {
            if st.selected_tab == ClipFilterTab::Todo {
                "搜索待办，或直接输入事项按 Enter 新建...".to_string()
            } else {
                "搜索剪贴历史...".to_string()
            }
        } else {
            st.search_query.clone()
        },
        rect: RECT {
            left: pad + s(29),
            top: top_y,
            right: search_text_right,
            bottom: top_y + btn_sz,
        },
        color: if st.search_query.is_empty() {
            palette.text_muted
        } else {
            palette.text_primary
        },
        font_kind: FontKind::Body,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
    });

    // 右侧圆形玻璃按钮序列：[队列(非极简)] · [图钉置顶] · [绿叶极简] · [暂停/监听] · [齿轮设置]
    let mut bx = pad + search_w + s(8);
    if !minimal {
        let q_active = st.store.queue_mode_active;
        let q_len = st.store.paste_queue_ids.len();
        draw_header_circle_btn(
            canvas,
            bx,
            top_y,
            btn_sz,
            scale,
            palette,
            q_active,
            palette.cobalt,
        );
        canvas.draw_icon_list_number(
            (bx + btn_sz / 2) as f32,
            (top_y + btn_sz / 2) as f32,
            sf(14.0),
            sf(1.5),
            if q_active {
                Color4::rgb(255, 255, 255)
            } else {
                palette.text_secondary
            },
        );
        if q_len > 0 {
            let b_w = s(15);
            let b_h = s(13);
            let qbx = bx + btn_sz - b_w + s(3);
            let qby = top_y - s(2);
            canvas.fill_round_rect(qbx, qby, b_w, b_h, sf(6.5), palette.amber);
            texts.push(TextDrawCmd {
                text: format!("{}", q_len.min(99)),
                rect: RECT {
                    left: qbx,
                    top: qby,
                    right: qbx + b_w,
                    bottom: qby + b_h,
                },
                color: Color4::rgb(255, 255, 255),
                font_kind: FontKind::KeyCap,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
        }
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: bx,
                top: top_y,
                right: bx + btn_sz,
                bottom: top_y + btn_sz,
            },
            interactive_cursor: true,
            action: HitAction::ToggleQueueMode,
        });
        bx += btn_sz + btn_gap;
    }

    // 图钉始终在前圆钮
    draw_header_circle_btn(
        canvas,
        bx,
        top_y,
        btn_sz,
        scale,
        palette,
        always_top,
        palette.cobalt,
    );
    canvas.draw_icon_pin(
        (bx + btn_sz / 2) as f32,
        (top_y + btn_sz / 2) as f32,
        sf(14.0),
        sf(1.5),
        if always_top {
            Color4::rgb(255, 255, 255)
        } else {
            palette.text_secondary
        },
        always_top,
    );
    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: bx,
            top: top_y,
            right: bx + btn_sz,
            bottom: top_y + btn_sz,
        },
        interactive_cursor: true,
        action: HitAction::ToggleAlwaysOnTop,
    });
    bx += btn_sz + btn_gap;

    // 绿叶极简纯净模式圆钮
    draw_header_circle_btn(
        canvas,
        bx,
        top_y,
        btn_sz,
        scale,
        palette,
        minimal,
        palette.emerald,
    );
    canvas.draw_icon_leaf(
        (bx + btn_sz / 2) as f32,
        (top_y + btn_sz / 2) as f32,
        sf(14.5),
        sf(1.5),
        if minimal {
            Color4::rgb(255, 255, 255)
        } else {
            palette.text_secondary
        },
    );
    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: bx,
            top: top_y,
            right: bx + btn_sz,
            bottom: top_y + btn_sz,
        },
        interactive_cursor: true,
        action: HitAction::ToggleMinimalMode,
    });
    bx += btn_sz + btn_gap;

    // 暂停/恢复记录圆钮
    draw_header_circle_btn(
        canvas,
        bx,
        top_y,
        btn_sz,
        scale,
        palette,
        false,
        palette.amber,
    );
    canvas.draw_icon_record_pause(
        (bx + btn_sz / 2) as f32,
        (top_y + btn_sz / 2) as f32,
        sf(15.0),
        sf(1.45),
        if st.store.is_paused {
            palette.amber
        } else {
            palette.text_secondary
        },
        st.store.is_paused,
    );
    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: bx,
            top: top_y,
            right: bx + btn_sz,
            bottom: top_y + btn_sz,
        },
        interactive_cursor: true,
        action: HitAction::TogglePauseCapture,
    });
    bx += btn_sz + btn_gap;

    // 偏好设置齿轮圆钮（检测到新版本时右上角亮起精致钴蓝更新微圆点）
    draw_header_circle_btn(
        canvas,
        bx,
        top_y,
        btn_sz,
        scale,
        palette,
        false,
        palette.cobalt,
    );
    canvas.draw_icon_gear(
        (bx + btn_sz / 2) as f32,
        (top_y + btn_sz / 2) as f32,
        sf(15.5),
        sf(1.45),
        palette.text_secondary,
    );
    if st.ota_state.available_version().is_some() {
        let dot_cx = (bx + btn_sz - s(5)) as f32;
        let dot_cy = (top_y + s(5)) as f32;
        canvas.fill_circle(dot_cx, dot_cy, sf(4.4), palette.window_bg);
        canvas.fill_circle(dot_cx, dot_cy, sf(3.2), palette.cobalt);
    }
    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: bx,
            top: top_y,
            right: bx + btn_sz,
            bottom: top_y + btn_sz,
        },
        interactive_cursor: true,
        action: HitAction::ToggleSettingsView,
    });

    // 2. iOS 滑动胶囊分类条 `filterBar`（纯白/雾白常驻滑块 + 柔和微阴影 + 120Hz 弹簧动画）
    let track_top = top_y + btn_sz + s(10);
    let track_h = s(34);
    canvas.fill_round_rect(pad, track_top, track_w, track_h, sf(17.0), palette.track_bg);
    canvas.stroke_round_rect(
        pad,
        track_top,
        track_w,
        track_h,
        sf(17.0),
        sf(0.7),
        palette.track_border,
    );

    let inset = s(3);
    let visible_tabs = ClipFilterTab::visible_tabs(minimal);
    let tab_cnt = visible_tabs.len().max(1);
    let inner_w = (track_w - inset * 2) as f32;
    let pill_wf = inner_w / (tab_cnt as f32);
    let pill_h = track_h - inset * 2;
    let clamped_ratio = st.seg_pill_ratio.clamp(0.0, (tab_cnt - 1) as f32);
    let pill_x = pad + inset + (clamped_ratio * pill_wf).round() as i32;
    let pill_w = pill_wf.round() as i32;
    let pill_y = track_top + inset;

    canvas.draw_soft_shadow_round_rect(
        pill_x,
        pill_y,
        pill_w,
        pill_h,
        (pill_h as f32) * 0.5,
        sf(1.0),
        sf(2.6),
        palette.active_segment_shadow,
    );
    canvas.fill_round_rect(
        pill_x,
        pill_y,
        pill_w,
        pill_h,
        (pill_h as f32) * 0.5,
        palette.active_segment_fill,
    );
    canvas.stroke_glass_bevel_round_rect(
        pill_x,
        pill_y,
        pill_w,
        pill_h,
        (pill_h as f32) * 0.5,
        sf(0.85),
        palette.glass_top_highlight,
        if st.is_dark_mode {
            Color4::rgba(226, 232, 240, 26)
        } else {
            palette.track_border
        },
    );

    let pending_todos = st.store.pending_todo_count();
    for (idx, tab) in visible_tabs.iter().enumerate() {
        let sx = pad + inset + ((idx as f32) * pill_wf).round() as i32;
        let sw = if idx + 1 == tab_cnt {
            pad + track_w - inset - sx
        } else {
            pill_w
        };
        let active = st.selected_tab == *tab;
        let rc = RECT {
            left: sx,
            top: pill_y,
            right: sx + sw,
            bottom: pill_y + pill_h,
        };
        if *tab == ClipFilterTab::Todo && pending_todos > 0 {
            // 独立微圆计数徽章：文字与计数清晰分离，不再等大等重挤成一团
            let cnt_str = format!("{}", pending_todos.min(99));
            let badge_w = if pending_todos >= 10 { s(17) } else { s(14) };
            let badge_h = s(14);
            let txt_w = s(24);
            let group_w = txt_w + s(3) + badge_w;
            let gx = sx + (sw - group_w) / 2;
            texts.push(TextDrawCmd {
                text: tab.title().to_string(),
                rect: RECT {
                    left: gx,
                    top: pill_y,
                    right: gx + txt_w,
                    bottom: pill_y + pill_h,
                },
                color: if active {
                    palette.text_primary
                } else {
                    palette.text_secondary
                },
                font_kind: if active {
                    FontKind::BadgeBold
                } else {
                    FontKind::Meta
                },
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            let bx_c = gx + txt_w + s(3);
            let by_c = pill_y + (pill_h - badge_h) / 2;
            canvas.fill_round_rect(
                bx_c,
                by_c,
                badge_w,
                badge_h,
                sf(7.0),
                if active {
                    palette.cobalt
                } else {
                    palette
                        .cobalt
                        .with_alpha(if st.is_dark_mode { 46 } else { 26 })
                },
            );
            texts.push(TextDrawCmd {
                text: cnt_str,
                rect: RECT {
                    left: bx_c,
                    top: by_c,
                    right: bx_c + badge_w,
                    bottom: by_c + badge_h,
                },
                color: if active {
                    Color4::rgb(255, 255, 255)
                } else {
                    palette.cobalt_text
                },
                font_kind: FontKind::KeyCap,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
        } else {
            texts.push(TextDrawCmd {
                text: tab.title().to_string(),
                rect: rc,
                color: if active {
                    palette.text_primary
                } else {
                    palette.text_secondary
                },
                font_kind: if active {
                    FontKind::BadgeBold
                } else {
                    FontKind::Meta
                },
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
        }
        st.hit_regions.push(HitRegion {
            rect: rc,
            interactive_cursor: true,
            action: HitAction::SelectTab(*tab),
        });
    }

    let mut cur_y = track_top + track_h + s(8);

    // 2.2 搜索框三合一快捷卡片（复刻 macOS InstantMathCardView / QuickCapture / @建议）
    if !minimal && !st.search_query.trim().is_empty() {
        let latest_txt = st.store.items.iter().find_map(|it| it.text.as_deref());
        if let Some(sug) = extract_suggestion_payload(&st.search_query) {
            let bh = s(44);
            canvas.fill_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(13.0),
                palette.cobalt.with_alpha(24),
            );
            canvas.stroke_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(13.0),
                sf(0.75),
                palette.cobalt.with_alpha(64),
            );
            let btn_w = s(64);
            let btn_h = s(24);
            let btn_x = w - pad - btn_w - s(10);
            let btn_y = cur_y + (bh - btn_h) / 2;
            canvas.fill_round_rect(btn_x, btn_y, btn_w, btn_h, sf(12.0), palette.cobalt);
            texts.push(TextDrawCmd {
                text: "采纳".to_string(),
                rect: RECT {
                    left: btn_x,
                    top: btn_y,
                    right: btn_x + btn_w,
                    bottom: btn_y + btn_h,
                },
                color: Color4::rgb(255, 255, 255),
                font_kind: FontKind::BadgeBold,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            texts.push(TextDrawCmd {
                text: if sug.is_empty() {
                    "一句话调教 iClip（如：开启始终在前 / 双击 Ctrl 呼出）".to_string()
                } else {
                    format!("调教指令：{sug}")
                },
                rect: RECT {
                    left: pad + s(12),
                    top: cur_y,
                    right: btn_x - s(8),
                    bottom: cur_y + bh,
                },
                color: palette.text_primary,
                font_kind: FontKind::BadgeBold,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: pad,
                    top: cur_y,
                    right: w - pad,
                    bottom: cur_y + bh,
                },
                interactive_cursor: true,
                action: HitAction::CommitSuggestion(sug),
            });
            cur_y += bh + s(8);
        } else if let Some(cap) = parse_quick_capture(&st.search_query) {
            let bh = s(44);
            let acc = if cap.default_todo {
                palette.cobalt
            } else {
                palette.emerald
            };
            canvas.fill_round_rect(pad, cur_y, track_w, bh, sf(13.0), acc.with_alpha(24));
            canvas.stroke_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(13.0),
                sf(0.75),
                acc.with_alpha(68),
            );
            let btn_w = s(64);
            let btn_h = s(24);
            let btn_x = w - pad - btn_w - s(10);
            let btn_y = cur_y + (bh - btn_h) / 2;
            canvas.fill_round_rect(btn_x, btn_y, btn_w, btn_h, sf(12.0), acc);
            texts.push(TextDrawCmd {
                text: "保存".to_string(),
                rect: RECT {
                    left: btn_x,
                    top: btn_y,
                    right: btn_x + btn_w,
                    bottom: btn_y + btn_h,
                },
                color: Color4::rgb(255, 255, 255),
                font_kind: FontKind::BadgeBold,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            let desc = if cap.body.is_empty() {
                if cap.default_todo {
                    "闪念待办：输入 `- 事项` 回车直接加入待办".to_string()
                } else {
                    "闪念速记：输入 `> 备注 :: 正文` 回车入库收藏".to_string()
                }
            } else if cap.default_todo {
                format!("新建待办：{}", cap.body)
            } else if let Some(al) = &cap.alias {
                format!("新建收藏「{al}」：{}", cap.body)
            } else {
                format!("速记入库：{}", cap.body)
            };
            texts.push(TextDrawCmd {
                text: desc,
                rect: RECT {
                    left: pad + s(12),
                    top: cur_y,
                    right: btn_x - s(8),
                    bottom: cur_y + bh,
                },
                color: palette.text_primary,
                font_kind: FontKind::BadgeBold,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: pad,
                    top: cur_y,
                    right: w - pad,
                    bottom: cur_y + bh,
                },
                interactive_cursor: true,
                action: HitAction::CommitQuickCapture,
            });
            cur_y += bh + s(8);
        } else if let Some(pw_cand) =
            iclip_core::security::evaluate_secure_password_query(&st.search_query)
        {
            let bh = s(48);
            canvas.fill_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(13.0),
                palette.cobalt.with_alpha(24),
            );
            canvas.stroke_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(13.0),
                sf(0.75),
                palette.cobalt.with_alpha(64),
            );
            let ic_cx = (pad + s(24)) as f32;
            let ic_cy = (cur_y + bh / 2) as f32;
            canvas.fill_circle(ic_cx, ic_cy, sf(13.0), palette.cobalt.with_alpha(36));
            texts.push(TextDrawCmd {
                text: "PW".to_string(),
                rect: RECT {
                    left: pad + s(11),
                    top: cur_y,
                    right: pad + s(37),
                    bottom: cur_y + bh,
                },
                color: palette.cobalt,
                font_kind: FontKind::BadgeBold,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });

            let btn_w = s(78);
            let btn_h = s(24);
            let btn_x = w - pad - btn_w - s(10);
            let btn_y = cur_y + (bh - btn_h) / 2;
            canvas.fill_round_rect(btn_x, btn_y, btn_w, btn_h, sf(12.0), palette.cobalt);
            texts.push(TextDrawCmd {
                text: "无痕键入".to_string(),
                rect: RECT {
                    left: btn_x,
                    top: btn_y,
                    right: btn_x + btn_w,
                    bottom: btn_y + btn_h,
                },
                color: Color4::rgb(255, 255, 255),
                font_kind: FontKind::BadgeBold,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });

            let pin_w = s(64);
            let pin_x = btn_x - s(6) - pin_w;
            canvas.fill_round_rect(
                pin_x,
                btn_y,
                pin_w,
                btn_h,
                sf(12.0),
                palette.cobalt.with_alpha(34),
            );
            texts.push(TextDrawCmd {
                text: "收藏".to_string(),
                rect: RECT {
                    left: pin_x,
                    top: btn_y,
                    right: pin_x + pin_w,
                    bottom: btn_y + btn_h,
                },
                color: palette.cobalt,
                font_kind: FontKind::BadgeBold,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: pin_x,
                    top: btn_y,
                    right: pin_x + pin_w,
                    bottom: btn_y + btn_h,
                },
                interactive_cursor: true,
                action: HitAction::PinGeneratedSecret {
                    secret: pw_cand.secret_value.clone(),
                    alias: pw_cand.default_vault_alias.clone(),
                },
            });

            let text_right = pin_x - s(8);
            texts.push(TextDrawCmd {
                text: pw_cand.secret_value.clone(),
                rect: RECT {
                    left: pad + s(44),
                    top: cur_y + s(5),
                    right: text_right,
                    bottom: cur_y + s(26),
                },
                color: palette.text_primary,
                font_kind: FontKind::Headline,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            texts.push(TextDrawCmd {
                text: pw_cand.subtitle,
                rect: RECT {
                    left: pad + s(44),
                    top: cur_y + s(25),
                    right: text_right,
                    bottom: cur_y + bh - s(4),
                },
                color: palette.text_secondary,
                font_kind: FontKind::Meta,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: pad,
                    top: cur_y,
                    right: w - pad,
                    bottom: cur_y + bh,
                },
                interactive_cursor: true,
                action: HitAction::CommitEphemeralSecret {
                    secret: pw_cand.secret_value,
                    toast: pw_cand.ephemeral_toast,
                },
            });
            cur_y += bh + s(8);
        } else if let Some(cap_cmd) = iclip_core::security::evaluate_secret_capsule_command(
            &st.search_query,
            st.store.latest_plain_for_capsule_lock(),
            st.store.latest_capsule_text(None),
        ) {
            let bh = s(48);
            let (badge_txt, accent, headline, subline, btn_label, primary_hit) = match &cap_cmd {
                iclip_core::security::SecretCapsuleCommand::LockReady {
                    passphrase,
                    plain_source,
                    is_inline_body,
                } => {
                    let veiled = iclip_core::security::veiled_sensitive_preview(plain_source);
                    let src_lbl = if *is_inline_body {
                        "内联正文"
                    } else {
                        "首条剪贴"
                    };
                    (
                        "LK",
                        palette.cobalt,
                        format!("端到端加密（{src_lbl}）：{veiled}"),
                        "SHA256-CTR + HMAC 防篡改信封 · Mac/Win 互通 · 明文不入库".to_string(),
                        Some("发送密文"),
                        Some(HitAction::CommitLockedCapsule {
                            plain: plain_source.clone(),
                            passphrase: passphrase.clone(),
                        }),
                    )
                }
                iclip_core::security::SecretCapsuleCommand::LockAwaitingInput { hint } => (
                    "LK",
                    palette.text_secondary,
                    "零知识口令密文信封".to_string(),
                    hint.clone(),
                    None,
                    None,
                ),
                iclip_core::security::SecretCapsuleCommand::UnlockDecrypted { decrypted_plain } => {
                    let single = decrypted_plain.replace('\r', "").replace('\n', " ");
                    (
                        "OK",
                        Color4::rgb(32, 178, 92),
                        single,
                        "✓ HMAC 校验通过 · 无痕键入不落盘 · 30s 擦除".to_string(),
                        Some("无痕键入"),
                        Some(HitAction::CommitEphemeralSecret {
                            secret: decrypted_plain.clone(),
                            toast: "已无痕键入解锁明文（不写入历史 · 30s后自动擦除）".to_string(),
                        }),
                    )
                }
                iclip_core::security::SecretCapsuleCommand::UnlockPending {
                    has_target_capsule,
                    attempted_passphrase,
                } => {
                    if !has_target_capsule {
                        (
                            "LK",
                            palette.text_secondary,
                            "未在剪贴历史中发现 ICLPMSG1 密文信封".to_string(),
                            "先在微信/飞书复制对方发来的密文，再输入 @解锁 口令".to_string(),
                            None,
                            None,
                        )
                    } else {
                        (
                            "KY",
                            if *attempted_passphrase {
                                Color4::rgb(245, 146, 28)
                            } else {
                                palette.cobalt
                            },
                            if *attempted_passphrase {
                                "等待正确口令解锁密文信封…".to_string()
                            } else {
                                "检测到端到端加密信封 · 请输入解锁口令".to_string()
                            },
                            "离线零联网解密 · 口令匹配即刻显影（明文绝不写入磁盘）".to_string(),
                            None,
                            None,
                        )
                    }
                }
            };

            canvas.fill_round_rect(pad, cur_y, track_w, bh, sf(13.0), accent.with_alpha(24));
            canvas.stroke_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(13.0),
                sf(0.75),
                accent.with_alpha(64),
            );
            let ic_cx = (pad + s(24)) as f32;
            let ic_cy = (cur_y + bh / 2) as f32;
            canvas.fill_circle(ic_cx, ic_cy, sf(13.0), accent.with_alpha(36));
            texts.push(TextDrawCmd {
                text: badge_txt.to_string(),
                rect: RECT {
                    left: pad + s(11),
                    top: cur_y,
                    right: pad + s(37),
                    bottom: cur_y + bh,
                },
                color: accent,
                font_kind: FontKind::BadgeBold,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });

            let mut text_right = w - pad - s(12);
            if let Some(lbl) = btn_label {
                let btn_w = s(78);
                let btn_h = s(24);
                let btn_x = w - pad - btn_w - s(10);
                let btn_y = cur_y + (bh - btn_h) / 2;
                canvas.fill_round_rect(btn_x, btn_y, btn_w, btn_h, sf(12.0), accent);
                texts.push(TextDrawCmd {
                    text: lbl.to_string(),
                    rect: RECT {
                        left: btn_x,
                        top: btn_y,
                        right: btn_x + btn_w,
                        bottom: btn_y + btn_h,
                    },
                    color: Color4::rgb(255, 255, 255),
                    font_kind: FontKind::BadgeBold,
                    flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                });
                text_right = btn_x - s(8);
                if let Some(hit) = primary_hit {
                    st.hit_regions.push(HitRegion {
                        rect: RECT {
                            left: pad,
                            top: cur_y,
                            right: w - pad,
                            bottom: cur_y + bh,
                        },
                        interactive_cursor: true,
                        action: hit,
                    });
                }
            }
            texts.push(TextDrawCmd {
                text: headline,
                rect: RECT {
                    left: pad + s(44),
                    top: cur_y + s(5),
                    right: text_right,
                    bottom: cur_y + s(26),
                },
                color: palette.text_primary,
                font_kind: FontKind::Headline,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            texts.push(TextDrawCmd {
                text: subline,
                rect: RECT {
                    left: pad + s(44),
                    top: cur_y + s(25),
                    right: text_right,
                    bottom: cur_y + bh - s(4),
                },
                color: palette.text_secondary,
                font_kind: FontKind::Meta,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            cur_y += bh + s(8);
        } else if iclip_core::security::is_security_audit_query(&st.search_query) {
            let risk_cnt = st.store.unpinned_sensitive_count();
            let pinned_sec = st.store.pinned_sensitive_count();
            let total_cnt = st.store.items.len();
            let is_clean = risk_cnt == 0;
            let accent = if is_clean {
                Color4::rgb(32, 178, 92)
            } else {
                Color4::rgb(245, 146, 28)
            };
            let bh = s(48);
            canvas.fill_round_rect(pad, cur_y, track_w, bh, sf(13.0), accent.with_alpha(24));
            canvas.stroke_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(13.0),
                sf(0.75),
                accent.with_alpha(68),
            );
            let ic_cx = (pad + s(24)) as f32;
            let ic_cy = (cur_y + bh / 2) as f32;
            canvas.fill_circle(ic_cx, ic_cy, sf(13.0), accent.with_alpha(38));
            texts.push(TextDrawCmd {
                text: "SH".to_string(),
                rect: RECT {
                    left: pad + s(11),
                    top: cur_y,
                    right: pad + s(37),
                    bottom: cur_y + bh,
                },
                color: accent,
                font_kind: FontKind::BadgeBold,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });

            let btn_w = if is_clean { s(68) } else { s(88) };
            let btn_h = s(24);
            let btn_x = w - pad - btn_w - s(10);
            let btn_y = cur_y + (bh - btn_h) / 2;
            if is_clean {
                canvas.fill_round_rect(btn_x, btn_y, btn_w, btn_h, sf(12.0), accent.with_alpha(36));
                texts.push(TextDrawCmd {
                    text: "护盾全开".to_string(),
                    rect: RECT {
                        left: btn_x,
                        top: btn_y,
                        right: btn_x + btn_w,
                        bottom: btn_y + btn_h,
                    },
                    color: accent,
                    font_kind: FontKind::BadgeBold,
                    flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                });
            } else {
                canvas.fill_round_rect(btn_x, btn_y, btn_w, btn_h, sf(12.0), accent);
                texts.push(TextDrawCmd {
                    text: format!("一键清零 ({risk_cnt})"),
                    rect: RECT {
                        left: btn_x,
                        top: btn_y,
                        right: btn_x + btn_w,
                        bottom: btn_y + btn_h,
                    },
                    color: Color4::rgb(255, 255, 255),
                    font_kind: FontKind::BadgeBold,
                    flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                });
                st.hit_regions.push(HitRegion {
                    rect: RECT {
                        left: btn_x,
                        top: btn_y,
                        right: btn_x + btn_w,
                        bottom: btn_y + btn_h,
                    },
                    interactive_cursor: true,
                    action: HitAction::SweepUnpinnedSensitive,
                });
            }

            let text_right = btn_x - s(8);
            let headline = if is_clean {
                format!("✓ 零临时风险残留 · {pinned_sec} 项收藏密钥受保护")
            } else {
                format!("检出 {risk_cnt} 项未收藏敏感/投毒风险 · 收藏豁免")
            };
            let stealth_lbl = if st.store.config.screen_share_privacy {
                "开启"
            } else {
                "关闭"
            };
            let veil_lbl = if st.store.config.mask_sensitive_previews {
                "开启"
            } else {
                "关闭"
            };
            let subline =
                format!("DPAPI已加密 {total_cnt} 条 · 投屏隐身{stealth_lbl} · 防肩窥{veil_lbl}");
            texts.push(TextDrawCmd {
                text: headline,
                rect: RECT {
                    left: pad + s(44),
                    top: cur_y + s(5),
                    right: text_right,
                    bottom: cur_y + s(26),
                },
                color: palette.text_primary,
                font_kind: FontKind::Headline,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            texts.push(TextDrawCmd {
                text: subline,
                rect: RECT {
                    left: pad + s(44),
                    top: cur_y + s(25),
                    right: text_right,
                    bottom: cur_y + bh - s(4),
                },
                color: palette.text_secondary,
                font_kind: FontKind::Meta,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            cur_y += bh + s(8);
        } else if let Some(math) = evaluate_instant_math(&st.search_query, latest_txt) {
            let bh = s(48);
            canvas.fill_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(13.0),
                palette.cobalt.with_alpha(24),
            );
            canvas.stroke_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(13.0),
                sf(0.75),
                palette.cobalt.with_alpha(64),
            );
            let ic_cx = (pad + s(24)) as f32;
            let ic_cy = (cur_y + bh / 2) as f32;
            canvas.fill_circle(
                ic_cx,
                ic_cy,
                sf(13.0),
                palette
                    .cobalt
                    .with_alpha(if st.is_dark_mode { 48 } else { 28 }),
            );
            texts.push(TextDrawCmd {
                text: "fx".to_string(),
                rect: RECT {
                    left: pad + s(11),
                    top: cur_y,
                    right: pad + s(37),
                    bottom: cur_y + bh,
                },
                color: palette.cobalt_text,
                font_kind: FontKind::Mono,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });

            let btn_w = s(54);
            let btn_h = s(24);
            let btn_x = w - pad - btn_w - s(10);
            let btn_y = cur_y + (bh - btn_h) / 2;
            canvas.fill_round_rect(btn_x, btn_y, btn_w, btn_h, sf(12.0), palette.cobalt);
            texts.push(TextDrawCmd {
                text: "键入".to_string(),
                rect: RECT {
                    left: btn_x,
                    top: btn_y,
                    right: btn_x + btn_w,
                    bottom: btn_y + btn_h,
                },
                color: Color4::rgb(255, 255, 255),
                font_kind: FontKind::BadgeBold,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });

            let mut text_right = btn_x - s(8);
            if let Some(rmb) = &math.rmb_uppercase {
                let rmb_w = s(64);
                let rmb_x = btn_x - s(6) - rmb_w;
                canvas.fill_round_rect(
                    rmb_x,
                    btn_y,
                    rmb_w,
                    btn_h,
                    sf(12.0),
                    palette
                        .cobalt
                        .with_alpha(if st.is_dark_mode { 44 } else { 24 }),
                );
                texts.push(TextDrawCmd {
                    text: "财务大写".to_string(),
                    rect: RECT {
                        left: rmb_x,
                        top: btn_y,
                        right: rmb_x + rmb_w,
                        bottom: btn_y + btn_h,
                    },
                    color: palette.cobalt_text,
                    font_kind: FontKind::BadgeBold,
                    flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                });
                st.hit_regions.push(HitRegion {
                    rect: RECT {
                        left: rmb_x,
                        top: btn_y,
                        right: rmb_x + rmb_w,
                        bottom: btn_y + btn_h,
                    },
                    interactive_cursor: true,
                    action: HitAction::CommitMathResult(rmb.clone()),
                });
                text_right = rmb_x - s(8);
            }

            texts.push(TextDrawCmd {
                text: format!("= {}", math.plain_value),
                rect: RECT {
                    left: pad + s(44),
                    top: cur_y + s(4),
                    right: text_right,
                    bottom: cur_y + s(27),
                },
                color: palette.text_primary,
                font_kind: FontKind::Display,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            let sub = math
                .rmb_uppercase
                .clone()
                .unwrap_or_else(|| math.expression_display.clone());
            texts.push(TextDrawCmd {
                text: sub,
                rect: RECT {
                    left: pad + s(44),
                    top: cur_y + s(25),
                    right: text_right,
                    bottom: cur_y + bh - s(4),
                },
                color: palette.text_secondary,
                font_kind: FontKind::Meta,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: pad,
                    top: cur_y,
                    right: w - pad,
                    bottom: cur_y + bh,
                },
                interactive_cursor: true,
                action: HitAction::CommitMathResult(math.plain_value),
            });
            cur_y += bh + s(8);
        } else if st.selected_tab == ClipFilterTab::Todo {
            let trimmed_q = st.search_query.trim();
            if !trimmed_q.is_empty() && !trimmed_q.starts_with('@') {
                let bh = s(40);
                canvas.fill_round_rect(
                    pad,
                    cur_y,
                    track_w,
                    bh,
                    sf(11.0),
                    palette.cobalt.with_alpha(26),
                );
                canvas.stroke_round_rect(
                    pad,
                    cur_y,
                    track_w,
                    bh,
                    sf(11.0),
                    sf(0.8),
                    palette.cobalt.with_alpha(86),
                );
                let cur_matches = st.store.filtered_indices_ext(
                    st.selected_tab,
                    st.selected_pin_category,
                    &st.search_query,
                    st.active_target_app_name.as_deref(),
                );
                let hint_txt = if cur_matches.is_empty() {
                    format!("+ 新建待办：「{trimmed_q}」 · 按 Enter 直接入库")
                } else {
                    format!("+ 新建待办：「{trimmed_q}」 · 按 Ctrl+Enter 新建")
                };
                texts.push(TextDrawCmd {
                    text: hint_txt,
                    rect: RECT {
                        left: pad + s(12),
                        top: cur_y,
                        right: w - pad - s(12),
                        bottom: cur_y + bh,
                    },
                    color: palette.cobalt,
                    font_kind: FontKind::BadgeBold,
                    flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                });
                st.hit_regions.push(HitRegion {
                    rect: RECT {
                        left: pad,
                        top: cur_y,
                        right: w - pad,
                        bottom: cur_y + bh,
                    },
                    interactive_cursor: true,
                    action: HitAction::CreateInlineTodo,
                });
                cur_y += bh + s(8);
            }
        }
    }

    // 2.3 待办统计栏 / 收藏分组胶囊栏 / 顺序队列提示条 / Ctrl+R 内联备注条
    if !minimal && st.selected_tab == ClipFilterTab::Todo {
        let done_todos = st.store.completed_todo_count();
        if pending_todos > 0 || done_todos > 0 {
            let sub_h = s(24);
            let dot_c = if pending_todos > 0 {
                palette.cobalt
            } else {
                palette.emerald
            };
            canvas.fill_circle(
                (pad + s(5)) as f32,
                (cur_y + sub_h / 2) as f32,
                sf(3.2),
                dot_c,
            );
            let status_txt = if pending_todos > 0 {
                format!("待完成 {pending_todos} 项 · Ctrl+T 勾销")
            } else {
                "待办已全部完成 · Ctrl+T 可还原".to_string()
            };
            let right_btns_w = if done_todos > 0 { s(168) } else { s(66) };
            texts.push(TextDrawCmd {
                text: status_txt,
                rect: RECT {
                    left: pad + s(13),
                    top: cur_y,
                    right: w - pad - right_btns_w,
                    bottom: cur_y + sub_h,
                },
                color: palette.text_secondary,
                font_kind: FontKind::Meta,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });

            let mut right_edge = w - pad;
            if done_todos > 0 {
                let bw = s(98);
                let bx = right_edge - bw;
                right_edge = bx - s(5);
                canvas.fill_round_rect(
                    bx,
                    cur_y,
                    bw,
                    sub_h,
                    sf(12.0),
                    palette.cobalt.with_alpha(30),
                );
                texts.push(TextDrawCmd {
                    text: format!("归档已完成 ({done_todos})"),
                    rect: RECT {
                        left: bx,
                        top: cur_y,
                        right: bx + bw,
                        bottom: cur_y + sub_h,
                    },
                    color: palette.cobalt,
                    font_kind: FontKind::BadgeBold,
                    flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                });
                st.hit_regions.push(HitRegion {
                    rect: RECT {
                        left: bx,
                        top: cur_y,
                        right: bx + bw,
                        bottom: cur_y + sub_h,
                    },
                    interactive_cursor: true,
                    action: HitAction::ArchiveCompletedTodos,
                });
            }

            let md_w = s(62);
            let md_x = right_edge - md_w;
            canvas.fill_round_rect(md_x, cur_y, md_w, sub_h, sf(12.0), palette.track_bg);
            texts.push(TextDrawCmd {
                text: "复制清单".to_string(),
                rect: RECT {
                    left: md_x,
                    top: cur_y,
                    right: md_x + md_w,
                    bottom: cur_y + sub_h,
                },
                color: palette.text_secondary,
                font_kind: FontKind::Meta,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: md_x,
                    top: cur_y,
                    right: md_x + md_w,
                    bottom: cur_y + sub_h,
                },
                interactive_cursor: true,
                action: HitAction::CopyTodosMarkdown,
            });
            cur_y += sub_h + s(8);
        }
    }

    // `@敏感` / `@即焚` 安全体检汇总栏（支持 1 秒无痕清扫所有未收藏高敏残留）
    if !minimal && st.selected_tab != ClipFilterTab::Todo {
        let q_low = st.search_query.trim().to_lowercase();
        let is_audit_q = [
            "@敏感", "@密钥", "@隐私", "@secret", "敏感", "@即焚", "@burn",
        ]
        .iter()
        .any(|k| {
            q_low == *k || q_low.starts_with(&format!("{k} ")) || q_low.ends_with(&format!(" {k}"))
        });
        let unpinned_sec_cnt = if is_audit_q {
            st.store.unpinned_sensitive_count()
        } else {
            0
        };
        if unpinned_sec_cnt > 0 {
            let sub_h = s(24);
            canvas.fill_circle(
                (pad + s(7)) as f32,
                (cur_y + sub_h / 2) as f32,
                sf(3.3),
                palette.amber,
            );
            texts.push(TextDrawCmd {
                text: format!("检出 {unpinned_sec_cnt} 条未收藏敏感凭据 · 收藏项永久保护"),
                rect: RECT {
                    left: pad + s(16),
                    top: cur_y,
                    right: w - pad - s(88),
                    bottom: cur_y + sub_h,
                },
                color: palette.text_primary,
                font_kind: FontKind::Meta,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            let sw_w = s(80);
            let sw_x = w - pad - sw_w;
            canvas.fill_round_rect(
                sw_x,
                cur_y,
                sw_w,
                sub_h,
                sf(12.0),
                palette.amber.with_alpha(36),
            );
            texts.push(TextDrawCmd {
                text: "一键清扫".to_string(),
                rect: RECT {
                    left: sw_x,
                    top: cur_y,
                    right: sw_x + sw_w,
                    bottom: cur_y + sub_h,
                },
                color: palette.amber,
                font_kind: FontKind::BadgeBold,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: sw_x,
                    top: cur_y,
                    right: sw_x + sw_w,
                    bottom: cur_y + sub_h,
                },
                interactive_cursor: true,
                action: HitAction::SweepUnpinnedSensitive,
            });
            cur_y += sub_h + s(8);
        }
    }

    if !minimal && st.selected_tab == ClipFilterTab::Pinned {
        let sub_h = s(24);
        let sub_gap = s(5);
        let opts: [Option<PinCategory>; 5] = [
            None,
            Some(PinCategory::Reply),
            Some(PinCategory::Invoice),
            Some(PinCategory::Contact),
            Some(PinCategory::Template),
        ];
        let cell_w = (track_w - sub_gap * 4) / 5;
        for (i, opt_cat) in opts.iter().enumerate() {
            let cx = pad + (i as i32) * (cell_w + sub_gap);
            let cw = if i == 4 { w - pad - cx } else { cell_w };
            let active = st.selected_pin_category == *opt_cat;
            let accent = opt_cat
                .map(GlassPalette::pin_category_color)
                .unwrap_or(palette.cobalt);
            canvas.fill_round_rect(
                cx,
                cur_y,
                cw,
                sub_h,
                sf(12.0),
                if active { accent } else { palette.chip_bg },
            );
            if let Some(_cat) = opt_cat {
                let dot_c = if active {
                    Color4::rgb(255, 255, 255)
                } else {
                    accent
                };
                canvas.fill_circle(
                    (cx + s(11)) as f32,
                    (cur_y + sub_h / 2) as f32,
                    sf(2.8),
                    dot_c,
                );
            }
            let rc = RECT {
                left: if opt_cat.is_some() { cx + s(8) } else { cx },
                top: cur_y,
                right: cx + cw,
                bottom: cur_y + sub_h,
            };
            texts.push(TextDrawCmd {
                text: opt_cat.map(|c| c.title()).unwrap_or("全部收藏").to_string(),
                rect: rc,
                color: if active {
                    Color4::rgb(255, 255, 255)
                } else {
                    palette.text_secondary
                },
                font_kind: if active {
                    FontKind::BadgeBold
                } else {
                    FontKind::Meta
                },
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: cx,
                    top: cur_y,
                    right: cx + cw,
                    bottom: cur_y + sub_h,
                },
                interactive_cursor: true,
                action: HitAction::SelectPinCategory(*opt_cat),
            });
        }
        cur_y += sub_h + s(8);
    }

    if !minimal && (st.store.queue_mode_active || !st.store.paste_queue_ids.is_empty()) {
        let qh = s(30);
        canvas.fill_round_rect(
            pad,
            cur_y,
            track_w,
            qh,
            sf(11.0),
            palette.cobalt.with_alpha(24),
        );
        let hk_q = st.store.config.hotkey_queue_pop.compact_string();
        texts.push(TextDrawCmd {
            text: format!(
                "顺序队列 · 已排 {} 项 · 按 {hk_q} 依次粘贴",
                st.store.paste_queue_ids.len()
            ),
            rect: RECT {
                left: pad + s(10),
                top: cur_y,
                right: w - pad - s(30),
                bottom: cur_y + qh,
            },
            color: palette.cobalt,
            font_kind: FontKind::BadgeBold,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
        let cx = w - pad - s(24);
        let cy = cur_y + s(5);
        canvas.fill_circle(
            (cx + s(10)) as f32,
            (cy + s(10)) as f32,
            sf(9.0),
            palette.chip_bg,
        );
        canvas.draw_icon_close(
            (cx + s(10)) as f32,
            (cy + s(10)) as f32,
            sf(8.0),
            sf(1.4),
            palette.text_secondary,
        );
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: cx,
                top: cy,
                right: cx + s(20),
                bottom: cy + s(20),
            },
            interactive_cursor: true,
            action: HitAction::ClearQueue,
        });
        cur_y += qh + s(8);
    }

    // 内联备注编辑条（1:1 复刻 ClipboardPopoverView.swift:865 inlineAliasEditorBar）
    if st.editing_alias_item_id.is_some() {
        let ah = s(34);
        canvas.fill_round_rect(pad, cur_y, track_w, ah, sf(11.0), palette.card_bg);
        canvas.stroke_round_rect(
            pad,
            cur_y,
            track_w,
            ah,
            sf(11.0),
            sf(1.0),
            palette.cobalt.with_alpha(135),
        );
        let save_w = s(46);
        let save_x = w - pad - s(30) - save_w;
        let save_y = cur_y + s(5);
        canvas.fill_round_rect(save_x, save_y, save_w, ah - s(10), sf(10.0), palette.cobalt);
        texts.push(TextDrawCmd {
            text: "保存".to_string(),
            rect: RECT {
                left: save_x,
                top: save_y,
                right: save_x + save_w,
                bottom: save_y + ah - s(10),
            },
            color: Color4::rgb(255, 255, 255),
            font_kind: FontKind::BadgeBold,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: save_x,
                top: save_y,
                right: save_x + save_w,
                bottom: save_y + ah - s(10),
            },
            interactive_cursor: true,
            action: HitAction::SaveAliasEdit,
        });

        let x_rc = RECT {
            left: w - pad - s(26),
            top: cur_y + s(7),
            right: w - pad - s(6),
            bottom: cur_y + ah - s(7),
        };
        canvas.draw_icon_close(
            (x_rc.left + x_rc.right) as f32 * 0.5,
            (x_rc.top + x_rc.bottom) as f32 * 0.5,
            sf(8.5),
            sf(1.5),
            palette.text_secondary,
        );
        st.hit_regions.push(HitRegion {
            rect: x_rc,
            interactive_cursor: true,
            action: HitAction::CloseOverlay,
        });

        texts.push(TextDrawCmd {
            text: if st.alias_draft.is_empty() {
                "输入备注名（如：深圳总公司税号），回车自动收藏...".to_string()
            } else {
                format!("备注：{}|", st.alias_draft)
            },
            rect: RECT {
                left: pad + s(12),
                top: cur_y,
                right: save_x - s(8),
                bottom: cur_y + ah,
            },
            color: if st.alias_draft.is_empty() {
                palette.text_muted
            } else {
                palette.text_primary
            },
            font_kind: FontKind::Body,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
        cur_y += ah + s(8);
    }

    // 取消生硬横穿全宽的顶部分割线，靠留白呼吸自然过渡
    cur_y += s(4);

    // 3. 剪贴卡片列表与 3 列相册网格
    let filtered = st.store.filtered_indices_ext(
        st.selected_tab,
        st.selected_pin_category,
        &st.search_query,
        st.active_target_app_name.as_deref(),
    );
    if st.selected_visible_pos >= filtered.len() {
        st.selected_visible_pos = filtered.len().saturating_sub(1);
    }

    let rows = build_display_rows_ext(
        &filtered,
        &st.store.items,
        st.selected_tab != ClipFilterTab::Todo,
    );
    if st.scroll_row_offset >= rows.len() {
        st.scroll_row_offset = rows.len().saturating_sub(1);
    }

    let footer_zone_h = s(44);
    let max_list_bottom = h - footer_zone_h - s(4);

    if rows.is_empty() {
        // 复刻 macOS emptyStateView：64x64 轻雾圆环 + 居中图标 + 双行温润提示
        let center_y = (cur_y + max_list_bottom) / 2 - s(16);
        canvas.fill_circle(
            (w / 2) as f32,
            (center_y - s(18)) as f32,
            sf(30.0),
            palette.chip_bg,
        );
        if st.search_query.is_empty() {
            canvas.draw_icon_clipboard(
                (w / 2) as f32,
                (center_y - s(18)) as f32,
                sf(26.0),
                sf(1.4),
                palette.text_muted,
            );
        } else {
            canvas.draw_icon_search(
                (w / 2) as f32,
                (center_y - s(18)) as f32,
                sf(24.0),
                sf(1.5),
                palette.text_muted,
            );
        }
        let is_todo_tab = st.selected_tab == ClipFilterTab::Todo;
        texts.push(TextDrawCmd {
            text: if st.search_query.is_empty() {
                if is_todo_tab {
                    "暂无待办事项".to_string()
                } else {
                    "暂无剪贴记录".to_string()
                }
            } else {
                "未找到匹配的内容".to_string()
            },
            rect: RECT {
                left: pad,
                top: center_y + s(20),
                right: w - pad,
                bottom: center_y + s(44),
            },
            color: palette.text_primary.with_alpha(210),
            font_kind: FontKind::Headline,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
        texts.push(TextDrawCmd {
            text: if st.search_query.is_empty() {
                if is_todo_tab {
                    "对任意剪贴记录按 Ctrl+T 加入待办，或输入 `- 事项` 回车速记".to_string()
                } else {
                    "复制文本、链接、图片或文件后将自动出现在这里".to_string()
                }
            } else {
                "试试更换关键词、拼音首字母，或按 Esc 清空搜索".to_string()
            },
            rect: RECT {
                left: pad + s(20),
                top: center_y + s(44),
                right: w - pad - s(20),
                bottom: center_y + s(68),
            },
            color: palette.text_secondary,
            font_kind: FontKind::Meta,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
    } else {
        let images_dir = st.store.images_dir.clone();
        for row in rows.iter().skip(st.scroll_row_offset) {
            match row {
                DisplayRow::ImageGridRow { cells } => {
                    let row_h = image_grid_row_height(scale);
                    let studio_h = if minimal { 0 } else { s(26) };
                    if cur_y + row_h + studio_h > max_list_bottom {
                        break;
                    }
                    let gap = s(9);
                    let tile_w = (track_w - gap * 2) / 3;
                    for (col_idx, &(vis_pos, store_idx)) in cells.iter().enumerate() {
                        let tx = pad + (col_idx as i32) * (tile_w + gap);
                        let tw = if col_idx == 2 { w - pad - tx } else { tile_w };
                        let item = st.store.items[store_idx].clone();
                        let is_sel = vis_pos == st.selected_visible_pos;
                        let is_hov = st.hovered_visible_pos == Some(vis_pos);

                        canvas.fill_round_rect(tx, cur_y, tw, row_h, sf(13.0), palette.card_bg);
                        if let Some(fname) = &item.image_file_name {
                            if let Some((iw, ih, rgba)) =
                                load_or_get_thumbnail(&mut st.thumb_cache, &images_dir, fname)
                            {
                                canvas.blit_rgba_round_rect(
                                    tx,
                                    cur_y,
                                    tw,
                                    row_h,
                                    sf(13.0),
                                    rgba,
                                    iw,
                                    ih,
                                );
                                if st.store.config.mask_sensitive_previews
                                    && !is_sel
                                    && !is_hov
                                    && item.detected_sensitive_kind().is_some()
                                {
                                    canvas.fill_round_rect(
                                        tx,
                                        cur_y,
                                        tw,
                                        row_h,
                                        sf(13.0),
                                        Color4::rgba(18, 20, 28, 212),
                                    );
                                    let pill_w = s(64);
                                    let pill_h = s(20);
                                    let px = tx + (tw - pill_w) / 2;
                                    let py = cur_y + (row_h - pill_h) / 2 - s(4);
                                    canvas.fill_round_rect(
                                        px,
                                        py,
                                        pill_w,
                                        pill_h,
                                        sf(10.0),
                                        palette.amber.with_alpha(52),
                                    );
                                    texts.push(TextDrawCmd {
                                        text: "隐私雾化".to_string(),
                                        rect: RECT {
                                            left: px,
                                            top: py,
                                            right: px + pill_w,
                                            bottom: py + pill_h,
                                        },
                                        color: Color4::rgba(255, 255, 255, 240),
                                        font_kind: FontKind::KeyCap,
                                        flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                                    });
                                }
                            }
                        }

                        // 底部 30px 渐变暗带（显示分辨率 / 备注）
                        let grad_h = s(30);
                        canvas.fill_vgrad_round_rect(
                            tx,
                            cur_y + row_h - grad_h,
                            tw,
                            grad_h,
                            sf(13.0),
                            Color4::rgba(0, 0, 0, 0),
                            Color4::rgba(0, 0, 0, 148),
                        );
                        let dim_txt = if let Some(al) = item
                            .custom_alias
                            .as_deref()
                            .filter(|a| !a.trim().is_empty())
                        {
                            al.to_string()
                        } else if let (Some(iw), Some(ih)) = (item.image_width, item.image_height) {
                            format!("{iw}×{ih}")
                        } else {
                            "PNG".to_string()
                        };
                        texts.push(TextDrawCmd {
                            text: dim_txt,
                            rect: RECT {
                                left: tx + s(7),
                                top: cur_y + row_h - s(20),
                                right: tx + tw - s(7),
                                bottom: cur_y + row_h - s(3),
                            },
                            color: Color4::rgba(255, 255, 255, 236),
                            font_kind: FontKind::KeyCap,
                            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                        });

                        // 左上角 ^1 胶囊（复刻 ClipImageGridTile.swift:125）
                        if vis_pos < 9 {
                            let bw = s(28);
                            let bh = s(17);
                            let bx = tx + s(6);
                            let by = cur_y + s(6);
                            canvas.fill_round_rect(
                                bx,
                                by,
                                bw,
                                bh,
                                sf(8.5),
                                if is_sel {
                                    palette.cobalt
                                } else {
                                    Color4::rgba(0, 0, 0, 134)
                                },
                            );
                            texts.push(TextDrawCmd {
                                text: format!("^{}", vis_pos + 1),
                                rect: RECT {
                                    left: bx,
                                    top: by,
                                    right: bx + bw,
                                    bottom: by + bh,
                                },
                                color: Color4::rgb(255, 255, 255),
                                font_kind: FontKind::KeyCap,
                                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                            });
                        }

                        // 右上角悬停微圆钮或选中回车圆标
                        if is_hov {
                            let b_sz = s(22);
                            let del_x = tx + tw - b_sz - s(5);
                            let pin_x = del_x - b_sz - s(4);
                            let by = cur_y + s(5);

                            canvas.fill_circle(
                                (pin_x + b_sz / 2) as f32,
                                (by + b_sz / 2) as f32,
                                sf(11.0),
                                Color4::rgba(18, 22, 28, 178),
                            );
                            canvas.draw_icon_star(
                                (pin_x + b_sz / 2) as f32,
                                (by + b_sz / 2) as f32,
                                sf(11.5),
                                sf(1.4),
                                if item.is_pinned {
                                    palette.amber
                                } else {
                                    Color4::rgb(255, 255, 255)
                                },
                                item.is_pinned,
                            );
                            st.hit_regions.push(HitRegion {
                                rect: RECT {
                                    left: pin_x,
                                    top: by,
                                    right: pin_x + b_sz,
                                    bottom: by + b_sz,
                                },
                                interactive_cursor: true,
                                action: HitAction::TogglePin(item.id.clone()),
                            });

                            canvas.fill_circle(
                                (del_x + b_sz / 2) as f32,
                                (by + b_sz / 2) as f32,
                                sf(11.0),
                                Color4::rgba(18, 22, 28, 178),
                            );
                            canvas.draw_icon_trash(
                                (del_x + b_sz / 2) as f32,
                                (by + b_sz / 2) as f32,
                                sf(11.0),
                                sf(1.4),
                                Color4::rgb(255, 112, 104),
                            );
                            st.hit_regions.push(HitRegion {
                                rect: RECT {
                                    left: del_x,
                                    top: by,
                                    right: del_x + b_sz,
                                    bottom: by + b_sz,
                                },
                                interactive_cursor: true,
                                action: HitAction::DeleteItem(item.id.clone()),
                            });
                        } else if is_sel {
                            let r_cx = (tx + tw - s(15)) as f32;
                            let r_cy = (cur_y + s(15)) as f32;
                            canvas.fill_circle(r_cx, r_cy, sf(9.5), palette.cobalt);
                            canvas.stroke_circle(
                                r_cx,
                                r_cy,
                                sf(9.5),
                                sf(1.0),
                                Color4::rgb(255, 255, 255),
                            );
                            canvas.draw_icon_return_arrow(
                                r_cx,
                                r_cy,
                                sf(9.5),
                                sf(1.4),
                                Color4::rgb(255, 255, 255),
                            );
                        }

                        // 外白内蓝双环选中框（复刻 ClipImageGridTile.swift:204）
                        if is_sel {
                            canvas.stroke_round_rect(
                                tx,
                                cur_y,
                                tw,
                                row_h,
                                sf(13.0),
                                sf(3.2),
                                Color4::rgba(255, 255, 255, 232),
                            );
                            canvas.stroke_round_rect(
                                tx,
                                cur_y,
                                tw,
                                row_h,
                                sf(13.0),
                                sf(2.0),
                                palette.cobalt,
                            );
                        } else {
                            let bd = if item.is_pinned {
                                palette.amber.with_alpha(190)
                            } else if is_hov {
                                palette.card_hover_border
                            } else {
                                palette.card_border
                            };
                            canvas.stroke_round_rect(tx, cur_y, tw, row_h, sf(13.0), sf(0.85), bd);
                        }

                        st.hit_regions.push(HitRegion {
                            rect: RECT {
                                left: tx,
                                top: cur_y,
                                right: tx + tw,
                                bottom: cur_y + row_h,
                            },
                            interactive_cursor: false,
                            action: HitAction::SelectCard(vis_pos),
                        });
                    }

                    // 零抖动常驻轻雾图片工作坊胶囊条
                    if !minimal && !cells.is_empty() {
                        let target_store_idx = cells
                            .iter()
                            .find(|(vp, _)| *vp == st.selected_visible_pos)
                            .map(|(_, si)| *si)
                            .unwrap_or(cells[0].1);
                        let chip_y = cur_y + row_h + s(4);
                        let chip_h = s(20);
                        let mut cx = pad;
                        for (lbl, is_jpg) in [("轻量瘦身 JPEG", true), ("圆角阴影样机图", false)]
                        {
                            let cw = s(102);
                            canvas.fill_round_rect(
                                cx,
                                chip_y,
                                cw,
                                chip_h,
                                sf(10.0),
                                palette.chip_bg,
                            );
                            texts.push(TextDrawCmd {
                                text: lbl.to_string(),
                                rect: RECT {
                                    left: cx + s(6),
                                    top: chip_y,
                                    right: cx + cw - s(6),
                                    bottom: chip_y + chip_h,
                                },
                                color: palette.text_secondary,
                                font_kind: FontKind::Meta,
                                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                            });
                            st.hit_regions.push(HitRegion {
                                rect: RECT {
                                    left: cx,
                                    top: chip_y,
                                    right: cx + cw,
                                    bottom: chip_y + chip_h,
                                },
                                interactive_cursor: true,
                                action: if is_jpg {
                                    HitAction::CompressImageJpeg(target_store_idx)
                                } else {
                                    HitAction::MockupImagePng(target_store_idx)
                                },
                            });
                            cx += cw + s(6);
                        }
                    }
                    cur_y += row_h + studio_h + s(9);
                }

                DisplayRow::StandardCard { vis_pos, store_idx } => {
                    let vis_pos = *vis_pos;
                    let store_idx = *store_idx;
                    let item = st.store.items[store_idx].clone();
                    let is_selected = vis_pos == st.selected_visible_pos;
                    let is_hovered = st.hovered_visible_pos == Some(vis_pos);

                    let quick_actions = item_quick_actions_for_ui(st, &item);
                    let has_chips = !quick_actions.is_empty();
                    let card_h = standard_card_height(has_chips, scale);
                    if cur_y + card_h > max_list_bottom {
                        break;
                    }

                    // 现代液态玻璃卡片材质：选中态采用轻透冰蓝玻璃层 + 左侧 3px 圆头精选指示条（彻底消除塑料大蓝块与溢出阴影）
                    if is_selected {
                        canvas.fill_round_rect(
                            pad,
                            cur_y,
                            track_w,
                            card_h,
                            sf(14.0),
                            palette.card_bg,
                        );
                        canvas.fill_diag_grad_round_rect(
                            pad,
                            cur_y,
                            track_w,
                            card_h,
                            sf(14.0),
                            palette.select_top,
                            palette.select_bottom,
                        );
                        canvas.stroke_glass_bevel_round_rect(
                            pad,
                            cur_y,
                            track_w,
                            card_h,
                            sf(14.0),
                            sf(0.95),
                            palette.glass_top_highlight,
                            palette.select_border,
                        );
                        // 左侧 3px 圆头品牌电光钴蓝精选指示条（上下收紧至卡片高度 58%，远离卡片外圆角拐点）
                        let ind_h = ((card_h as f32) * 0.58).round() as i32;
                        canvas.fill_round_rect(
                            pad + s(1),
                            cur_y + (card_h - ind_h) / 2,
                            s(3),
                            ind_h.max(s(22)),
                            sf(1.5),
                            palette.select_indicator,
                        );
                    } else if item.is_pinned {
                        let (pt, pb) = if is_hovered {
                            (
                                palette.card_pinned_hover_top,
                                palette.card_pinned_hover_bottom,
                            )
                        } else {
                            (palette.card_pinned_top, palette.card_pinned_bottom)
                        };
                        canvas.fill_diag_grad_round_rect(
                            pad,
                            cur_y,
                            track_w,
                            card_h,
                            sf(14.0),
                            pt,
                            pb,
                        );
                        canvas.stroke_glass_bevel_round_rect(
                            pad,
                            cur_y,
                            track_w,
                            card_h,
                            sf(14.0),
                            sf(0.85),
                            palette.glass_top_highlight,
                            palette.card_pinned_border,
                        );
                    } else {
                        let bg = if is_hovered {
                            palette.card_hover_bg
                        } else {
                            palette.card_bg
                        };
                        let bd = if is_hovered {
                            palette.card_hover_border
                        } else {
                            palette.card_border
                        };
                        canvas.fill_round_rect(pad, cur_y, track_w, card_h, sf(14.0), bg);
                        canvas.stroke_glass_bevel_round_rect(
                            pad,
                            cur_y,
                            track_w,
                            card_h,
                            sf(14.0),
                            sf(0.80),
                            palette.glass_top_highlight,
                            bd,
                        );
                    }

                    let mut left_cursor = pad + s(13);
                    let content_center_y = if has_chips {
                        cur_y + s(30)
                    } else {
                        cur_y + card_h / 2
                    };

                    // Things 3 风格待办圆环勾选框（复刻 TodoLeadingCheckboxButton）
                    let shows_todo = !minimal && item.is_todo();
                    let todo_done = item.is_todo_completed();
                    if shows_todo {
                        let cb_sz = s(20);
                        let cbx = left_cursor;
                        let cby = content_center_y - cb_sz / 2;
                        let ring_c = if todo_done {
                            palette.emerald
                        } else if is_selected {
                            palette.cobalt_text
                        } else {
                            palette.cobalt.with_alpha(185)
                        };
                        let chk_c = Color4::rgb(255, 255, 255);
                        canvas.draw_icon_check_circle(
                            (cbx + cb_sz / 2) as f32,
                            (cby + cb_sz / 2) as f32,
                            sf(17.5),
                            sf(1.55),
                            ring_c,
                            todo_done,
                            chk_c,
                        );
                        st.hit_regions.push(HitRegion {
                            rect: RECT {
                                left: cbx - s(3),
                                top: cby - s(3),
                                right: cbx + cb_sz + s(3),
                                bottom: cby + cb_sz + s(3),
                            },
                            interactive_cursor: true,
                            action: HitAction::ToggleTodo(item.id.clone()),
                        });
                        left_cursor += s(28);
                    }

                    // 左侧 42x42 圆角 11px 视觉徽标（复刻 LinkLaunchLogoButton：常态链环，悬停变蓝青渐变 + ↗ 发射箭头！）
                    let can_jump = item_supports_external_jump(&item);
                    if can_jump {
                        let b_sz = s(42);
                        let bx = left_cursor;
                        let by = content_center_y - b_sz / 2;
                        let badge_hov = st.hovered_link_badge_store_idx == Some(store_idx);

                        if badge_hov {
                            canvas.draw_soft_shadow_round_rect(
                                bx,
                                by,
                                b_sz,
                                b_sz,
                                sf(11.0),
                                sf(2.0),
                                sf(5.0),
                                palette.cobalt.with_alpha(86),
                            );
                            canvas.fill_diag_grad_round_rect(
                                bx,
                                by,
                                b_sz,
                                b_sz,
                                sf(11.0),
                                palette.cobalt,
                                Color4::rgb(31, 163, 250),
                            );
                        } else {
                            let bg = if is_selected {
                                palette
                                    .cobalt
                                    .with_alpha(if st.is_dark_mode { 54 } else { 32 })
                            } else {
                                palette
                                    .cobalt
                                    .with_alpha(if st.is_dark_mode { 36 } else { 24 })
                            };
                            canvas.fill_round_rect(bx, by, b_sz, b_sz, sf(11.0), bg);
                        }

                        let ic_c = if badge_hov {
                            Color4::rgb(255, 255, 255)
                        } else {
                            palette.cobalt_text
                        };
                        let ic_cx = (bx + b_sz / 2) as f32;
                        let ic_cy = (by + b_sz / 2) as f32;
                        if item.kind == ClipContentType::File {
                            canvas.draw_icon_file(ic_cx, ic_cy, sf(18.0), sf(1.55), ic_c);
                        } else if badge_hov {
                            canvas.draw_icon_external_link(ic_cx, ic_cy, sf(16.0), sf(1.75), ic_c);
                        } else {
                            canvas.draw_icon_link_chain(ic_cx, ic_cy, sf(19.0), sf(1.6), ic_c);
                        }

                        st.hit_regions.push(HitRegion {
                            rect: RECT {
                                left: bx,
                                top: by,
                                right: bx + b_sz,
                                bottom: by + b_sz,
                            },
                            interactive_cursor: true,
                            action: HitAction::OpenExternalTarget(store_idx),
                        });
                        left_cursor += b_sz + s(11);
                    }

                    // 右上角悬停圆形微按钮组或极淡快捷键胶囊 `^1`
                    let right_reserved = if is_hovered {
                        if can_jump {
                            s(118)
                        } else {
                            s(90)
                        }
                    } else if is_selected {
                        s(68)
                    } else {
                        s(44)
                    };

                    if is_hovered {
                        let b_sz = s(23);
                        let by = cur_y + s(8);
                        let mut rx = w - pad - s(9) - b_sz;
                        let circle_bg = palette.chip_hover_bg;

                        // 删除圆钮
                        canvas.fill_circle(
                            (rx + b_sz / 2) as f32,
                            (by + b_sz / 2) as f32,
                            (b_sz as f32) * 0.5,
                            circle_bg,
                        );
                        canvas.draw_icon_trash(
                            (rx + b_sz / 2) as f32,
                            (by + b_sz / 2) as f32,
                            sf(11.5),
                            sf(1.4),
                            palette.danger,
                        );
                        st.hit_regions.push(HitRegion {
                            rect: RECT {
                                left: rx,
                                top: by,
                                right: rx + b_sz,
                                bottom: by + b_sz,
                            },
                            interactive_cursor: true,
                            action: HitAction::DeleteItem(item.id.clone()),
                        });
                        rx -= b_sz + s(4);

                        // 星标收藏圆钮
                        canvas.fill_circle(
                            (rx + b_sz / 2) as f32,
                            (by + b_sz / 2) as f32,
                            (b_sz as f32) * 0.5,
                            if item.is_pinned {
                                palette.amber.with_alpha(38)
                            } else {
                                circle_bg
                            },
                        );
                        canvas.draw_icon_star(
                            (rx + b_sz / 2) as f32,
                            (by + b_sz / 2) as f32,
                            sf(12.0),
                            sf(1.4),
                            if item.is_pinned {
                                palette.amber
                            } else {
                                palette.text_secondary
                            },
                            item.is_pinned,
                        );
                        st.hit_regions.push(HitRegion {
                            rect: RECT {
                                left: rx,
                                top: by,
                                right: rx + b_sz,
                                bottom: by + b_sz,
                            },
                            interactive_cursor: true,
                            action: HitAction::TogglePin(item.id.clone()),
                        });

                        if !minimal {
                            rx -= b_sz + s(4);
                            canvas.fill_circle(
                                (rx + b_sz / 2) as f32,
                                (by + b_sz / 2) as f32,
                                (b_sz as f32) * 0.5,
                                circle_bg,
                            );
                            canvas.draw_icon_check_circle(
                                (rx + b_sz / 2) as f32,
                                (by + b_sz / 2) as f32,
                                sf(12.0),
                                sf(1.35),
                                if item.is_todo() {
                                    palette.emerald
                                } else {
                                    palette.text_secondary
                                },
                                item.is_todo(),
                                Color4::rgb(255, 255, 255),
                            );
                            st.hit_regions.push(HitRegion {
                                rect: RECT {
                                    left: rx,
                                    top: by,
                                    right: rx + b_sz,
                                    bottom: by + b_sz,
                                },
                                interactive_cursor: true,
                                action: HitAction::ToggleTodo(item.id.clone()),
                            });
                        }

                        if can_jump {
                            rx -= b_sz + s(4);
                            canvas.fill_circle(
                                (rx + b_sz / 2) as f32,
                                (by + b_sz / 2) as f32,
                                (b_sz as f32) * 0.5,
                                circle_bg,
                            );
                            canvas.draw_icon_external_link(
                                (rx + b_sz / 2) as f32,
                                (by + b_sz / 2) as f32,
                                sf(11.0),
                                sf(1.5),
                                palette.cobalt_text,
                            );
                            st.hit_regions.push(HitRegion {
                                rect: RECT {
                                    left: rx,
                                    top: by,
                                    right: rx + b_sz,
                                    bottom: by + b_sz,
                                },
                                interactive_cursor: true,
                                action: HitAction::OpenExternalTarget(store_idx),
                            });
                        }
                    } else if let Some(q_rank) = st.store.queue_rank(&item.id) {
                        let bw = s(34);
                        let bh = s(18);
                        let bx = w - pad - bw - s(10);
                        let by = cur_y + s(9);
                        canvas.fill_round_rect(bx, by, bw, bh, sf(9.0), palette.cobalt);
                        texts.push(TextDrawCmd {
                            text: format!("#{q_rank}"),
                            rect: RECT {
                                left: bx,
                                top: by,
                                right: bx + bw,
                                bottom: by + bh,
                            },
                            color: Color4::rgb(255, 255, 255),
                            font_kind: FontKind::KeyCap,
                            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                        });
                    } else if vis_pos < 9 {
                        let bw = s(28);
                        let bh = s(18);
                        let mut bx = w - pad - bw - s(10);
                        let by = cur_y + s(9);
                        if is_selected {
                            let r_sz = s(20);
                            let rx = bx + bw - r_sz;
                            // 选中卡片右侧确认键入圆钮承担唯一品牌电光钴蓝焦点
                            canvas.fill_circle(
                                (rx + r_sz / 2) as f32,
                                (by + bh / 2) as f32,
                                (r_sz as f32) * 0.5,
                                palette.cobalt,
                            );
                            canvas.draw_icon_return_arrow(
                                (rx + r_sz / 2) as f32,
                                (by + bh / 2) as f32,
                                sf(10.5),
                                sf(1.45),
                                Color4::rgb(255, 255, 255),
                            );
                            bx = rx - bw - s(6);
                        }
                        canvas.fill_round_rect(
                            bx,
                            by,
                            bw,
                            bh,
                            sf(6.0),
                            if is_selected {
                                palette
                                    .cobalt
                                    .with_alpha(if st.is_dark_mode { 42 } else { 20 })
                            } else {
                                palette.chip_bg
                            },
                        );
                        texts.push(TextDrawCmd {
                            text: format!("^{}", vis_pos + 1),
                            rect: RECT {
                                left: bx,
                                top: by,
                                right: bx + bw,
                                bottom: by + bh,
                            },
                            color: if is_selected {
                                palette.cobalt_text
                            } else {
                                palette.text_muted
                            },
                            font_kind: FontKind::KeyCap,
                            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                        });
                    }

                    // 卡片主标题（通透选中层下始终保持深海军蓝/纯白最高可读对比度）
                    let veil_on =
                        st.store.config.mask_sensitive_previews && !is_selected && !is_hovered;
                    let title_str = item.display_title(minimal, veil_on);
                    texts.push(TextDrawCmd {
                        text: title_str,
                        rect: RECT {
                            left: left_cursor,
                            top: cur_y + s(8),
                            right: w - pad - right_reserved,
                            bottom: cur_y + s(31),
                        },
                        color: if todo_done {
                            palette.text_muted
                        } else {
                            palette.text_primary
                        },
                        font_kind: FontKind::CardTitle,
                        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                    });

                    // 副标题行（收藏星标 + 独立分类徽章胶囊 + 降噪元信息 + 右侧等宽相对时间）
                    let mut meta_x = left_cursor;
                    let meta_cy = (cur_y + s(41)) as f32;
                    if item.is_pinned {
                        let star_c = if !minimal {
                            item.pin_category
                                .map(GlassPalette::pin_category_color)
                                .unwrap_or(palette.amber)
                        } else {
                            palette.amber
                        };
                        canvas.draw_icon_star(
                            meta_x as f32 + sf(5.0),
                            meta_cy,
                            sf(10.5),
                            sf(1.3),
                            star_c,
                            true,
                        );
                        meta_x += s(14);
                    } else if !minimal {
                        if let Some(cat) = item.pin_category {
                            let dot_c = GlassPalette::pin_category_color(cat);
                            canvas.fill_circle(meta_x as f32 + sf(3.0), meta_cy, sf(2.6), dot_c);
                            meta_x += s(8);
                        }
                    }

                    // 收藏分类拆分为独立语义微胶囊（告别与正文摘要混排成一团！）
                    if !minimal {
                        if let Some(cat) = item.pin_category {
                            let cat_lbl = cat.title();
                            let cat_c = GlassPalette::pin_category_color(cat);
                            let cw = estimate_text_px(cat_lbl, sf(10.5)) + s(10);
                            let ch = s(15);
                            let cy_b = cur_y + s(34);
                            canvas.fill_round_rect(
                                meta_x,
                                cy_b,
                                cw,
                                ch,
                                sf(7.5),
                                cat_c.with_alpha(if st.is_dark_mode { 44 } else { 26 }),
                            );
                            texts.push(TextDrawCmd {
                                text: cat_lbl.to_string(),
                                rect: RECT {
                                    left: meta_x,
                                    top: cy_b,
                                    right: meta_x + cw,
                                    bottom: cy_b + ch,
                                },
                                color: if st.is_dark_mode {
                                    cat_c.lerp(Color4::rgb(255, 255, 255), 0.28)
                                } else {
                                    cat_c.lerp(Color4::rgb(15, 23, 42), 0.22)
                                },
                                font_kind: FontKind::BadgeBold,
                                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                            });
                            meta_x += cw + s(6);
                        }
                    }

                    let mut sub_parts: Vec<String> = Vec::new();
                    if item.is_burn_after_paste() {
                        sub_parts.push("粘贴即焚".to_string());
                    } else if matches!(
                        item.detected_poison_threat(),
                        Some(iclip_core::security::PoisonThreatKind::PastejackingOrBidi(
                            _
                        ))
                    ) {
                        sub_parts.push("含隐藏控制符".to_string());
                    } else if let Some(link_risk) = item.detected_link_risk() {
                        sub_parts.push(link_risk.badge_title().to_string());
                    } else if let Some(sec_kind) = item.detected_sensitive_kind() {
                        if !item.is_pinned
                            && !item.is_pending_todo()
                            && st.store.config.auto_expire_unpinned_secrets
                        {
                            sub_parts.push(format!("{} · 24h自毁", sec_kind.badge_title()));
                        } else {
                            sub_parts.push(sec_kind.badge_title().to_string());
                        }
                    }
                    sub_parts.push(item.subtitle_info_veiled(veil_on));
                    if let Some(app) = &item.source_app_name {
                        if !app.is_empty() {
                            sub_parts.push(app.clone());
                        }
                    }
                    if st.copied_flash_item_id.as_deref() == Some(item.id.as_str()) {
                        sub_parts.push("✓ 已复制".to_string());
                    } else if !minimal {
                        if let Some(badge) = st.store.preferred_target_badge(
                            &item.content_hash,
                            st.active_target_app_name.as_deref(),
                        ) {
                            sub_parts.push(badge);
                        } else if !item.is_pinned {
                            let reuse = st.store.reuse_count(&item.content_hash);
                            if reuse >= 3 {
                                sub_parts.push(format!("高频 ×{reuse}"));
                            }
                        }
                    }

                    let time_w = s(58);
                    texts.push(TextDrawCmd {
                        text: sub_parts.join(" · "),
                        rect: RECT {
                            left: meta_x,
                            top: cur_y + s(32),
                            right: w - pad - time_w - s(12),
                            bottom: cur_y + s(52),
                        },
                        color: if st.copied_flash_item_id.as_deref() == Some(item.id.as_str()) {
                            palette.emerald
                        } else {
                            palette.text_secondary
                        },
                        font_kind: FontKind::Meta,
                        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                    });
                    texts.push(TextDrawCmd {
                        text: format_relative_time(item.created_unix_secs),
                        rect: RECT {
                            left: w - pad - time_w - s(10),
                            top: cur_y + s(32),
                            right: w - pad - s(12),
                            bottom: cur_y + s(52),
                        },
                        color: palette.text_muted,
                        font_kind: FontKind::Meta,
                        flags: DT_RIGHT | DT_VCENTER | DT_SINGLELINE,
                    });

                    // 现代精致快捷转化胶囊（零低质 Unicode 符号、高辨识冷蓝/琥珀语义底、清晰 22px 舒展高度）
                    if has_chips {
                        let mut chip_x = left_cursor;
                        let chip_top = cur_y + s(55);
                        let chip_h = s(22);
                        for (a_idx, act) in quick_actions.iter().enumerate() {
                            let label = act.title.clone();
                            let is_primary_chip = a_idx == 0;
                            let txt_w = estimate_text_px(&label, sf(10.4));
                            let extra_key_w = if is_primary_chip { s(22) } else { 0 };
                            let cw =
                                (s(21) + txt_w + extra_key_w + s(7)).min(w - pad - chip_x - s(10));
                            if cw < s(52) {
                                break;
                            }
                            let (chip_bg, chip_bd, chip_fg, bolt_c) = if is_primary_chip {
                                if act.is_security {
                                    (
                                        palette.amber.with_alpha(if st.is_dark_mode {
                                            42
                                        } else {
                                            22
                                        }),
                                        palette.amber.with_alpha(if st.is_dark_mode {
                                            96
                                        } else {
                                            64
                                        }),
                                        if st.is_dark_mode {
                                            Color4::rgb(253, 224, 138)
                                        } else {
                                            Color4::rgb(180, 83, 9)
                                        },
                                        palette.amber,
                                    )
                                } else {
                                    (
                                        palette.cobalt.with_alpha(if st.is_dark_mode {
                                            44
                                        } else {
                                            20
                                        }),
                                        palette.cobalt.with_alpha(if st.is_dark_mode {
                                            108
                                        } else {
                                            62
                                        }),
                                        palette.cobalt_text,
                                        palette.cobalt_text,
                                    )
                                }
                            } else {
                                (
                                    if is_hovered {
                                        palette.chip_hover_bg
                                    } else {
                                        palette.chip_bg
                                    },
                                    palette.card_border,
                                    palette.text_secondary,
                                    if act.is_security {
                                        palette.amber
                                    } else {
                                        palette.cobalt_text
                                    },
                                )
                            };
                            canvas.fill_round_rect(chip_x, chip_top, cw, chip_h, sf(11.0), chip_bg);
                            canvas.stroke_round_rect(
                                chip_x,
                                chip_top,
                                cw,
                                chip_h,
                                sf(11.0),
                                sf(0.65),
                                chip_bd,
                            );
                            canvas.draw_icon_bolt(
                                (chip_x + s(11)) as f32,
                                (chip_top + chip_h / 2) as f32,
                                sf(9.5),
                                sf(1.35),
                                bolt_c,
                            );
                            let text_right = if is_primary_chip {
                                chip_x + cw - s(26)
                            } else {
                                chip_x + cw - s(8)
                            };
                            texts.push(TextDrawCmd {
                                text: label,
                                rect: RECT {
                                    left: chip_x + s(19),
                                    top: chip_top,
                                    right: text_right,
                                    bottom: chip_top + chip_h,
                                },
                                color: chip_fg,
                                font_kind: if is_primary_chip {
                                    FontKind::BadgeBold
                                } else {
                                    FontKind::Meta
                                },
                                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                            });
                            // 首枚胶囊右侧绘制像素对齐矢量 Shift + Enter 双图标，与底栏 [⇧ ↵] 转换 100% 语义统一
                            if is_primary_chip && cw >= s(72) {
                                let icy = (chip_top + chip_h / 2) as f32;
                                let key_c = chip_fg.with_alpha(210);
                                canvas.draw_icon_shift_arrow(
                                    (chip_x + cw - s(19)) as f32,
                                    icy,
                                    sf(8.2),
                                    sf(1.18),
                                    key_c,
                                );
                                canvas.draw_icon_return_arrow(
                                    (chip_x + cw - s(10)) as f32,
                                    icy,
                                    sf(8.4),
                                    sf(1.22),
                                    key_c,
                                );
                            }
                            st.hit_regions.push(HitRegion {
                                rect: RECT {
                                    left: chip_x,
                                    top: chip_top,
                                    right: chip_x + cw,
                                    bottom: chip_top + chip_h,
                                },
                                interactive_cursor: true,
                                action: HitAction::TriggerQuickAction {
                                    item_idx: store_idx,
                                    action: act.clone(),
                                },
                            });
                            chip_x += cw + s(6);
                        }
                    }

                    st.hit_regions.push(HitRegion {
                        rect: RECT {
                            left: pad,
                            top: cur_y,
                            right: w - pad,
                            bottom: cur_y + card_h,
                        },
                        interactive_cursor: false,
                        action: HitAction::SelectCard(vis_pos),
                    });
                    cur_y += card_h + s(9);
                }
            }
        }
    }

    // 4. 底部悬浮玻璃胶囊状态栏（去除多余顶线，全矢量键帽 + 隔离清空按钮防误触）
    let _ = footer_zone_h;
    let fb_x = s(12);
    let fb_w = w - s(24);
    let fb_h = s(30);
    let fb_y = h - fb_h - s(8);
    canvas.fill_round_rect(fb_x, fb_y, fb_w, fb_h, sf(15.0), palette.footer_backdrop);
    canvas.stroke_glass_bevel_round_rect(
        fb_x,
        fb_y,
        fb_w,
        fb_h,
        sf(15.0),
        sf(0.75),
        palette.glass_top_highlight,
        palette.track_border,
    );

    let dot_c = if st.store.is_paused {
        palette.amber
    } else {
        palette.emerald
    };
    let fb_cy = (fb_y + fb_h / 2) as f32;
    canvas.fill_circle((fb_x + s(13)) as f32, fb_cy, sf(3.25), dot_c);
    texts.push(TextDrawCmd {
        text: format!("{} 条", filtered.len()),
        rect: RECT {
            left: fb_x + s(22),
            top: fb_y,
            right: fb_x + s(86),
            bottom: fb_y + fb_h,
        },
        color: palette.text_secondary,
        font_kind: FontKind::BadgeBold,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
    });

    // 右侧一键清空未收藏微圆钮（左侧留细竖分隔线与键帽区清晰隔离防误触）
    let has_unpinned = st.store.items.iter().any(|it| !it.is_pinned);
    let mut hint_right_edge = fb_x + fb_w - s(10);
    if has_unpinned {
        let tb_sz = s(20);
        let tbx = fb_x + fb_w - tb_sz - s(6);
        let tby = fb_y + (fb_h - tb_sz) / 2;
        canvas.fill_circle(
            (tbx + tb_sz / 2) as f32,
            (tby + tb_sz / 2) as f32,
            sf(10.0),
            palette.chip_bg,
        );
        canvas.draw_icon_trash(
            (tbx + tb_sz / 2) as f32,
            (tby + tb_sz / 2) as f32,
            sf(10.5),
            sf(1.35),
            palette.text_secondary,
        );
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: tbx,
                top: tby,
                right: tbx + tb_sz,
                bottom: tby + tb_sz,
            },
            interactive_cursor: true,
            action: HitAction::ClearUnpinnedHistory,
        });
        let sep_x = (tbx - s(6)) as f32;
        canvas.draw_line(
            sep_x,
            (fb_y + s(7)) as f32,
            sep_x,
            (fb_y + fb_h - s(7)) as f32,
            sf(0.75),
            palette.divider,
        );
        hint_right_edge = tbx - s(12);
    }

    // 恒定全矢量键帽提示组（零低质 Unicode 符号）：[Esc] 关闭 · [Tab] 类目 · [Shift+Enter] 转换 · [Enter] 键入
    let tab_lbl = if st.store.paste_queue_ids.is_empty() {
        "类目"
    } else {
        "出队"
    };
    let mut hints: Vec<(&str, &str)> = vec![("Esc", "关闭"), ("tab", tab_lbl)];
    if !minimal {
        hints.push(("shift_ret", "转换"));
    }
    hints.push(("ret", "键入"));

    let mut cur_rx = hint_right_edge;
    for (k, lbl) in hints {
        let lbl_w = s(25);
        let cap_w = match k {
            "ret" | "tab" => s(19),
            "shift_ret" => s(28),
            _ => s(27),
        };
        let total_w = cap_w + s(4) + lbl_w;
        let start_x = cur_rx - total_w;
        if start_x < fb_x + s(74) {
            break;
        }
        let cap_h = s(17);
        let cap_y = fb_y + (fb_h - cap_h) / 2;
        canvas.fill_round_rect(start_x, cap_y, cap_w, cap_h, sf(4.8), palette.chip_bg);
        canvas.stroke_round_rect(
            start_x,
            cap_y,
            cap_w,
            cap_h,
            sf(4.8),
            sf(0.65),
            palette.card_border,
        );
        let cap_cx = (start_x + cap_w / 2) as f32;
        let cap_cy = (cap_y + cap_h / 2) as f32;
        if k == "ret" {
            canvas.draw_icon_return_arrow(cap_cx, cap_cy, sf(9.2), sf(1.3), palette.text_secondary);
        } else if k == "tab" {
            canvas.draw_icon_tab_arrow(cap_cx, cap_cy, sf(9.2), sf(1.25), palette.text_secondary);
        } else if k == "shift_ret" {
            canvas.draw_icon_shift_arrow(
                (start_x + s(8)) as f32,
                cap_cy,
                sf(8.6),
                sf(1.2),
                palette.text_secondary,
            );
            canvas.draw_icon_return_arrow(
                (start_x + cap_w - s(8)) as f32,
                cap_cy,
                sf(8.6),
                sf(1.2),
                palette.text_secondary,
            );
        } else {
            texts.push(TextDrawCmd {
                text: k.to_string(),
                rect: RECT {
                    left: start_x,
                    top: cap_y,
                    right: start_x + cap_w,
                    bottom: cap_y + cap_h,
                },
                color: palette.text_secondary,
                font_kind: FontKind::KeyCap,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
        }
        texts.push(TextDrawCmd {
            text: lbl.to_string(),
            rect: RECT {
                left: start_x + cap_w + s(4),
                top: fb_y,
                right: cur_rx,
                bottom: fb_y + fb_h,
            },
            color: palette.text_secondary,
            font_kind: FontKind::Meta,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        });
        cur_rx = start_x - s(8);
    }
}

#[allow(clippy::too_many_arguments)]
fn draw_header_circle_btn(
    canvas: &mut PixelCanvas,
    x: i32,
    y: i32,
    sz: i32,
    scale: f32,
    palette: &GlassPalette,
    active: bool,
    active_color: Color4,
) {
    let r = (sz as f32) * 0.5;
    let fill = if active {
        active_color
    } else {
        palette.search_bg
    };
    let stroke = if active {
        Color4::rgba(255, 255, 255, 85)
    } else {
        palette.search_border
    };
    canvas.fill_round_rect(x, y, sz, sz, r, fill);
    canvas.stroke_round_rect(x, y, sz, sz, r, 0.75 * scale, stroke);
}

// ============================================================================
// 1:1 复刻 macOS `settingsView`（iOS 分组玻璃卡片 + Tahoe 实景流光折射预览窗）
// ============================================================================

fn layout_and_draw_settings_view(
    canvas: &mut PixelCanvas,
    texts: &mut Vec<TextDrawCmd>,
    w: i32,
    h: i32,
    scale: f32,
    palette: &GlassPalette,
    st: &mut WinAppState,
) -> (usize, i32, i32) {
    let s = |v: i32| ((v as f32) * scale).round() as i32;
    let sf = |v: f32| v * scale;
    let pad = s(14);
    let content_w = w - pad * 2;

    // 1. 设置页顶栏：左侧 `‹ 返回` 胶囊 + 居中 `iClip 设置` 与轻巧角色徽章（主副视觉清晰分层）
    let top_y = s(14);
    let back_w = s(58);
    let back_h = s(28);
    canvas.fill_round_rect(pad, top_y, back_w, back_h, sf(14.0), palette.search_bg);
    canvas.stroke_glass_bevel_round_rect(
        pad,
        top_y,
        back_w,
        back_h,
        sf(14.0),
        sf(0.8),
        palette.glass_top_highlight,
        palette.search_border,
    );
    canvas.draw_icon_back(
        (pad + s(14)) as f32,
        (top_y + back_h / 2) as f32,
        sf(10.5),
        sf(1.65),
        palette.cobalt_text,
    );
    texts.push(TextDrawCmd {
        text: "返回".to_string(),
        rect: RECT {
            left: pad + s(22),
            top: top_y,
            right: pad + back_w - s(5),
            bottom: top_y + back_h,
        },
        color: palette.cobalt_text,
        font_kind: FontKind::BadgeBold,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
    });
    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: pad,
            top: top_y,
            right: pad + back_w,
            bottom: top_y + back_h,
        },
        interactive_cursor: true,
        action: HitAction::ToggleSettingsView,
    });

    let ed_badge = if ClipboardStore::edition_key() == "flow" {
        "办公版"
    } else {
        "极客版"
    };
    let head_txt = "iClip 设置";
    let head_w = estimate_text_px(head_txt, sf(15.0)) + s(6);
    let ed_w = estimate_text_px(ed_badge, sf(11.0)) + s(14);
    let ed_h = s(19);
    let grp_w = head_w + s(6) + ed_w;
    let grp_x = ((w - grp_w) / 2).max(pad + back_w + s(8));
    texts.push(TextDrawCmd {
        text: head_txt.to_string(),
        rect: RECT {
            left: grp_x,
            top: top_y,
            right: grp_x + head_w,
            bottom: top_y + back_h,
        },
        color: palette.text_primary,
        font_kind: FontKind::Headline,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
    });
    let ed_x = grp_x + head_w + s(6);
    let ed_y = top_y + (back_h - ed_h) / 2;
    canvas.fill_round_rect(
        ed_x,
        ed_y,
        ed_w,
        ed_h,
        sf(9.5),
        palette
            .cobalt
            .with_alpha(if st.is_dark_mode { 42 } else { 22 }),
    );
    texts.push(TextDrawCmd {
        text: ed_badge.to_string(),
        rect: RECT {
            left: ed_x,
            top: ed_y,
            right: ed_x + ed_w,
            bottom: ed_y + ed_h,
        },
        color: palette.cobalt_text,
        font_kind: FontKind::BadgeBold,
        flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
    });

    let view_top = top_y + back_h + s(14);
    let view_bottom = h - s(10);
    let mut y = view_top - st.settings_scroll_px;

    let scroll_text_start = texts.len();
    let scroll_hit_start = st.hit_regions.len();
    canvas.set_vertical_clip(view_top, view_bottom);

    let visible_block = |by: i32, bh: i32| -> bool { (by + bh) > view_top && by < view_bottom };

    // ── 分组 0：软件更新（Windows 原生 WinHTTP 双源校验 + 无感原地热替换 OTA）──
    if visible_block(y, s(18)) {
        draw_group_header(texts, pad, y, content_w, s(18), "软件更新", palette);
    }
    y += s(22);

    let ota_is_downloading = matches!(st.ota_state, OtaState::Downloading { .. });
    let g0_h = if ota_is_downloading { s(76) } else { s(62) };
    if visible_block(y, g0_h) {
        canvas.fill_round_rect(pad, y, content_w, g0_h, sf(14.0), palette.group_fill);
        canvas.stroke_glass_bevel_round_rect(
            pad,
            y,
            content_w,
            g0_h,
            sf(14.0),
            sf(0.85),
            palette.glass_top_highlight,
            palette.group_stroke,
        );

        let cur_ver = env!("CARGO_PKG_VERSION");
        let (ota_title, ota_sub, btn_lbl, btn_primary, btn_action, prog_opt) = match &st.ota_state {
            OtaState::Idle => (
                format!("iClip v{cur_ver}"),
                "原生 OTA 双源校验 · 无感原地更新免重装".to_string(),
                "检查更新".to_string(),
                false,
                Some(HitAction::CheckForUpdates),
                None,
            ),
            OtaState::Checking => (
                format!("iClip v{cur_ver}"),
                "正在连接发布源检测最新版本...".to_string(),
                "检查中".to_string(),
                false,
                None,
                None,
            ),
            OtaState::UpToDate { latest } => (
                format!("iClip v{latest} · 已是最新"),
                "已是最新原生版 · 启动时后台静默检测".to_string(),
                "检查更新".to_string(),
                false,
                Some(HitAction::CheckForUpdates),
                None,
            ),
            OtaState::Available(info) => (
                format!("发现新版本 v{}", info.version),
                format!("当前 v{cur_ver} · {}", info.release_notes),
                "立即更新".to_string(),
                true,
                Some(HitAction::StartOtaDownload),
                None,
            ),
            OtaState::Downloading {
                info,
                progress_pct,
                downloaded_kb,
                total_kb,
            } => (
                format!("正在下载 v{} · {progress_pct}%", info.version),
                if *total_kb > 0 {
                    format!("已下载 {downloaded_kb} KB / {total_kb} KB · 自动校验完整性")
                } else {
                    format!("已下载 {downloaded_kb} KB · 自动校验完整性")
                },
                "取消".to_string(),
                false,
                Some(HitAction::CancelOtaDownload),
                Some(*progress_pct),
            ),
            OtaState::Installing(info) => (
                format!("正在安装 v{}...", info.version),
                "PE 签名校验通过，正在热替换并重启 iClip".to_string(),
                "安装中".to_string(),
                false,
                None,
                Some(100),
            ),
            OtaState::Failed(err) => (
                format!("iClip v{cur_ver} · 更新中断"),
                err.clone(),
                "重试".to_string(),
                false,
                Some(HitAction::CheckForUpdates),
                None,
            ),
        };

        let ic_box = s(34);
        let ic_x = pad + s(12);
        let ic_y = y + (s(62) - ic_box) / 2;
        let has_new = st.ota_state.available_version().is_some();
        canvas.fill_round_rect(
            ic_x,
            ic_y,
            ic_box,
            ic_box,
            sf(10.0),
            if has_new {
                palette
                    .cobalt
                    .with_alpha(if st.is_dark_mode { 56 } else { 28 })
            } else {
                palette
                    .emerald
                    .with_alpha(if st.is_dark_mode { 44 } else { 22 })
            },
        );
        canvas.draw_icon_refresh_update(
            (ic_x + ic_box / 2) as f32,
            (ic_y + ic_box / 2) as f32,
            sf(16.0),
            sf(1.55),
            if has_new {
                palette.cobalt_text
            } else {
                palette.emerald
            },
        );

        let ob_w = (estimate_text_px(&btn_lbl, sf(11.5)) + s(22)).clamp(s(66), s(96));
        let ob_h = s(28);
        let ob_x = w - pad - s(12) - ob_w;
        let ob_y = y + (s(62) - ob_h) / 2;
        if btn_primary {
            canvas.fill_round_rect(ob_x, ob_y, ob_w, ob_h, sf(14.0), palette.cobalt);
        } else {
            canvas.fill_round_rect(
                ob_x,
                ob_y,
                ob_w,
                ob_h,
                sf(14.0),
                if btn_action.is_some() {
                    palette
                        .cobalt
                        .with_alpha(if st.is_dark_mode { 38 } else { 18 })
                } else {
                    palette.chip_bg
                },
            );
            canvas.stroke_round_rect(
                ob_x,
                ob_y,
                ob_w,
                ob_h,
                sf(14.0),
                sf(0.7),
                if btn_action.is_some() {
                    palette
                        .cobalt
                        .with_alpha(if st.is_dark_mode { 84 } else { 48 })
                } else {
                    palette.card_border
                },
            );
        }
        texts.push(TextDrawCmd {
            text: btn_lbl,
            rect: RECT {
                left: ob_x,
                top: ob_y,
                right: ob_x + ob_w,
                bottom: ob_y + ob_h,
            },
            color: if btn_primary {
                Color4::rgb(255, 255, 255)
            } else if btn_action.is_some() {
                palette.cobalt_text
            } else {
                palette.text_muted
            },
            font_kind: FontKind::BadgeBold,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
        if let Some(act) = btn_action {
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: ob_x,
                    top: ob_y,
                    right: ob_x + ob_w,
                    bottom: ob_y + ob_h,
                },
                interactive_cursor: true,
                action: act,
            });
        }

        let txt_left = ic_x + ic_box + s(11);
        let txt_right = ob_x - s(16);
        texts.push(TextDrawCmd {
            text: ota_title,
            rect: RECT {
                left: txt_left,
                top: y + s(10),
                right: txt_right,
                bottom: y + s(31),
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
        texts.push(TextDrawCmd {
            text: ota_sub,
            rect: RECT {
                left: txt_left,
                top: y + s(32),
                right: txt_right,
                bottom: y + s(52),
            },
            color: if matches!(st.ota_state, OtaState::Failed(_)) {
                palette.danger
            } else {
                palette.text_secondary
            },
            font_kind: FontKind::Meta,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });

        if let Some(pct) = prog_opt {
            let bar_x = pad + s(12);
            let bar_w = content_w - s(24);
            let bar_y = y + g0_h - s(11);
            let bar_h = s(4);
            canvas.fill_round_rect(bar_x, bar_y, bar_w, bar_h, sf(2.0), palette.chip_bg);
            let fill_w = ((bar_w as f32) * (pct.min(100) as f32 / 100.0)).round() as i32;
            if fill_w > 0 {
                canvas.fill_round_rect(
                    bar_x,
                    bar_y,
                    fill_w.max(bar_h),
                    bar_h,
                    sf(2.0),
                    palette.cobalt,
                );
            }
        }
    }
    y += g0_h + s(16);

    // ── 分组 1：液态玻璃（纯通透折射预览窗 + 三档语义微刻度滑杆）──
    if visible_block(y, s(18)) {
        draw_group_header(texts, pad, y, content_w, s(18), "液态玻璃", palette);
    }
    y += s(22);

    let g1_h = s(178);
    if visible_block(y, g1_h) {
        canvas.fill_round_rect(pad, y, content_w, g1_h, sf(14.0), palette.group_fill);
        canvas.stroke_glass_bevel_round_rect(
            pad,
            y,
            content_w,
            g1_h,
            sf(14.0),
            sf(0.85),
            palette.glass_top_highlight,
            palette.group_stroke,
        );

        let pct = st.store.config.blur_concentration_pct;
        let stage_label = if pct < 22 {
            format!("清透折射 · {pct}%")
        } else if pct < 68 {
            format!("均衡柔焦 · {pct}%")
        } else {
            format!("浓厚磨砂 · {pct}%")
        };
        texts.push(TextDrawCmd {
            text: "背景模糊浓度".to_string(),
            rect: RECT {
                left: pad + s(14),
                top: y + s(10),
                right: pad + s(164),
                bottom: y + s(30),
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        });
        texts.push(TextDrawCmd {
            text: stage_label,
            rect: RECT {
                left: w - pad - s(146),
                top: y + s(10),
                right: w - pad - s(14),
                bottom: y + s(30),
            },
            color: palette.text_secondary,
            font_kind: FontKind::Meta,
            flags: DT_RIGHT | DT_VCENTER | DT_SINGLELINE,
        });

        // 92px 纯粹通透流光折射预览窗（彻底移除底部割裂灰条）
        let pv_x = pad + s(14);
        let pv_y = y + s(36);
        let pv_w = content_w - s(28);
        let pv_h = s(90);
        canvas.draw_scenic_liquid_glass_preview(
            pv_x,
            pv_y,
            pv_w,
            pv_h,
            scale,
            st.is_dark_mode,
            pct,
        );
        texts.push(TextDrawCmd {
            text: "搜索".to_string(),
            rect: RECT {
                left: pv_x + s(153),
                top: pv_y + s(11),
                right: pv_x + pv_w - s(16),
                bottom: pv_y + s(43),
            },
            color: if st.is_dark_mode {
                Color4::rgba(255, 255, 255, 190)
            } else {
                Color4::rgba(15, 23, 42, 180)
            },
            font_kind: FontKind::Meta,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        });

        // 底部单轴滑块 + 对称三档语义标注（清透 · 均衡 · 浓雾）
        let sl_row_y = pv_y + pv_h + s(10);
        let gl_sz = s(18);
        let left_gx = pv_x;
        let right_gx = pv_x + pv_w - gl_sz;
        canvas.draw_icon_overlapping_squares(
            left_gx as f32,
            (sl_row_y + s(3)) as f32,
            gl_sz as f32,
            palette.text_secondary,
            false,
        );
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: left_gx - s(2),
                top: sl_row_y,
                right: left_gx + gl_sz + s(4),
                bottom: sl_row_y + s(24),
            },
            interactive_cursor: true,
            action: HitAction::SetBlurPreset(8),
        });

        canvas.draw_icon_overlapping_squares(
            right_gx as f32,
            (sl_row_y + s(3)) as f32,
            gl_sz as f32,
            palette.text_secondary,
            true,
        );
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: right_gx - s(4),
                top: sl_row_y,
                right: right_gx + gl_sz + s(2),
                bottom: sl_row_y + s(24),
            },
            interactive_cursor: true,
            action: HitAction::SetBlurPreset(88),
        });

        let track_x = left_gx + gl_sz + s(10);
        let track_w_sl = right_gx - s(10) - track_x;
        canvas.draw_concentration_slider(track_x, sl_row_y, track_w_sl, s(22), pct, palette.cobalt);
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: track_x - s(4),
                top: sl_row_y - s(2),
                right: track_x + track_w_sl + s(4),
                bottom: sl_row_y + s(26),
            },
            interactive_cursor: true,
            action: HitAction::AdjustBlurConcentration {
                track_left: track_x,
                track_width: track_w_sl,
            },
        });

        let lbl_y = sl_row_y + s(21);
        for (anchor, name) in [(0.08f32, "清透"), (0.48f32, "均衡"), (0.88f32, "浓雾")] {
            let cx_a = track_x + ((track_w_sl as f32) * anchor).round() as i32;
            texts.push(TextDrawCmd {
                text: name.to_string(),
                rect: RECT {
                    left: cx_a - s(20),
                    top: lbl_y,
                    right: cx_a + s(20),
                    bottom: lbl_y + s(15),
                },
                color: palette.text_secondary,
                font_kind: FontKind::Meta,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
        }
    }
    y += g1_h + s(16);

    // ── 分组 2：通用与快捷键（大呼吸感 48px 行高 + 顶亮玻璃描边 + 自动微键帽）──
    if visible_block(y, s(18)) {
        draw_group_header(texts, pad, y, content_w, s(18), "通用与快捷键", palette);
    }
    y += s(22);

    let row_h = s(48);
    let g2_rows = 6;
    let g2_h = s(8) + row_h * g2_rows;
    if visible_block(y, g2_h) {
        canvas.fill_round_rect(pad, y, content_w, g2_h, sf(14.0), palette.group_fill);
        canvas.stroke_glass_bevel_round_rect(
            pad,
            y,
            content_w,
            g2_h,
            sf(14.0),
            sf(0.85),
            palette.glass_top_highlight,
            palette.group_stroke,
        );

        let common_toggles = [
            (
                "窗口始终在前（Ctrl+P）",
                "固定面板置顶，切换窗口与连续粘贴时不自动收起",
                st.store.config.always_on_top,
                palette.cobalt,
                HitAction::ToggleAlwaysOnTop,
            ),
            (
                "开机自动启动",
                "登录 Windows 后自动在系统托盘常驻（0.00% 待机 CPU）",
                st.autostart_cached,
                palette.cobalt,
                HitAction::ToggleAutostart,
            ),
            (
                "选中后自动键入粘贴",
                "双击或按回车自动向目标窗口发送 Ctrl+V",
                st.store.config.auto_paste_enabled,
                palette.cobalt,
                HitAction::ToggleAutoPaste,
            ),
            (
                "极简纯净模式（Ctrl+E）",
                "仅保留基础复制检索与收藏，隐藏进阶胶囊与待办",
                st.store.config.minimal_mode_enabled,
                palette.emerald,
                HitAction::ToggleMinimalMode,
            ),
        ];

        let mut ry = y + s(5);
        for (idx, (t, sub, on, acc, act)) in common_toggles.into_iter().enumerate() {
            if idx > 0 {
                canvas.draw_line(
                    (pad + s(12)) as f32,
                    ry as f32,
                    (w - pad - s(12)) as f32,
                    ry as f32,
                    sf(0.7),
                    palette.divider,
                );
            }
            draw_grouped_toggle_row(
                canvas, texts, st, pad, ry, content_w, row_h, scale, palette, t, sub, on, acc, act,
            );
            ry += row_h;
        }

        // 两个全局热键录制行（呼出面板热键 & 顺序出队热键）
        for (slot, title, default_sub, cur_hk, def_hk) in [
            (
                WinHotKeySlot::MainToggle,
                "全局呼出快捷键",
                "点击录制组合键或双击 Ctrl/Alt/Shift/Win 单键",
                st.store.config.hotkey_toggle.clone(),
                WinHotKeyShortcut::default_toggle(),
            ),
            (
                WinHotKeySlot::QueuePop,
                "免开面板顺序出队热键",
                "在表格/表单中连按即可逐项填入队列内容",
                st.store.config.hotkey_queue_pop.clone(),
                WinHotKeyShortcut::default_queue_pop(),
            ),
        ] {
            canvas.draw_line(
                (pad + s(12)) as f32,
                ry as f32,
                (w - pad - s(12)) as f32,
                ry as f32,
                sf(0.7),
                palette.divider,
            );
            let is_rec = st.recording_slot == Some(slot);
            let has_conflict = is_rec && st.hotkey_conflict_error.is_some();

            let mut right_edge = w - pad - s(12);
            if cur_hk != def_hk && !is_rec {
                let rst_sz = s(22);
                let rst_x = right_edge - rst_sz;
                let rst_y = ry + (row_h - rst_sz) / 2;
                canvas.fill_circle(
                    (rst_x + rst_sz / 2) as f32,
                    (rst_y + rst_sz / 2) as f32,
                    sf(11.0),
                    palette.chip_bg,
                );
                canvas.draw_icon_undo_ccw(
                    (rst_x + rst_sz / 2) as f32,
                    (rst_y + rst_sz / 2) as f32,
                    sf(11.0),
                    sf(1.4),
                    palette.text_secondary,
                );
                st.hit_regions.push(HitRegion {
                    rect: RECT {
                        left: rst_x,
                        top: rst_y,
                        right: rst_x + rst_sz,
                        bottom: rst_y + rst_sz,
                    },
                    interactive_cursor: true,
                    action: HitAction::ResetHotkeyDefault(slot),
                });
                right_edge = rst_x - s(6);
            }

            let pill_label = if has_conflict {
                "冲突 · 请重按".to_string()
            } else if is_rec {
                "等待按键...".to_string()
            } else {
                cur_hk.display_string()
            };
            let pill_w = (estimate_text_px(&pill_label, sf(11.0)) + s(24)).clamp(s(76), s(122));
            let pill_h = s(26);
            let pill_x = right_edge - pill_w;
            let pill_y = ry + (row_h - pill_h) / 2;
            let pill_bg = if has_conflict {
                palette.danger
            } else if is_rec {
                palette.cobalt
            } else {
                palette.chip_bg
            };
            canvas.fill_round_rect(pill_x, pill_y, pill_w, pill_h, sf(8.0), pill_bg);
            if !is_rec && !has_conflict {
                canvas.stroke_round_rect(
                    pill_x,
                    pill_y,
                    pill_w,
                    pill_h,
                    sf(8.0),
                    sf(0.75),
                    palette.card_border,
                );
            }
            texts.push(TextDrawCmd {
                text: pill_label,
                rect: RECT {
                    left: pill_x + s(6),
                    top: pill_y,
                    right: pill_x + pill_w - s(6),
                    bottom: pill_y + pill_h,
                },
                color: if is_rec || has_conflict {
                    Color4::rgb(255, 255, 255)
                } else {
                    palette.text_primary
                },
                font_kind: if is_rec || has_conflict {
                    FontKind::BadgeBold
                } else {
                    FontKind::KeyCap
                },
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: pill_x,
                    top: pill_y,
                    right: pill_x + pill_w,
                    bottom: pill_y + pill_h,
                },
                interactive_cursor: true,
                action: HitAction::StartRecordHotkey(slot),
            });

            texts.push(TextDrawCmd {
                text: title.to_string(),
                rect: RECT {
                    left: pad + s(14),
                    top: ry + s(7),
                    right: pill_x - s(10),
                    bottom: ry + s(26),
                },
                color: palette.text_primary,
                font_kind: FontKind::CardTitle,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
            });

            let (sub_txt, sub_col) = if has_conflict {
                (
                    st.hotkey_conflict_error.clone().unwrap_or_default(),
                    palette.danger,
                )
            } else if is_rec {
                (
                    st.hotkey_recording_hint
                        .clone()
                        .unwrap_or_else(|| "按下组合键，或双击单键（Esc 取消）".to_string()),
                    palette.cobalt_text,
                )
            } else {
                (default_sub.to_string(), palette.text_secondary)
            };
            texts.push(TextDrawCmd {
                text: sub_txt,
                rect: RECT {
                    left: pad + s(14),
                    top: ry + s(27),
                    right: pill_x - s(10),
                    bottom: ry + row_h - s(6),
                },
                color: sub_col,
                font_kind: FontKind::Meta,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            ry += row_h;
        }
    }
    y += g2_h + s(14);

    // ── 分组 3：智能辅助（极简模式下自动隐藏）──
    if !st.store.config.minimal_mode_enabled {
        if visible_block(y, s(18)) {
            draw_group_header(texts, pad, y, content_w, s(18), "智能辅助", palette);
        }
        y += s(22);

        let smart_toggles = [
            (
                "跨处选段续接复制（Ctrl+Alt+C）",
                "自动复制当前选段并换行追加至最新文本末尾",
                st.store.config.copy_append_enabled,
                palette.cobalt,
                HitAction::ToggleCopyAppend,
            ),
            (
                "双按 Ctrl+C×2 零离手智变",
                "连按两次复制自动执行首选净化或剥离脏样式",
                st.store.config.double_copy_spark_enabled,
                palette.cobalt,
                HitAction::ToggleDoubleCopySpark,
            ),
            (
                "自动剥离富文本脏样式",
                "清除网页/文档背景字号，IDE 代码高亮自动豁免",
                st.store.config.auto_strip_rich_formatting,
                palette.cobalt,
                HitAction::ToggleStripRichFormat,
            ),
            (
                "复制链接自动剥离追踪尾巴",
                "自动剔除 utm_source / spm / fbclid 等营销参数",
                st.store.config.auto_clean_tracking_url,
                palette.cobalt,
                HitAction::ToggleAutoCleanUrl,
            ),
            (
                "验证码粘贴 30 秒无痕销毁",
                "一次性短信/邮件验证码粘贴后到期自动清除",
                st.store.config.auto_expire_otp,
                palette.cobalt,
                HitAction::ToggleAutoExpireOtp,
            ),
            (
                "顺序出队粘贴后自动补 Tab",
                "连填多列表格或网页表单时自动跳向下一输入框",
                st.store.config.queue_auto_tab,
                palette.emerald,
                HitAction::ToggleQueueAutoTab,
            ),
        ];

        let g3_h = s(10) + row_h * (smart_toggles.len() as i32);
        if visible_block(y, g3_h) {
            canvas.fill_round_rect(pad, y, content_w, g3_h, sf(14.0), palette.group_fill);
            canvas.stroke_round_rect(
                pad,
                y,
                content_w,
                g3_h,
                sf(14.0),
                sf(0.75),
                palette.group_stroke,
            );
            let mut ry = y + s(5);
            for (idx, (t, sub, on, acc, act)) in smart_toggles.into_iter().enumerate() {
                if idx > 0 {
                    canvas.draw_line(
                        (pad + s(12)) as f32,
                        ry as f32,
                        (w - pad - s(12)) as f32,
                        ry as f32,
                        sf(0.7),
                        palette.divider,
                    );
                }
                draw_grouped_toggle_row(
                    canvas, texts, st, pad, ry, content_w, row_h, scale, palette, t, sub, on, acc,
                    act,
                );
                ry += row_h;
            }
        }
        y += g3_h + s(14);
    }

    // ── 分组 4：隐私护盾与跨软件迁移（DPAPI 加密 + 投屏隐身 + 防肩窥遮罩 + 多格式无损迁入）──
    if visible_block(y, s(18)) {
        draw_group_header(texts, pad, y, content_w, s(18), "隐私护盾与迁移", palette);
    }
    y += s(22);

    let g4_toggle_rows = 4;
    let g4_top_h = s(32) + row_h * g4_toggle_rows;
    let g4_h = g4_top_h + s(122);
    if visible_block(y, g4_h) {
        canvas.fill_round_rect(pad, y, content_w, g4_h, sf(14.0), palette.group_fill);
        canvas.stroke_round_rect(
            pad,
            y,
            content_w,
            g4_h,
            sf(14.0),
            sf(0.75),
            palette.group_stroke,
        );

        // 顶部本机 DPAPI 静态加密激活徽标条
        let badge_x = pad + s(10);
        let badge_y = y + s(7);
        let badge_w = content_w - s(20);
        let badge_h = s(22);
        canvas.fill_round_rect(
            badge_x,
            badge_y,
            badge_w,
            badge_h,
            sf(7.0),
            palette.emerald.with_alpha(26),
        );
        canvas.fill_circle(
            (badge_x + s(11)) as f32,
            (badge_y + badge_h / 2) as f32,
            sf(3.2),
            palette.emerald,
        );
        texts.push(TextDrawCmd {
            text: "本机 DPAPI 硬件凭据加密保护已启用 · 零联网上传".to_string(),
            rect: RECT {
                left: badge_x + s(19),
                top: badge_y,
                right: badge_x + badge_w - s(8),
                bottom: badge_y + badge_h,
            },
            color: palette.text_secondary,
            font_kind: FontKind::Meta,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });

        let shield_toggles = [
            (
                "投屏与录屏光学隐身护盾",
                "腾讯会议 / 飞书共享屏幕及录屏画面中自动隐藏面板",
                st.store.config.screen_share_privacy,
                palette.emerald,
                HitAction::ToggleScreenSharePrivacy,
            ),
            (
                "敏感凭据防肩窥圆点遮罩",
                "API 密钥与私钥默认圆点雾化，选中或悬停即刻显影",
                st.store.config.mask_sensitive_previews,
                palette.cobalt,
                HitAction::ToggleSensitiveVeil,
            ),
            (
                "密码剪贴板 60 秒残留擦除",
                "检测到密码管理器复制密码后超时自动清空系统剪贴板",
                st.store.config.auto_clear_concealed_clipboard,
                palette.cobalt,
                HitAction::ToggleAutoClearConcealed,
            ),
            (
                "未收藏敏感凭据 24h 自动销毁",
                "临时密钥与身份证卡号满 24 小时自动代谢，收藏项永久守护",
                st.store.config.auto_expire_unpinned_secrets,
                palette.cobalt,
                HitAction::ToggleAutoExpireSecrets,
            ),
        ];

        let mut sry = y + s(32);
        for (t, sub, on, acc, act) in shield_toggles {
            canvas.draw_line(
                (pad + s(12)) as f32,
                sry as f32,
                (w - pad - s(12)) as f32,
                sry as f32,
                sf(0.7),
                palette.divider,
            );
            draw_grouped_toggle_row(
                canvas, texts, st, pad, sry, content_w, row_h, scale, palette, t, sub, on, acc, act,
            );
            sry += row_h;
        }

        let sec_base_y = y + g4_top_h;
        canvas.draw_line(
            (pad + s(12)) as f32,
            sec_base_y as f32,
            (w - pad - s(12)) as f32,
            sec_base_y as f32,
            sf(0.7),
            palette.divider,
        );

        texts.push(TextDrawCmd {
            text: "历史保留上限".to_string(),
            rect: RECT {
                left: pad + s(12),
                top: sec_base_y + s(8),
                right: pad + s(160),
                bottom: sec_base_y + s(28),
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        });
        texts.push(TextDrawCmd {
            text: "收藏记录永不清理".to_string(),
            rect: RECT {
                left: w - pad - s(140),
                top: sec_base_y + s(8),
                right: w - pad - s(12),
                bottom: sec_base_y + s(28),
            },
            color: palette.text_secondary,
            font_kind: FontKind::Meta,
            flags: DT_RIGHT | DT_VCENTER | DT_SINGLELINE,
        });

        // iOS 原生风 Segmented Picker：[50 条 | 100 条 | 200 条 | 500 条]
        let pk_x = pad + s(12);
        let pk_y = sec_base_y + s(33);
        let pk_w = content_w - s(24);
        let pk_h = s(28);
        canvas.fill_round_rect(pk_x, pk_y, pk_w, pk_h, sf(8.5), palette.track_bg);
        let caps = [50usize, 100, 200, 500];
        let cell_w = (pk_w - s(4)) / 4;
        for (i, &cap) in caps.iter().enumerate() {
            let cx = pk_x + s(2) + (i as i32) * cell_w;
            let cw = if i == 3 {
                pk_x + pk_w - s(2) - cx
            } else {
                cell_w
            };
            let active = st.store.config.max_history_count == cap;
            if active {
                canvas.fill_round_rect(
                    cx,
                    pk_y + s(2),
                    cw,
                    pk_h - s(4),
                    sf(6.5),
                    palette.active_segment_fill,
                );
            }
            let rc = RECT {
                left: cx,
                top: pk_y,
                right: cx + cw,
                bottom: pk_y + pk_h,
            };
            texts.push(TextDrawCmd {
                text: format!("{cap} 条"),
                rect: rc,
                color: if active {
                    palette.text_primary
                } else {
                    palette.text_secondary
                },
                font_kind: if active {
                    FontKind::BadgeBold
                } else {
                    FontKind::Meta
                },
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            st.hit_regions.push(HitRegion {
                rect: rc,
                interactive_cursor: true,
                action: HitAction::SelectMaxHistory(cap),
            });
        }

        canvas.draw_line(
            (pad + s(12)) as f32,
            (sec_base_y + s(70)) as f32,
            (w - pad - s(12)) as f32,
            (sec_base_y + s(70)) as f32,
            sf(0.7),
            palette.divider,
        );

        let exp_w = s(88);
        let imp_w = s(64);
        let exp_x = w - pad - s(12) - exp_w;
        let imp_x = exp_x - s(6) - imp_w;
        let btn_y = sec_base_y + s(82);
        let btn_h = s(26);

        canvas.fill_round_rect(imp_x, btn_y, imp_w, btn_h, sf(8.0), palette.chip_bg);
        canvas.stroke_round_rect(
            imp_x,
            btn_y,
            imp_w,
            btn_h,
            sf(8.0),
            sf(0.7),
            palette.group_stroke,
        );
        texts.push(TextDrawCmd {
            text: "导入...".to_string(),
            rect: RECT {
                left: imp_x,
                top: btn_y,
                right: imp_x + imp_w,
                bottom: btn_y + btn_h,
            },
            color: palette.text_primary,
            font_kind: FontKind::BadgeBold,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: imp_x,
                top: btn_y,
                right: imp_x + imp_w,
                bottom: btn_y + btn_h,
            },
            interactive_cursor: true,
            action: HitAction::ImportArchive,
        });

        canvas.fill_round_rect(exp_x, btn_y, exp_w, btn_h, sf(8.0), palette.cobalt);
        texts.push(TextDrawCmd {
            text: "导出 (.iclip)".to_string(),
            rect: RECT {
                left: exp_x,
                top: btn_y,
                right: exp_x + exp_w,
                bottom: btn_y + btn_h,
            },
            color: Color4::rgb(255, 255, 255),
            font_kind: FontKind::BadgeBold,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: exp_x,
                top: btn_y,
                right: exp_x + exp_w,
                bottom: btn_y + btn_h,
            },
            interactive_cursor: true,
            action: HitAction::ExportArchive,
        });

        texts.push(TextDrawCmd {
            text: "收藏归档与跨软件搬家".to_string(),
            rect: RECT {
                left: pad + s(12),
                top: sec_base_y + s(75),
                right: imp_x - s(8),
                bottom: sec_base_y + s(95),
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        });
        texts.push(TextDrawCmd {
            text: format!(
                "已收藏 {} 条 · 支持 .iclip / Raycast / CSV",
                st.store.pinned_count()
            ),
            rect: RECT {
                left: pad + s(12),
                top: sec_base_y + s(94),
                right: imp_x - s(8),
                bottom: sec_base_y + s(114),
            },
            color: palette.text_secondary,
            font_kind: FontKind::Meta,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
    }
    y += g4_h + s(14);

    // ── 分组 5：帮助（按需展开的键盘快捷键速查表，默认折叠不刷屏）──
    if visible_block(y, s(18)) {
        draw_group_header(texts, pad, y, content_w, s(18), "帮助", palette);
    }
    y += s(22);

    let sc_list = [
        (
            "呼出 / 隐藏面板",
            st.store.config.hotkey_toggle.display_string(),
        ),
        ("直接键入光标处", "双击 / Enter".to_string()),
        ("左 / 右切换类目", "Shift+Tab / Tab".to_string()),
        ("标记 / 完成待办事项", "Ctrl + T".to_string()),
        ("设为粘贴一次后无痕自毁", "Ctrl + B".to_string()),
        ("设置备注标题（自动收藏）", "Ctrl + R".to_string()),
        ("原位速览 / 行级差异比对", "Space / Alt+Space".to_string()),
        ("快速键入前 9 条", "Ctrl + 1 ~ 9".to_string()),
    ];
    let g5_h = if st.show_shortcut_ref {
        s(76) + (sc_list.len() as i32) * s(28) + s(6)
    } else {
        s(76)
    };
    if visible_block(y, g5_h) {
        canvas.fill_round_rect(pad, y, content_w, g5_h, sf(14.0), palette.group_fill);
        canvas.stroke_round_rect(
            pad,
            y,
            content_w,
            g5_h,
            sf(14.0),
            sf(0.75),
            palette.group_stroke,
        );
        texts.push(TextDrawCmd {
            text: "查看新手与新功能引导".to_string(),
            rect: RECT {
                left: pad + s(12),
                top: y,
                right: w - pad - s(36),
                bottom: y + s(38),
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        });
        canvas.draw_icon_star(
            (w - pad - s(18)) as f32,
            (y + s(19)) as f32,
            sf(12.0),
            sf(1.35),
            palette.cobalt,
            true,
        );
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: pad,
                top: y,
                right: w - pad,
                bottom: y + s(38),
            },
            interactive_cursor: true,
            action: HitAction::ShowHighlightsOverlay,
        });

        let ky = y + s(38);
        canvas.draw_line(
            (pad + s(12)) as f32,
            ky as f32,
            (w - pad - s(12)) as f32,
            ky as f32,
            sf(0.7),
            palette.divider,
        );
        texts.push(TextDrawCmd {
            text: "键盘快捷键速查".to_string(),
            rect: RECT {
                left: pad + s(12),
                top: ky,
                right: w - pad - s(36),
                bottom: ky + s(38),
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        });
        canvas.draw_icon_chevron_ud(
            (w - pad - s(18)) as f32,
            (ky + s(19)) as f32,
            sf(11.0),
            sf(1.5),
            palette.text_secondary,
            st.show_shortcut_ref,
        );
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: pad,
                top: ky,
                right: w - pad,
                bottom: ky + s(38),
            },
            interactive_cursor: true,
            action: HitAction::ToggleShortcutRef,
        });

        if st.show_shortcut_ref {
            let mut sy = ky + s(38);
            for (desc, key_str) in sc_list {
                canvas.draw_line(
                    (pad + s(12)) as f32,
                    sy as f32,
                    (w - pad - s(12)) as f32,
                    sy as f32,
                    sf(0.7),
                    palette.divider,
                );
                texts.push(TextDrawCmd {
                    text: desc.to_string(),
                    rect: RECT {
                        left: pad + s(12),
                        top: sy,
                        right: w - pad - s(130),
                        bottom: sy + s(28),
                    },
                    color: palette.text_primary,
                    font_kind: FontKind::Body,
                    flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
                });
                let kw = (key_str.chars().count() as i32) * s(7) + s(16);
                let kx = w - pad - s(12) - kw;
                canvas.fill_round_rect(kx, sy + s(5), kw, s(18), sf(9.0), palette.chip_bg);
                texts.push(TextDrawCmd {
                    text: key_str,
                    rect: RECT {
                        left: kx,
                        top: sy + s(5),
                        right: kx + kw,
                        bottom: sy + s(23),
                    },
                    color: palette.text_secondary,
                    font_kind: FontKind::KeyCap,
                    flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                });
                sy += s(28);
            }
        }
    }
    y += g5_h + s(14);

    // ── 底部操作双按钮（复刻 ClipboardPopoverView.swift:1789-1814）──
    let b_row_h = s(36);
    if visible_block(y, b_row_h) {
        let half_w = (content_w - s(10)) / 2;
        canvas.fill_round_rect(pad, y, half_w, b_row_h, sf(10.0), palette.chip_bg);
        texts.push(TextDrawCmd {
            text: "清空未收藏历史".to_string(),
            rect: RECT {
                left: pad,
                top: y,
                right: pad + half_w,
                bottom: y + b_row_h,
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: pad,
                top: y,
                right: pad + half_w,
                bottom: y + b_row_h,
            },
            interactive_cursor: true,
            action: HitAction::ClearUnpinnedHistory,
        });

        let qx = pad + half_w + s(10);
        canvas.fill_round_rect(
            qx,
            y,
            half_w,
            b_row_h,
            sf(10.0),
            palette.danger.with_alpha(28),
        );
        texts.push(TextDrawCmd {
            text: "退出 iClip".to_string(),
            rect: RECT {
                left: qx,
                top: y,
                right: qx + half_w,
                bottom: y + b_row_h,
            },
            color: palette.danger,
            font_kind: FontKind::CardTitle,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: qx,
                top: y,
                right: qx + half_w,
                bottom: y + b_row_h,
            },
            interactive_cursor: true,
            action: HitAction::QuitApp,
        });
    }
    y += b_row_h + s(18);

    canvas.reset_vertical_clip();

    // 裁剪设置滚动区点击热区至视口范围，防止滚出视口外的隐形行误触顶栏
    let mut clipped_hits = Vec::with_capacity(st.hit_regions.len());
    for (idx, mut hit) in st.hit_regions.drain(..).enumerate() {
        if idx >= scroll_hit_start {
            hit.rect.top = hit.rect.top.max(view_top);
            hit.rect.bottom = hit.rect.bottom.min(view_bottom);
            if hit.rect.bottom <= hit.rect.top {
                continue;
            }
        }
        clipped_hits.push(hit);
    }
    st.hit_regions = clipped_hits;

    let total_content_h = (y + st.settings_scroll_px) - view_top;
    let visible_h = (view_bottom - view_top).max(1);
    st.settings_max_scroll_px = (total_content_h - visible_h).max(0);

    // 若设置页下方尚有可滚动内容，绘制原生极细悬浮滚动条与底部轻柔渐隐过渡，彻底告别硬切感
    if st.settings_max_scroll_px > 0 {
        let track_h_sb = (view_bottom - view_top - s(8)).max(s(40));
        let thumb_h = ((visible_h as f32 / total_content_h.max(1) as f32) * track_h_sb as f32)
            .round()
            .clamp(sf(34.0), (track_h_sb - s(16)) as f32) as i32;
        let scroll_ratio =
            (st.settings_scroll_px as f32 / st.settings_max_scroll_px as f32).clamp(0.0, 1.0);
        let thumb_y =
            view_top + s(4) + ((track_h_sb - thumb_h) as f32 * scroll_ratio).round() as i32;
        let sb_w = s(3);
        let sb_x = w - s(6);
        canvas.fill_round_rect(
            sb_x,
            thumb_y,
            sb_w,
            thumb_h,
            sf(1.5),
            palette
                .text_muted
                .with_alpha(if st.is_dark_mode { 115 } else { 95 }),
        );
        if st.settings_scroll_px < st.settings_max_scroll_px - s(4) {
            let fade_h = s(18);
            let fade_top = Color4::rgba(
                palette.window_bg.r,
                palette.window_bg.g,
                palette.window_bg.b,
                0,
            );
            let fade_bot = Color4::rgba(
                palette.window_bg.r,
                palette.window_bg.g,
                palette.window_bg.b,
                if st.is_dark_mode { 228 } else { 232 },
            );
            canvas.fill_vgrad_round_rect(
                pad,
                view_bottom - fade_h,
                content_w,
                fade_h + s(4),
                sf(8.0),
                fade_top,
                fade_bot,
            );
        }
    }

    (scroll_text_start, view_top, view_bottom)
}

fn draw_group_header(
    texts: &mut Vec<TextDrawCmd>,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    title: &str,
    palette: &GlassPalette,
) {
    texts.push(TextDrawCmd {
        text: title.to_string(),
        rect: RECT {
            left: x + 8,
            top: y,
            right: x + w,
            bottom: y + h,
        },
        color: palette.text_secondary,
        font_kind: FontKind::BadgeBold,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
    });
}

#[allow(clippy::too_many_arguments)]
fn draw_grouped_toggle_row(
    canvas: &mut PixelCanvas,
    texts: &mut Vec<TextDrawCmd>,
    st: &mut WinAppState,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    scale: f32,
    palette: &GlassPalette,
    title: &str,
    subtitle: &str,
    is_on: bool,
    accent: Color4,
    action: HitAction,
) {
    let s = |v: i32| ((v as f32) * scale).round() as i32;
    let sf = |v: f32| v * scale;
    let sw_w = s(38);
    let sw_h = s(22);
    let sw_x = x + w - s(14) - sw_w;
    let sw_y = y + (h - sw_h) / 2;
    canvas.draw_toggle_switch(sw_x, sw_y, sw_w, sw_h, is_on, accent);

    // 自动剥离全角括号快捷键（如「窗口始终在前（Ctrl+P）」），转为标题右侧精致等宽物理微键帽！
    let (clean_title, shortcut_cap) =
        if let (Some(open), Some(close)) = (title.find('（'), title.rfind('）')) {
            if close > open {
                let inner = title[open + '（'.len_utf8()..close].trim();
                if inner.is_ascii() && !inner.is_empty() {
                    (title[..open].trim(), Some(inner))
                } else {
                    (title, None)
                }
            } else {
                (title, None)
            }
        } else {
            (title, None)
        };

    let title_left = x + s(14);
    let title_top = y + s(7);
    let title_bot = y + s(26);
    if let Some(key_txt) = shortcut_cap {
        let tw = estimate_text_px(clean_title, sf(13.5)) + s(4);
        let kw = (estimate_text_px(key_txt, sf(10.5)) + s(12)).max(s(36));
        let max_tw = (sw_x - s(14) - title_left - kw - s(8)).max(s(60));
        let used_tw = tw.min(max_tw);
        texts.push(TextDrawCmd {
            text: clean_title.to_string(),
            rect: RECT {
                left: title_left,
                top: title_top,
                right: title_left + used_tw,
                bottom: title_bot,
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
        let kx = title_left + used_tw + s(6);
        let kh = s(17);
        let ky = title_top + (title_bot - title_top - kh) / 2;
        canvas.fill_round_rect(kx, ky, kw, kh, sf(5.0), palette.chip_bg);
        canvas.stroke_round_rect(kx, ky, kw, kh, sf(5.0), sf(0.65), palette.card_border);
        texts.push(TextDrawCmd {
            text: key_txt.to_string(),
            rect: RECT {
                left: kx,
                top: ky,
                right: kx + kw,
                bottom: ky + kh,
            },
            color: palette.text_secondary,
            font_kind: FontKind::KeyCap,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
    } else {
        texts.push(TextDrawCmd {
            text: clean_title.to_string(),
            rect: RECT {
                left: title_left,
                top: title_top,
                right: sw_x - s(10),
                bottom: title_bot,
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
    }

    texts.push(TextDrawCmd {
        text: subtitle.to_string(),
        rect: RECT {
            left: title_left,
            top: y + s(27),
            right: sw_x - s(10),
            bottom: y + h - s(6),
        },
        color: palette.text_secondary,
        font_kind: FontKind::Meta,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
    });
    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: x,
            top: y,
            right: x + w,
            bottom: y + h,
        },
        interactive_cursor: true,
        action,
    });
}

// ============================================================================
// 悬浮灵动胶囊 `toastPill` 与原位速览 / Diff 浮层
// ============================================================================

#[allow(clippy::too_many_arguments)]
fn layout_and_draw_toast_pill(
    canvas: &mut PixelCanvas,
    texts: &mut Vec<TextDrawCmd>,
    w: i32,
    h: i32,
    scale: f32,
    palette: &GlassPalette,
    st: &mut WinAppState,
    msg: &str,
) {
    let s = |v: i32| ((v as f32) * scale).round() as i32;
    let sf = |v: f32| v * scale;

    let can_undo = st.store.has_active_undo(now_unix_secs())
        && (msg.contains("删除") || msg.contains("清空") || msg.contains("Ctrl+Z"));
    let text_w = (estimate_text_px(msg, sf(13.8)) + s(34)).clamp(s(148), w - s(24));
    let pill_w = if can_undo {
        (text_w + s(54)).min(w - s(20))
    } else {
        text_w
    };
    let pill_h = s(30);
    let px = (w - pill_w) / 2;
    let py = h - s(58) - pill_h;

    canvas.draw_soft_shadow_round_rect(
        px,
        py,
        pill_w,
        pill_h,
        sf(15.0),
        sf(2.5),
        sf(6.0),
        Color4::rgba(0, 0, 0, 58),
    );
    canvas.fill_round_rect(
        px,
        py,
        pill_w,
        pill_h,
        sf(15.0),
        if st.is_dark_mode {
            Color4::rgba(28, 33, 46, 242)
        } else {
            Color4::rgba(22, 25, 34, 234)
        },
    );
    canvas.stroke_round_rect(
        px,
        py,
        pill_w,
        pill_h,
        sf(15.0),
        sf(0.8),
        Color4::rgba(255, 255, 255, 48),
    );

    if can_undo {
        let uw = s(44);
        let uh = s(20);
        let ux = px + pill_w - uw - s(6);
        let uy = py + (pill_h - uh) / 2;
        canvas.fill_round_rect(ux, uy, uw, uh, sf(10.0), Color4::rgb(255, 255, 255));
        texts.push(TextDrawCmd {
            text: "撤销".to_string(),
            rect: RECT {
                left: ux,
                top: uy,
                right: ux + uw,
                bottom: uy + uh,
            },
            color: palette.cobalt,
            font_kind: FontKind::BadgeBold,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
        st.hit_regions.insert(
            0,
            HitRegion {
                rect: RECT {
                    left: ux,
                    top: uy,
                    right: ux + uw,
                    bottom: uy + uh,
                },
                interactive_cursor: true,
                action: HitAction::UndoDelete,
            },
        );
        texts.push(TextDrawCmd {
            text: msg.to_string(),
            rect: RECT {
                left: px + s(14),
                top: py,
                right: ux - s(6),
                bottom: py + pill_h,
            },
            color: Color4::rgb(255, 255, 255),
            font_kind: FontKind::Body,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
    } else {
        texts.push(TextDrawCmd {
            text: msg.to_string(),
            rect: RECT {
                left: px + s(14),
                top: py,
                right: px + pill_w - s(14),
                bottom: py + pill_h,
            },
            color: Color4::rgb(255, 255, 255),
            font_kind: FontKind::Body,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
    }
}

fn layout_and_draw_quick_look_overlay(
    canvas: &mut PixelCanvas,
    texts: &mut Vec<TextDrawCmd>,
    w: i32,
    h: i32,
    scale: f32,
    palette: &GlassPalette,
    st: &mut WinAppState,
) {
    let s = |v: i32| ((v as f32) * scale).round() as i32;
    let sf = |v: f32| v * scale;

    st.hit_regions.clear();
    canvas.fill_round_rect(
        0,
        0,
        w,
        h,
        sf(18.0),
        if st.is_dark_mode {
            Color4::rgba(8, 10, 14, 186)
        } else {
            Color4::rgba(15, 23, 42, 112)
        },
    );

    let mx = s(16);
    let my = s(36);
    let mw = w - mx * 2;
    let mh = h - my * 2;
    let modal_bg = if st.is_dark_mode {
        Color4::rgb(26, 28, 35)
    } else {
        Color4::rgb(250, 251, 254)
    };
    canvas.draw_soft_shadow_round_rect(
        mx,
        my,
        mw,
        mh,
        sf(16.0),
        sf(6.0),
        sf(14.0),
        Color4::rgba(0, 0, 0, 76),
    );
    canvas.fill_round_rect(mx, my, mw, mh, sf(16.0), modal_bg);
    canvas.stroke_round_rect(mx, my, mw, mh, sf(16.0), sf(0.85), palette.group_stroke);

    let filtered = st.store.filtered_indices_ext(
        st.selected_tab,
        st.selected_pin_category,
        &st.search_query,
        st.active_target_app_name.as_deref(),
    );
    let Some(&store_idx) = filtered.get(st.selected_visible_pos) else {
        st.show_quick_look = false;
        return;
    };
    let item = st.store.items[store_idx].clone();

    let tab_w = s(84);
    let tab_h = s(24);
    for (i, (lbl, is_diff)) in [("全文速览", false), ("差异比对", true)]
        .into_iter()
        .enumerate()
    {
        let tx = mx + s(12) + (i as i32) * (tab_w + s(6));
        let ty = my + s(11);
        let active = st.quick_look_diff_mode == is_diff;
        canvas.fill_round_rect(
            tx,
            ty,
            tab_w,
            tab_h,
            sf(12.0),
            if active {
                palette.cobalt
            } else {
                palette.chip_bg
            },
        );
        let rc = RECT {
            left: tx,
            top: ty,
            right: tx + tab_w,
            bottom: ty + tab_h,
        };
        texts.push(TextDrawCmd {
            text: lbl.to_string(),
            rect: rc,
            color: if active {
                Color4::rgb(255, 255, 255)
            } else {
                palette.text_secondary
            },
            font_kind: FontKind::BadgeBold,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
        st.hit_regions.push(HitRegion {
            rect: rc,
            interactive_cursor: true,
            action: HitAction::ToggleQuickLookDiffMode,
        });
    }

    let close_sz = s(24);
    let cx = mx + mw - close_sz - s(10);
    let cy = my + s(11);
    canvas.fill_circle(
        (cx + close_sz / 2) as f32,
        (cy + close_sz / 2) as f32,
        sf(12.0),
        palette.chip_bg,
    );
    canvas.draw_icon_close(
        (cx + close_sz / 2) as f32,
        (cy + close_sz / 2) as f32,
        sf(9.5),
        sf(1.5),
        palette.text_primary,
    );
    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: cx,
            top: cy,
            right: cx + close_sz,
            bottom: cy + close_sz,
        },
        interactive_cursor: true,
        action: HitAction::CloseOverlay,
    });

    if let Some(txt_for_metrics) = item.text.as_deref().or_else(|| item.ocr_text.as_deref()) {
        texts.push(TextDrawCmd {
            text: iclip_core::security::text_metrics_summary(txt_for_metrics),
            rect: RECT {
                left: mx + s(194),
                top: my + s(11),
                right: cx - s(8),
                bottom: my + s(35),
            },
            color: palette.text_muted,
            font_kind: FontKind::Meta,
            flags: DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
    }

    let body_top = my + s(44);
    let body_bottom = my + mh - s(32);

    if st.quick_look_diff_mode {
        let cur_isolated = item.is_burn_after_paste()
            || iclip_core::security::contains_secret_capsule(item.text.as_deref());
        let cur_txt = if cur_isolated {
            ""
        } else {
            item.text.as_deref().unwrap_or("")
        };
        let older_txt = if cur_isolated {
            ""
        } else {
            st.store
                .items
                .iter()
                .enumerate()
                .find(|(idx, it)| {
                    *idx != store_idx
                        && it.text.is_some()
                        && !it.is_burn_after_paste()
                        && !iclip_core::security::contains_secret_capsule(it.text.as_deref())
                })
                .and_then(|(_, it)| it.text.as_deref())
                .unwrap_or("")
        };
        let diff = if cur_isolated {
            iclip_core::intelligence::ClipboardDiffSummary {
                added_count: 0,
                removed_count: 0,
                json_semantically_equal: false,
                lines: vec![iclip_core::intelligence::DiffLine {
                    kind: DiffLineKind::Unchanged,
                    text: "粘贴即焚或密文信封已开启跨卡隔离保护，不参与差异比对".to_string(),
                }],
            }
        } else {
            compute_clipboard_diff(older_txt, cur_txt)
        };

        texts.push(TextDrawCmd {
            text: format!("对比上一条文本记录：{}", diff.badge_title()),
            rect: RECT {
                left: mx + s(14),
                top: body_top,
                right: mx + mw - s(14),
                bottom: body_top + s(22),
            },
            color: palette.cobalt,
            font_kind: FontKind::BadgeBold,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        });

        let mut ly = body_top + s(26);
        let lh = s(20);
        for dline in diff.lines.iter().skip(st.quick_look_scroll) {
            if ly + lh > body_bottom {
                break;
            }
            let (row_bg, fg) = match dline.kind {
                DiffLineKind::Added => (
                    Some(palette.emerald.with_alpha(32)),
                    if st.is_dark_mode {
                        Color4::rgb(110, 231, 152)
                    } else {
                        Color4::rgb(21, 128, 61)
                    },
                ),
                DiffLineKind::Removed => (
                    Some(palette.danger.with_alpha(28)),
                    if st.is_dark_mode {
                        Color4::rgb(252, 145, 145)
                    } else {
                        Color4::rgb(185, 28, 28)
                    },
                ),
                DiffLineKind::Collapsed(_) => (None, palette.text_muted),
                DiffLineKind::Unchanged => (None, palette.text_secondary),
            };
            if let Some(bg) = row_bg {
                canvas.fill_round_rect(mx + s(10), ly, mw - s(20), lh - s(1), sf(5.0), bg);
            }
            texts.push(TextDrawCmd {
                text: dline.text.clone(),
                rect: RECT {
                    left: mx + s(14),
                    top: ly,
                    right: mx + mw - s(14),
                    bottom: ly + lh,
                },
                color: fg,
                font_kind: FontKind::Mono,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            ly += lh;
        }
    } else if item.kind == ClipContentType::Image {
        if let Some(fname) = &item.image_file_name {
            let images_dir = st.store.images_dir.clone();
            if let Some((iw, ih, rgba)) =
                load_or_get_thumbnail(&mut st.thumb_cache, &images_dir, fname)
            {
                canvas.blit_rgba_round_rect(
                    mx + s(14),
                    body_top,
                    mw - s(28),
                    body_bottom - body_top - s(8),
                    sf(12.0),
                    rgba,
                    iw,
                    ih,
                );
            }
        }
    } else {
        let full = item
            .text
            .clone()
            .or_else(|| item.file_paths.as_ref().map(|p| p.join("\n")))
            .unwrap_or_default();
        let lines: Vec<&str> = full.lines().skip(st.quick_look_scroll).take(22).collect();
        texts.push(TextDrawCmd {
            text: lines.join("\r\n"),
            rect: RECT {
                left: mx + s(14),
                top: body_top,
                right: mx + mw - s(14),
                bottom: body_bottom,
            },
            color: palette.text_primary,
            font_kind: FontKind::Body,
            flags: DT_LEFT | DT_WORDBREAK,
        });
    }

    texts.push(TextDrawCmd {
        text: "Space / Esc 关闭 · Alt+Space 切换差异比对 · Enter 立即粘贴".to_string(),
        rect: RECT {
            left: mx + s(12),
            top: my + mh - s(28),
            right: mx + mw - s(12),
            bottom: my + mh - s(6),
        },
        color: palette.text_muted,
        font_kind: FontKind::Meta,
        flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
    });
}

fn layout_and_draw_highlights_overlay(
    canvas: &mut PixelCanvas,
    texts: &mut Vec<TextDrawCmd>,
    w: i32,
    h: i32,
    scale: f32,
    palette: &GlassPalette,
    st: &mut WinAppState,
) {
    let s = |v: i32| ((v as f32) * scale).round() as i32;
    let sf = |v: f32| v * scale;

    st.hit_regions.clear();
    canvas.fill_round_rect(
        0,
        0,
        w,
        h,
        sf(18.0),
        if st.is_dark_mode {
            Color4::rgba(8, 10, 14, 152)
        } else {
            Color4::rgba(15, 23, 42, 72)
        },
    );

    let mw = s(364).min(w - s(24));
    let mh = s(386).min(h - s(36));
    let mx = (w - mw) / 2;
    let my = (h - mh) / 2;

    canvas.draw_soft_shadow_round_rect(
        mx,
        my,
        mw,
        mh,
        sf(20.0),
        sf(6.0),
        sf(18.0),
        Color4::rgba(0, 0, 0, if st.is_dark_mode { 98 } else { 42 }),
    );
    let modal_bg = if st.is_dark_mode {
        Color4::rgba(26, 29, 38, 250)
    } else {
        Color4::rgba(250, 252, 255, 252)
    };
    canvas.fill_round_rect(mx, my, mw, mh, sf(20.0), modal_bg);

    let ver_short = {
        let parts: Vec<&str> = env!("CARGO_PKG_VERSION").split('.').collect();
        if parts.len() >= 2 {
            format!("{}.{}", parts[0], parts[1])
        } else {
            env!("CARGO_PKG_VERSION").to_string()
        }
    };
    texts.push(TextDrawCmd {
        text: format!("欢迎使用 iClip {ver_short}"),
        rect: RECT {
            left: mx + s(22),
            top: my + s(20),
            right: mx + mw - s(22),
            bottom: my + s(46),
        },
        color: palette.text_primary,
        font_kind: FontKind::Display,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
    });
    texts.push(TextDrawCmd {
        text: "轻如无物，一呼即贴 · 按 Enter 立即开始".to_string(),
        rect: RECT {
            left: mx + s(22),
            top: my + s(46),
            right: mx + mw - s(22),
            bottom: my + s(66),
        },
        color: palette.text_secondary,
        font_kind: FontKind::Meta,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
    });

    let tints = [
        Color4::rgb(30, 94, 255),
        Color4::rgb(20, 158, 115),
        Color4::rgb(56, 122, 245),
        Color4::rgb(40, 143, 133),
    ];

    let mut ry = my + s(78);
    for (idx, (title, detail)) in iclip_core::store::CORE_HIGHLIGHTS_V27.iter().enumerate() {
        let bx = mx + s(22);
        let by = ry + s(2);
        let bsz = s(32);
        let tint = tints[idx];
        canvas.fill_round_rect(
            bx,
            by,
            bsz,
            bsz,
            sf(9.0),
            tint.with_alpha(if st.is_dark_mode { 56 } else { 34 }),
        );
        let icx = (bx + bsz / 2) as f32;
        let icy = (by + bsz / 2) as f32;
        match idx {
            0 => canvas.draw_icon_bolt(icx, icy, sf(14.0), sf(1.5), tint),
            1 => canvas.draw_icon_check_circle(
                icx,
                icy,
                sf(15.0),
                sf(1.5),
                tint,
                true,
                Color4::rgb(255, 255, 255),
            ),
            2 => canvas.draw_icon_clipboard(icx, icy, sf(14.0), sf(1.5), tint),
            _ => canvas.draw_icon_leaf(icx, icy, sf(14.0), sf(1.5), tint),
        }

        texts.push(TextDrawCmd {
            text: (*title).to_string(),
            rect: RECT {
                left: bx + bsz + s(11),
                top: ry,
                right: mx + mw - s(20),
                bottom: ry + s(20),
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        });
        texts.push(TextDrawCmd {
            text: (*detail).to_string(),
            rect: RECT {
                left: bx + bsz + s(11),
                top: ry + s(20),
                right: mx + mw - s(20),
                bottom: ry + s(54),
            },
            color: palette.text_secondary,
            font_kind: FontKind::Meta,
            flags: DT_LEFT | DT_WORDBREAK,
        });
        ry += s(60);
    }

    let btn_x = mx + s(22);
    let btn_w = mw - s(44);
    let btn_h = s(36);
    let btn_y = my + mh - btn_h - s(18);
    canvas.fill_round_rect(
        btn_x,
        btn_y,
        btn_w,
        btn_h,
        sf(18.0),
        Color4::rgb(30, 94, 255),
    );
    texts.push(TextDrawCmd {
        text: "开始使用".to_string(),
        rect: RECT {
            left: btn_x,
            top: btn_y,
            right: btn_x + btn_w,
            bottom: btn_y + btn_h,
        },
        color: Color4::rgb(255, 255, 255),
        font_kind: FontKind::CardTitle,
        flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
    });

    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: 0,
            top: 0,
            right: w,
            bottom: h,
        },
        interactive_cursor: true,
        action: HitAction::DismissHighlightsOverlay,
    });
}

// ============================================================================
// 鼠标跟手拖拽、手型光标、全键盘快捷键交互与系统托盘菜单
// ============================================================================

fn point_in_rect(x: i32, y: i32, r: &RECT) -> bool {
    x >= r.left && x < r.right && y >= r.top && y < r.bottom
}

unsafe fn apply_slider_drag_pct(hwnd: HWND, x: i32, track_left: i32, track_width: i32) {
    let mut raw_pct = (((x - track_left) as f32 / (track_width.max(1) as f32)) * 100.0)
        .round()
        .clamp(0.0, 100.0) as u8;
    // 官方三档磁吸锚点（8% · 45% · 88%）
    for anchor in [8u8, 45, 88] {
        if raw_pct.abs_diff(anchor) <= 2 {
            raw_pct = anchor;
            break;
        }
    }
    let mapped_mode = if raw_pct < 26 {
        GlassAppearance::Clear
    } else if raw_pct >= 85 {
        GlassAppearance::Solid
    } else {
        GlassAppearance::Tinted
    };
    let mut is_dark = false;
    let mut changed = false;
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            is_dark = st.is_dark_mode;
            if st.store.config.blur_concentration_pct != raw_pct {
                st.store.config.blur_concentration_pct = raw_pct;
                st.store.config.glass_appearance = mapped_mode;
                st.store.save_config();
                changed = true;
            }
        }
    });
    if changed {
        apply_dwm_glass_style(hwnd, is_dark, raw_pct);
        let _ = InvalidateRect(hwnd, null(), FALSE);
    }
}

unsafe fn handle_mouse_move(hwnd: HWND, x: i32, y: i32, left_held: bool) {
    let drag_track = APP_STATE.with(|c| {
        let mut b = c.borrow_mut();
        let st = b.as_mut()?;
        if !left_held {
            st.dragging_slider_track = None;
        }
        st.dragging_slider_track
    });
    if let Some((tl, tw)) = drag_track {
        apply_slider_drag_pct(hwnd, x, tl, tw);
        SetCursor(LoadCursorW(null_mut(), IDC_HAND));
        return;
    }

    let mut changed = false;
    let mut use_hand = false;

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            let mut found_badge_idx = None;
            for reg in &st.hit_regions {
                if point_in_rect(x, y, &reg.rect) {
                    use_hand = reg.interactive_cursor;
                    if let HitAction::OpenExternalTarget(si) = reg.action {
                        found_badge_idx = Some(si);
                    }
                    break;
                }
            }
            if st.hovered_link_badge_store_idx != found_badge_idx {
                st.hovered_link_badge_store_idx = found_badge_idx;
                changed = true;
            }

            let mut found_card = None;
            for reg in &st.hit_regions {
                if let HitAction::SelectCard(pos) = reg.action {
                    if point_in_rect(x, y, &reg.rect) {
                        found_card = Some(pos);
                        break;
                    }
                }
            }
            if st.hovered_visible_pos != found_card {
                st.hovered_visible_pos = found_card;
                changed = true;
            }
        }
    });

    let cursor_id = if use_hand { IDC_HAND } else { IDC_ARROW };
    SetCursor(LoadCursorW(null_mut(), cursor_id));

    if changed {
        let _ = InvalidateRect(hwnd, null(), FALSE);
    }
}

unsafe fn handle_left_click(hwnd: HWND, x: i32, y: i32, is_double: bool) {
    let hit = APP_STATE.with(|cell| {
        let borrow = cell.borrow();
        let st = borrow.as_ref()?;
        st.hit_regions
            .iter()
            .find(|r| point_in_rect(x, y, &r.rect))
            .map(|r| r.action.clone())
    });

    let Some(action) = hit else {
        if y < 52 && !is_double {
            let _ = ReleaseCapture();
            SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION as usize, 0);
        }
        return;
    };

    let ctrl_down = (GetKeyState(VK_CONTROL as i32) as u16 & 0x8000) != 0;

    match action {
        HitAction::FocusSearch => {
            activate_panel_for_input(hwnd);
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::ClearSearch => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.search_query.clear();
                    st.selected_visible_pos = 0;
                    st.scroll_row_offset = 0;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::ToggleMinimalMode => {
            let (now_min, next_tab) = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut().unwrap();
                st.store.config.minimal_mode_enabled = !st.store.config.minimal_mode_enabled;
                if st.store.config.minimal_mode_enabled && st.selected_tab == ClipFilterTab::Todo {
                    st.selected_tab = ClipFilterTab::All;
                }
                st.store.save_config();
                (st.store.config.minimal_mode_enabled, st.selected_tab)
            });
            start_tab_spring_to(hwnd, next_tab);
            set_toast(
                hwnd,
                if now_min {
                    "已开启极简纯净模式".to_string()
                } else {
                    "已恢复全量智能工具箱".to_string()
                },
            );
        }
        HitAction::ToggleAlwaysOnTop => {
            toggle_always_on_top(hwnd);
        }
        HitAction::ToggleSettingsView => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.view_mode = if st.view_mode == ActiveViewMode::Settings {
                        ActiveViewMode::MainList
                    } else {
                        st.autostart_cached = is_autostart_enabled();
                        ActiveViewMode::Settings
                    };
                    st.recording_slot = None;
                    st.hotkey_conflict_error = None;
                    st.hotkey_recording_hint = None;
                }
            });
            reload_global_hotkeys_and_hooks(hwnd);
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::SelectTab(tab) => {
            start_tab_spring_to(hwnd, tab);
        }
        HitAction::SelectPinCategory(cat) => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.selected_pin_category = cat;
                    st.selected_visible_pos = 0;
                    st.scroll_row_offset = 0;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::CommitMathResult(val) => {
            commit_direct_text_paste(hwnd, &val, format!("已键入计算结果 {val}"));
        }
        HitAction::CommitEphemeralSecret { secret, toast } => {
            commit_ephemeral_secret_paste(hwnd, &secret, toast);
        }
        HitAction::CommitLockedCapsule { plain, passphrase } => {
            let env_opt = APP_STATE.with(|c| {
                let b = c.borrow();
                let st = b.as_ref()?;
                iclip_core::security::seal_secret_capsule(&plain, &passphrase, &st.store.data_dir)
            });
            if let Some(env_str) = env_opt {
                commit_direct_text_paste(
                    hwnd,
                    &env_str,
                    "已生成端到端加密信封并键入（对方输入口令即可解锁）".to_string(),
                );
            } else {
                set_toast(hwnd, "加密失败：请检查口令与正文".to_string());
            }
        }
        HitAction::PinGeneratedSecret { secret, alias } => {
            let new_idx = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut()?;
                let intent = iclip_core::intelligence::QuickCaptureIntent {
                    alias: Some(alias),
                    body: secret.clone(),
                    default_pin: true,
                    default_todo: false,
                };
                let id = st.store.capture_quick_note(&intent)?;
                st.search_query.clear();
                st.store.items.iter().position(|i| i.id == id)
            });
            iclip_core::security::bump_password_generation_salt();
            if let Some(idx) = new_idx {
                commit_paste_item_by_index(hwnd, idx, false);
            }
        }
        HitAction::CommitQuickCapture => {
            commit_quick_capture_from_search(hwnd);
        }
        HitAction::CommitSuggestion(payload) => {
            apply_suggestion_with_theme_check(hwnd, &payload);
        }
        HitAction::SelectCard(vis_pos) => {
            let mut target_store_idx = None;
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.selected_visible_pos = vis_pos;
                    let filtered = st.store.filtered_indices_ext(
                        st.selected_tab,
                        st.selected_pin_category,
                        &st.search_query,
                        st.active_target_app_name.as_deref(),
                    );
                    target_store_idx = filtered.get(vis_pos).copied();
                }
            });
            if let Some(idx) = target_store_idx {
                if ctrl_down && !is_double {
                    let jumpable = APP_STATE.with(|c| {
                        c.borrow()
                            .as_ref()
                            .and_then(|s| s.store.items.get(idx))
                            .map(item_supports_external_jump)
                            .unwrap_or(false)
                    });
                    if jumpable {
                        open_item_external_target(hwnd, idx);
                        return;
                    }
                }
                if is_double {
                    commit_paste_item_by_index(hwnd, idx, false);
                } else {
                    // 对齐 macOS handleCardTap：单击即选中并静默复制 + 显示 `✓ 已复制` 内联轻反馈，双击键入！
                    copy_only_item_in_place(hwnd, idx);
                }
            }
        }
        HitAction::OpenExternalTarget(store_idx) => {
            open_item_external_target(hwnd, store_idx);
        }
        HitAction::TriggerQuickAction { item_idx, action } => {
            commit_quick_action(hwnd, item_idx, &action);
        }
        HitAction::CompressImageJpeg(store_idx) => {
            apply_image_studio_transform(hwnd, store_idx, true);
        }
        HitAction::MockupImagePng(store_idx) => {
            apply_image_studio_transform(hwnd, store_idx, false);
        }
        HitAction::TogglePin(id) => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.toggle_pin(&id);
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::ToggleTodo(id) => {
            let msg = APP_STATE.with(|c| {
                c.borrow_mut()
                    .as_mut()
                    .and_then(|st| st.store.toggle_todo(&id))
                    .map(|s| s.to_string())
            });
            if let Some(m) = msg {
                set_toast(hwnd, m);
            } else {
                let _ = InvalidateRect(hwnd, null(), FALSE);
            }
        }
        HitAction::ArchiveCompletedTodos => {
            let cnt = APP_STATE.with(|c| {
                c.borrow_mut()
                    .as_mut()
                    .map(|st| st.store.archive_completed_todos())
                    .unwrap_or(0)
            });
            if cnt > 0 {
                set_toast(hwnd, format!("已归档 {cnt} 项已完成待办"));
            }
        }
        HitAction::CopyTodosMarkdown => {
            let exported = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut()?;
                let (md, cnt) = st.store.format_todos_as_markdown()?;
                let has_sens_todo = st.store.items.iter().any(|it| {
                    it.is_todo()
                        && (it.detected_sensitive_kind().is_some() || it.is_burn_after_paste())
                }) || iclip_core::security::classify_sensitive_text(&md)
                    .is_some();
                let guard = WinClipboardLocalOnlyGuard {
                    block_cloud_and_history: has_sens_todo,
                    cf_excl: st.cf_exclude_monitor,
                    cf_can_hist: st.cf_can_include_history,
                    cf_can_cloud: st.cf_can_upload_cloud,
                };
                let need_scrub = has_sens_todo && st.store.config.auto_clear_concealed_clipboard;
                st.ignore_next_clipboard_seq = true;
                Some((md, cnt, guard, need_scrub))
            });
            if let Some((md, cnt, guard, need_scrub)) = exported {
                let _ = write_text_and_html_to_clipboard_ext(hwnd, &md, None, guard);
                if need_scrub {
                    let seq = GetClipboardSequenceNumber();
                    APP_STATE.with(|c| {
                        if let Some(st) = c.borrow_mut().as_mut() {
                            st.scrub_expected_seq_num = seq;
                        }
                    });
                    SetTimer(hwnd, TIMER_ID_CONCEALED_SCRUB, 45_000, None);
                }
                set_toast(hwnd, format!("✓ 已复制 {cnt} 条 Markdown 待办清单"));
            }
        }
        HitAction::SweepUnpinnedSensitive => {
            let cnt = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let Some(st) = b.as_mut() else { return 0 };
                let removed = st.store.sweep_all_unpinned_sensitive();
                st.selected_visible_pos = 0;
                removed
            });
            if cnt > 0 {
                set_toast(hwnd, format!("已无痕清扫 {cnt} 条未收藏敏感记录"));
            }
        }
        HitAction::CreateInlineTodo => {
            let created = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut()?;
                let q = st.search_query.trim().to_string();
                if q.is_empty() || q.starts_with('@') {
                    return None;
                }
                let (alias, body) = iclip_core::intelligence::split_alias_and_body(&q);
                let id = st.store.capture_quick_todo(&body, alias.as_deref())?;
                st.search_query.clear();
                st.selected_visible_pos = 0;
                st.scroll_row_offset = 0;
                Some(id)
            });
            if created.is_some() {
                set_toast(hwnd, "✓ 已加入待办清单".to_string());
            }
        }
        HitAction::ClearQueue => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.queue_mode_active = false;
                    st.store.paste_queue_ids.clear();
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::DeleteItem(id) => {
            delete_item_and_scrub_clipboard_if_needed(hwnd, &id);
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::UndoDelete => {
            let restored = APP_STATE.with(|c| {
                c.borrow_mut()
                    .as_mut()
                    .and_then(|st| st.store.undo_last_delete(now_unix_secs()))
            });
            if let Some(n) = restored {
                set_toast(hwnd, format!("已原位恢复 {n} 条记录"));
            }
        }
        HitAction::CloseOverlay => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.show_quick_look = false;
                    st.editing_alias_item_id = None;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::ToggleQuickLookDiffMode => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.quick_look_diff_mode = !st.quick_look_diff_mode;
                    st.quick_look_scroll = 0;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::SaveAliasEdit => {
            save_current_alias_draft(hwnd);
        }
        HitAction::StartRecordHotkey(slot) => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    if st.recording_slot == Some(slot) {
                        st.recording_slot = None;
                        st.hotkey_recording_hint = None;
                    } else {
                        st.recording_slot = Some(slot);
                        st.hotkey_conflict_error = None;
                        st.hotkey_recording_hint =
                            Some("按下组合键，或双击 Ctrl/Alt/Shift/Win 单键".to_string());
                        st.double_tap_machine.reset();
                    }
                }
            });
            reload_global_hotkeys_and_hooks(hwnd);
            let is_rec = APP_STATE.with(|c| {
                c.borrow()
                    .as_ref()
                    .map(|s| s.recording_slot.is_some())
                    .unwrap_or(false)
            });
            if is_rec {
                activate_panel_for_input(hwnd);
            }
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::ResetHotkeyDefault(slot) => {
            let def = match slot {
                WinHotKeySlot::MainToggle => WinHotKeyShortcut::default_toggle(),
                WinHotKeySlot::QueuePop | WinHotKeySlot::CopyAppend => {
                    WinHotKeyShortcut::default_queue_pop()
                }
            };
            apply_recorded_hotkey_candidate(hwnd, slot, def);
        }
        HitAction::SetBlurPreset(pct) => {
            let mapped = if pct < 26 {
                GlassAppearance::Clear
            } else if pct >= 85 {
                GlassAppearance::Solid
            } else {
                GlassAppearance::Tinted
            };
            let mut is_dark = false;
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    is_dark = st.is_dark_mode;
                    st.store.config.blur_concentration_pct = pct;
                    st.store.config.glass_appearance = mapped;
                    st.store.save_config();
                }
            });
            apply_dwm_glass_style(hwnd, is_dark, pct);
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::AdjustBlurConcentration {
            track_left,
            track_width,
        } => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.dragging_slider_track = Some((track_left, track_width));
                }
            });
            apply_slider_drag_pct(hwnd, x, track_left, track_width);
        }
        HitAction::ToggleAutoPaste => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.auto_paste_enabled);
        }
        HitAction::ToggleCopyAppend => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.copy_append_enabled);
            reload_global_hotkeys_and_hooks(hwnd);
        }
        HitAction::ToggleDoubleCopySpark => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.double_copy_spark_enabled);
        }
        HitAction::ToggleStripRichFormat => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.auto_strip_rich_formatting);
        }
        HitAction::ToggleAutoCleanUrl => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.auto_clean_tracking_url);
        }
        HitAction::ToggleAutoExpireOtp => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.auto_expire_otp);
        }
        HitAction::ToggleScreenSharePrivacy => {
            let next = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut().unwrap();
                st.store.config.screen_share_privacy = !st.store.config.screen_share_privacy;
                st.store.save_config();
                st.store.config.screen_share_privacy
            });
            apply_screen_capture_shield(hwnd, next);
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::ToggleSensitiveVeil => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.mask_sensitive_previews);
        }
        HitAction::ToggleAutoClearConcealed => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.auto_clear_concealed_clipboard);
        }
        HitAction::ToggleAutoExpireSecrets => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.auto_expire_unpinned_secrets);
        }
        HitAction::ToggleQueueMode => {
            let active = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut().unwrap();
                st.store.queue_mode_active = !st.store.queue_mode_active;
                st.store.queue_mode_active
            });
            set_toast(
                hwnd,
                if active {
                    "已开启顺序采集：连续 Ctrl+C 按序入队".to_string()
                } else {
                    "已结束顺序采集".to_string()
                },
            );
        }
        HitAction::ToggleQueueAutoTab => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.queue_auto_tab);
        }
        HitAction::ToggleAutostart => {
            let next = !is_autostart_enabled();
            set_autostart_enabled(next);
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.autostart_cached = next;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::SelectMaxHistory(cap) => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.config.max_history_count = cap;
                    st.store.trim_history_if_needed();
                    st.store.save_config();
                    st.store.save_history();
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::ExportArchive => export_archive_via_dialog(hwnd),
        HitAction::ImportArchive => import_archive_via_dialog(hwnd),
        HitAction::ClearUnpinnedHistory => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.clear_unpinned();
                    st.view_mode = ActiveViewMode::MainList;
                }
            });
            set_toast(hwnd, "已清空未收藏历史 · Ctrl+Z 可恢复".to_string());
        }
        HitAction::TogglePauseCapture => {
            let paused = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut().unwrap();
                st.store.toggle_timed_pause(15, now_unix_secs())
            });
            set_toast(
                hwnd,
                if paused {
                    "已开启 15 分钟无痕暂停（到点自动恢复）".to_string()
                } else {
                    "已恢复记录剪贴板".to_string()
                },
            );
        }
        HitAction::ShowHighlightsOverlay => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.view_mode = ActiveViewMode::MainList;
                    st.show_highlights_overlay = true;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::DismissHighlightsOverlay => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.show_highlights_overlay = false;
                    if !st.store.config.has_seen_highlights_v27 {
                        st.store.config.has_seen_highlights_v27 = true;
                        st.store.save_config();
                    }
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::CheckForUpdates => {
            trigger_ota_check(hwnd, false);
        }
        HitAction::StartOtaDownload => {
            trigger_ota_download_and_install(hwnd);
        }
        HitAction::CancelOtaDownload => {
            cancel_ota_download(hwnd);
        }
        HitAction::ToggleShortcutRef => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.show_shortcut_ref = !st.show_shortcut_ref;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::QuitApp => {
            DestroyWindow(hwnd);
        }
    }
}

unsafe fn apply_suggestion_with_theme_check(hwnd: HWND, payload: &str) {
    let lower = payload.to_lowercase();
    let summary = APP_STATE.with(|c| {
        let mut b = c.borrow_mut();
        let st = b.as_mut().unwrap();
        st.search_query.clear();
        if lower.contains("浅色") || lower.contains("亮色") || lower.contains("白天") {
            st.theme_pref = ThemePreference::Light;
        } else if lower.contains("深色") || lower.contains("暗色") || lower.contains("夜间") {
            st.theme_pref = ThemePreference::Dark;
        } else if lower.contains("跟随系统") {
            st.theme_pref = ThemePreference::System;
        }
        let s = st.store.adopt_user_suggestion(payload);
        apply_dwm_glass_style(
            hwnd,
            st.is_dark_mode,
            st.store.config.blur_concentration_pct,
        );
        s
    });
    sync_effective_theme(hwnd);
    reload_global_hotkeys_and_hooks(hwnd);
    set_toast(hwnd, summary);
}

unsafe fn toggle_config_bool(
    hwnd: HWND,
    f: impl FnOnce(&mut iclip_core::store::StoreConfig) -> &mut bool,
) {
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            let field = f(&mut st.store.config);
            *field = !*field;
            st.store.save_config();
        }
    });
    let _ = InvalidateRect(hwnd, null(), FALSE);
}

unsafe fn toggle_always_on_top(hwnd: HWND) {
    let mut rc: RECT = zeroed();
    let has_rc = GetWindowRect(hwnd, &mut rc) != FALSE;
    let now_pin = APP_STATE.with(|c| {
        let mut b = c.borrow_mut();
        let st = b.as_mut().unwrap();
        st.store.config.always_on_top = !st.store.config.always_on_top;
        if st.store.config.always_on_top && has_rc {
            st.store.config.pinned_panel_pos = Some((rc.left, rc.top));
        }
        st.store.save_config();
        st.store.config.always_on_top
    });
    set_toast(
        hwnd,
        if now_pin {
            "窗口已固定始终在前".to_string()
        } else {
            "已恢复自动收起浮窗".to_string()
        },
    );
}

unsafe fn commit_quick_capture_from_search(hwnd: HWND) {
    let outcome = APP_STATE.with(|c| {
        let mut b = c.borrow_mut();
        let st = b.as_mut()?;
        let intent = parse_quick_capture(&st.search_query)?;
        let id = st.store.capture_quick_note(&intent)?;
        st.search_query.clear();
        st.selected_visible_pos = 0;
        st.scroll_row_offset = 0;
        Some((id, intent.default_pin, intent.default_todo))
    });
    if let Some((_id, pinned, is_todo)) = outcome {
        set_toast(
            hwnd,
            if is_todo {
                "✓ 已加入待办清单".to_string()
            } else if pinned {
                "已保存至收藏并自动识别分组".to_string()
            } else {
                "闪念速记已入库".to_string()
            },
        );
    }
}

unsafe fn save_current_alias_draft(hwnd: HWND) {
    let res = APP_STATE.with(|c| {
        let mut b = c.borrow_mut();
        let st = b.as_mut()?;
        let id = st.editing_alias_item_id.take()?;
        let draft = st.alias_draft.clone();
        st.alias_draft.clear();
        st.store.set_custom_alias(&id, &draft)
    });
    if let Some(auto_pinned) = res {
        set_toast(
            hwnd,
            if auto_pinned {
                "备注已保存，并自动点亮收藏保护".to_string()
            } else {
                "备注已更新".to_string()
            },
        );
    } else {
        let _ = InvalidateRect(hwnd, null(), FALSE);
    }
}

unsafe fn apply_image_studio_transform(hwnd: HWND, store_idx: usize, to_jpeg: bool) {
    let mut img_path = None;
    let mut auto_paste = true;
    let mut privacy_guard = WinClipboardLocalOnlyGuard::default();
    let mut item_id_opt: Option<String> = None;
    let mut is_pinned = false;
    let mut is_sensitive = false;
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            auto_paste = st.store.config.auto_paste_enabled;
            st.ignore_next_clipboard_seq = true;
            if let Some(it) = st.store.items.get(store_idx) {
                item_id_opt = Some(it.id.clone());
                is_pinned = it.is_pinned;
                is_sensitive = it.detected_sensitive_kind().is_some() || it.is_burn_after_paste();
                privacy_guard = WinClipboardLocalOnlyGuard {
                    block_cloud_and_history: is_sensitive,
                    cf_excl: st.cf_exclude_monitor,
                    cf_can_hist: st.cf_can_include_history,
                    cf_can_cloud: st.cf_can_upload_cloud,
                };
                if let Some(f) = &it.image_file_name {
                    img_path = Some(st.store.images_dir.join(f));
                }
            }
        }
    });
    let Some(path) = img_path else { return };
    let Some((dir, fname)) = path.parent().zip(path.file_name().and_then(|s| s.to_str())) else {
        return;
    };
    let Some(raw_png) = iclip_core::security::read_decrypted_image_from_dir(dir, fname) else {
        return;
    };

    let transformed: Option<Vec<u8>> = if to_jpeg {
        compress_png_to_white_bg_jpeg(&raw_png, 82)
    } else {
        render_mockup_frame_png(&raw_png, 36).map(|(b, _, _)| b)
    };
    if let Some(bytes) = transformed {
        let _ = write_image_bytes_to_clipboard_ext(hwnd, &bytes, privacy_guard);
        let mut scrub_ms: Option<u32> = None;
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                if let Some(id) = &item_id_opt {
                    if st.store.schedule_burn_after_paste_if_needed(id, 5) {
                        scrub_ms = Some(5_000);
                    } else if is_sensitive
                        && !is_pinned
                        && st.store.config.auto_clear_concealed_clipboard
                    {
                        scrub_ms = Some(45_000);
                    }
                }
            }
        });
        if let Some(delay_ms) = scrub_ms {
            let seq = GetClipboardSequenceNumber();
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.scrub_expected_seq_num = seq;
                }
            });
            SetTimer(hwnd, TIMER_ID_CONCEALED_SCRUB, delay_ms, None);
        }
        hide_panel(hwnd, true);
        if auto_paste {
            std::thread::sleep(std::time::Duration::from_millis(35));
            simulate_ctrl_v(false);
        }
    }
}

unsafe fn handle_key_down(hwnd: HWND, vk: u32) {
    let ctrl_down = (GetKeyState(VK_CONTROL as i32) as u16 & 0x8000) != 0;
    let alt_down = (GetKeyState(VK_MENU as i32) as u16 & 0x8000) != 0;
    let shift_down = (GetKeyState(VK_SHIFT as i32) as u16 & 0x8000) != 0;
    let win_down =
        ((GetKeyState(0x5B) as u16 & 0x8000) != 0) || ((GetKeyState(0x5C) as u16 & 0x8000) != 0);

    let active_rec_slot = APP_STATE.with(|c| c.borrow().as_ref().and_then(|s| s.recording_slot));
    if let Some(slot) = active_rec_slot {
        if vk == VK_ESCAPE as u32 {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.recording_slot = None;
                    st.hotkey_conflict_error = None;
                    st.hotkey_recording_hint = None;
                }
            });
            reload_global_hotkeys_and_hooks(hwnd);
            let _ = InvalidateRect(hwnd, null(), FALSE);
            return;
        }
        if WinSingleModifier::from_vk(vk).is_some() {
            return;
        }
        let mut mods = 0u32;
        if ctrl_down {
            mods |= MOD_CONTROL_BITS;
        }
        if alt_down {
            mods |= MOD_ALT_BITS;
        }
        if shift_down {
            mods |= MOD_SHIFT_BITS;
        }
        if win_down {
            mods |= MOD_WIN_BITS;
        }
        let candidate = WinHotKeyShortcut::combo(vk, mods);
        apply_recorded_hotkey_candidate(hwnd, slot, candidate);
        return;
    }

    let in_alias_edit = APP_STATE.with(|c| {
        c.borrow()
            .as_ref()
            .map(|s| s.editing_alias_item_id.is_some())
            .unwrap_or(false)
    });
    if in_alias_edit {
        if vk == VK_ESCAPE as u32 {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.editing_alias_item_id = None;
                    st.alias_draft.clear();
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        } else if vk == VK_RETURN as u32 {
            save_current_alias_draft(hwnd);
        }
        return;
    }

    let dismissed_highlights = APP_STATE.with(|c| {
        let mut b = c.borrow_mut();
        let Some(st) = b.as_mut() else { return false };
        if st.show_highlights_overlay && st.view_mode == ActiveViewMode::MainList {
            if vk == VK_ESCAPE as u32
                || vk == VK_RETURN as u32
                || vk == VK_SPACE as u32
                || (ctrl_down && !alt_down && !shift_down && vk == 0x57)
            {
                st.show_highlights_overlay = false;
                if !st.store.config.has_seen_highlights_v27 {
                    st.store.config.has_seen_highlights_v27 = true;
                    st.store.save_config();
                }
            }
            return true;
        }
        false
    });
    if dismissed_highlights {
        let _ = InvalidateRect(hwnd, null(), FALSE);
        return;
    }

    if vk == VK_ESCAPE as u32 || (ctrl_down && !alt_down && !shift_down && vk == 0x57) {
        let handled_inner = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let Some(st) = b.as_mut() else { return false };
            if st.show_quick_look {
                st.show_quick_look = false;
                return true;
            }
            if st.view_mode == ActiveViewMode::Settings {
                st.view_mode = ActiveViewMode::MainList;
                return true;
            }
            if vk == VK_ESCAPE as u32 && !st.search_query.is_empty() {
                st.search_query.clear();
                st.selected_visible_pos = 0;
                st.scroll_row_offset = 0;
                return true;
            }
            false
        });
        if handled_inner {
            let _ = InvalidateRect(hwnd, null(), FALSE);
        } else {
            hide_panel(hwnd, true);
        }
        return;
    }

    // Ctrl+V：在主列表非搜索输入聚焦态（或搜索词为空）时，直接粘贴当前选中的历史卡片
    if ctrl_down && !alt_down && !shift_down && vk == 0x56 {
        let paste_idx = APP_STATE.with(|c| {
            let b = c.borrow();
            let st = b.as_ref()?;
            if st.view_mode != ActiveViewMode::MainList {
                return None;
            }
            if GetForegroundWindow() == hwnd && !st.search_query.is_empty() {
                return None;
            }
            let filtered = st.store.filtered_indices_ext(
                st.selected_tab,
                st.selected_pin_category,
                &st.search_query,
                st.active_target_app_name.as_deref(),
            );
            filtered.get(st.selected_visible_pos).copied()
        });
        if let Some(idx) = paste_idx {
            commit_paste_item_by_index(hwnd, idx, false);
        }
        return;
    }

    if ctrl_down && vk == 0xBC {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.view_mode = if st.view_mode == ActiveViewMode::Settings {
                    ActiveViewMode::MainList
                } else {
                    st.autostart_cached = is_autostart_enabled();
                    ActiveViewMode::Settings
                };
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
        return;
    }

    if ctrl_down && !alt_down && !shift_down && vk == 0x50 {
        toggle_always_on_top(hwnd);
        return;
    }

    if ctrl_down && !alt_down && !shift_down && vk == 0x45 {
        let (now_min, next_tab) = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut().unwrap();
            st.store.config.minimal_mode_enabled = !st.store.config.minimal_mode_enabled;
            if st.store.config.minimal_mode_enabled && st.selected_tab == ClipFilterTab::Todo {
                st.selected_tab = ClipFilterTab::All;
            }
            st.store.save_config();
            (st.store.config.minimal_mode_enabled, st.selected_tab)
        });
        start_tab_spring_to(hwnd, next_tab);
        set_toast(
            hwnd,
            if now_min {
                "已开启极简纯净模式".to_string()
            } else {
                "已恢复全量智能工具箱".to_string()
            },
        );
        return;
    }

    if ctrl_down && !alt_down && !shift_down && vk == 0x42 {
        let msg = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut()?;
            if st.view_mode == ActiveViewMode::Settings {
                return None;
            }
            let filtered = st.store.filtered_indices_ext(
                st.selected_tab,
                st.selected_pin_category,
                &st.search_query,
                st.active_target_app_name.as_deref(),
            );
            let &store_idx = filtered.get(st.selected_visible_pos)?;
            let id = st.store.items[store_idx].id.clone();
            let on = st.store.toggle_burn_after_paste(&id)?;
            Some(if on {
                "已设为「粘贴即焚」· 粘贴 5 秒后无痕自毁".to_string()
            } else {
                "已取消粘贴即焚".to_string()
            })
        });
        if let Some(m) = msg {
            set_toast(hwnd, m);
            return;
        }
    }

    if ctrl_down && !alt_down && !shift_down && vk == 0x5A {
        let restored = APP_STATE.with(|c| {
            c.borrow_mut()
                .as_mut()
                .and_then(|st| st.store.undo_last_delete(now_unix_secs()))
        });
        if let Some(n) = restored {
            set_toast(hwnd, format!("已恢复 {n} 条记录"));
            return;
        }
    }

    if vk == VK_TAB as u32 && !ctrl_down && !alt_down {
        let next_tab_opt = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut()?;
            if st.view_mode == ActiveViewMode::Settings {
                return None;
            }
            let tabs = ClipFilterTab::visible_tabs(st.store.config.minimal_mode_enabled);
            let cur = tabs.iter().position(|&t| t == st.selected_tab).unwrap_or(0);
            let next = if shift_down {
                (cur + tabs.len() - 1) % tabs.len()
            } else {
                (cur + 1) % tabs.len()
            };
            Some(tabs[next])
        });
        if let Some(nt) = next_tab_opt {
            start_tab_spring_to(hwnd, nt);
        }
        return;
    }

    if alt_down && !ctrl_down && (0x31..=0x37).contains(&vk) {
        let idx = (vk - 0x31) as usize;
        let tab_opt = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut()?;
            let tabs = ClipFilterTab::visible_tabs(st.store.config.minimal_mode_enabled);
            let &t = tabs.get(idx)?;
            st.view_mode = ActiveViewMode::MainList;
            Some(t)
        });
        if let Some(t) = tab_opt {
            start_tab_spring_to(hwnd, t);
            return;
        }
    }

    if ctrl_down && (0x31..=0x39).contains(&vk) {
        let pos = (vk - 0x31) as usize;
        let mut target_idx = None;
        let mut top_act = None;
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow().as_ref() {
                let filtered = st.store.filtered_indices_ext(
                    st.selected_tab,
                    st.selected_pin_category,
                    &st.search_query,
                    st.active_target_app_name.as_deref(),
                );
                if let Some(&idx) = filtered.get(pos) {
                    target_idx = Some(idx);
                    if alt_down && !st.store.config.minimal_mode_enabled {
                        let item_snapshot = st.store.items[idx].clone();
                        top_act = item_quick_actions_for_ui(st, &item_snapshot)
                            .into_iter()
                            .next();
                    }
                }
            }
        });
        if let (Some(idx), Some(act)) = (target_idx, top_act) {
            commit_quick_action(hwnd, idx, &act);
        } else if let Some(idx) = target_idx {
            commit_paste_item_by_index(hwnd, idx, shift_down);
        }
        return;
    }

    if ctrl_down && !alt_down && vk == 0x54 {
        let msg = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut()?;
            if st.store.config.minimal_mode_enabled {
                return None;
            }
            let filtered = st.store.filtered_indices_ext(
                st.selected_tab,
                st.selected_pin_category,
                &st.search_query,
                st.active_target_app_name.as_deref(),
            );
            let idx = *filtered.get(st.selected_visible_pos)?;
            let id = st.store.items[idx].id.clone();
            st.store.toggle_todo(&id).map(|s| s.to_string())
        });
        if let Some(m) = msg {
            set_toast(hwnd, m);
        }
        return;
    }

    if ctrl_down && !alt_down && vk == 0x44 {
        let msg = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut()?;
            let filtered = st.store.filtered_indices_ext(
                st.selected_tab,
                st.selected_pin_category,
                &st.search_query,
                st.active_target_app_name.as_deref(),
            );
            let idx = *filtered.get(st.selected_visible_pos)?;
            let id = st.store.items[idx].id.clone();
            let pinned = st.store.toggle_pin(&id)?;
            Some(
                if pinned {
                    "已加入收藏"
                } else {
                    "已取消收藏"
                }
                .to_string(),
            )
        });
        if let Some(m) = msg {
            set_toast(hwnd, m);
        }
        return;
    }

    if ctrl_down && !alt_down && vk == 0x52 {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                let filtered = st.store.filtered_indices_ext(
                    st.selected_tab,
                    st.selected_pin_category,
                    &st.search_query,
                    st.active_target_app_name.as_deref(),
                );
                if let Some(&idx) = filtered.get(st.selected_visible_pos) {
                    let it = &st.store.items[idx];
                    st.editing_alias_item_id = Some(it.id.clone());
                    st.alias_draft = it.custom_alias.clone().unwrap_or_default();
                }
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
        return;
    }

    if ctrl_down && !alt_down && vk == 0x4F {
        let store_idx = APP_STATE.with(|c| {
            let b = c.borrow();
            let st = b.as_ref()?;
            let filtered = st.store.filtered_indices_ext(
                st.selected_tab,
                st.selected_pin_category,
                &st.search_query,
                st.active_target_app_name.as_deref(),
            );
            filtered.get(st.selected_visible_pos).copied()
        });
        if let Some(idx) = store_idx {
            open_item_external_target(hwnd, idx);
        }
        return;
    }

    if ctrl_down && vk == 0x4B {
        let msg = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut()?;
            let filtered = st.store.filtered_indices_ext(
                st.selected_tab,
                st.selected_pin_category,
                &st.search_query,
                st.active_target_app_name.as_deref(),
            );
            let idx = *filtered.get(st.selected_visible_pos)?;
            let id = st.store.items[idx].id.clone();
            Some(match st.store.toggle_queue_item(&id) {
                Some(n) => format!("已加入顺序粘贴队列 #{n}"),
                None => "已移出顺序粘贴队列".to_string(),
            })
        });
        if let Some(m) = msg {
            set_toast(hwnd, m);
        }
        return;
    }

    if vk == VK_SPACE as u32 {
        let toggled = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let Some(st) = b.as_mut() else { return false };
            if st.view_mode == ActiveViewMode::Settings {
                return false;
            }
            if alt_down {
                if st.show_quick_look && st.quick_look_diff_mode {
                    st.show_quick_look = false;
                } else {
                    st.show_quick_look = true;
                    st.quick_look_diff_mode = true;
                    st.quick_look_scroll = 0;
                }
                return true;
            }
            if st.search_query.is_empty() || st.show_quick_look {
                st.show_quick_look = !st.show_quick_look;
                st.quick_look_diff_mode = false;
                st.quick_look_scroll = 0;
                return true;
            }
            false
        });
        if toggled {
            let _ = InvalidateRect(hwnd, null(), FALSE);
            return;
        }
    }

    if matches!(vk as u16, VK_UP | VK_DOWN | VK_LEFT | VK_RIGHT) {
        let dir = match vk as u16 {
            VK_UP => GridMoveDir::Up,
            VK_DOWN => GridMoveDir::Down,
            VK_LEFT => GridMoveDir::Left,
            _ => GridMoveDir::Right,
        };
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                if st.view_mode == ActiveViewMode::Settings {
                    return;
                }
                let filtered = st.store.filtered_indices_ext(
                    st.selected_tab,
                    st.selected_pin_category,
                    &st.search_query,
                    st.active_target_app_name.as_deref(),
                );
                let rows = build_display_rows_ext(
                    &filtered,
                    &st.store.items,
                    st.selected_tab != ClipFilterTab::Todo,
                );
                st.selected_visible_pos =
                    grid_move_selection(&rows, st.selected_visible_pos, filtered.len(), dir);
                if let Some((r_idx, _)) =
                    iclip_core::canvas_ui::find_row_and_col(&rows, st.selected_visible_pos)
                {
                    if r_idx < st.scroll_row_offset {
                        st.scroll_row_offset = r_idx;
                    } else if r_idx >= st.scroll_row_offset + 5 {
                        st.scroll_row_offset = r_idx - 4;
                    }
                }
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
        return;
    }

    if vk == VK_DELETE as u32 {
        let mut target_id = None;
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                let filtered = st.store.filtered_indices_ext(
                    st.selected_tab,
                    st.selected_pin_category,
                    &st.search_query,
                    st.active_target_app_name.as_deref(),
                );
                if let Some(&idx) = filtered.get(st.selected_visible_pos) {
                    target_id = Some(st.store.items[idx].id.clone());
                }
            }
        });
        if let Some(id) = target_id {
            delete_item_and_scrub_clipboard_if_needed(hwnd, &id);
        }
        let _ = InvalidateRect(hwnd, null(), FALSE);
        return;
    }

    if vk == VK_RETURN as u32 {
        let query_snapshot = APP_STATE.with(|c| {
            c.borrow()
                .as_ref()
                .map(|s| s.search_query.clone())
                .unwrap_or_default()
        });
        if let Some(sug) = extract_suggestion_payload(&query_snapshot) {
            apply_suggestion_with_theme_check(hwnd, &sug);
            return;
        }
        if parse_quick_capture(&query_snapshot).is_some() {
            commit_quick_capture_from_search(hwnd);
            return;
        }
        let cap_cmd_opt = APP_STATE.with(|c| {
            let b = c.borrow();
            let st = b.as_ref()?;
            let filtered = st.store.filtered_indices_ext(
                st.selected_tab,
                st.selected_pin_category,
                &st.search_query,
                st.active_target_app_name.as_deref(),
            );
            let sel_store_idx = filtered.get(st.selected_visible_pos).copied();
            let data_dir = st.store.data_dir.clone();
            let cmd = iclip_core::security::evaluate_secret_capsule_command(
                &query_snapshot,
                st.store.latest_plain_for_capsule_lock(),
                st.store.latest_capsule_text(sel_store_idx),
            )?;
            Some((cmd, data_dir))
        });
        if let Some((cap_cmd, data_dir)) = cap_cmd_opt {
            match cap_cmd {
                iclip_core::security::SecretCapsuleCommand::LockReady {
                    passphrase,
                    plain_source,
                    ..
                } => {
                    if let Some(env_str) = iclip_core::security::seal_secret_capsule(
                        &plain_source,
                        &passphrase,
                        &data_dir,
                    ) {
                        commit_direct_text_paste(
                            hwnd,
                            &env_str,
                            "已生成端到端加密信封并键入（对方输入口令即可解锁）".to_string(),
                        );
                    }
                }
                iclip_core::security::SecretCapsuleCommand::UnlockDecrypted { decrypted_plain } => {
                    if shift_down {
                        let new_idx = APP_STATE.with(|c| {
                            let mut b = c.borrow_mut();
                            let st = b.as_mut()?;
                            let intent = iclip_core::intelligence::QuickCaptureIntent {
                                alias: Some("已解锁机密信封".to_string()),
                                body: decrypted_plain.clone(),
                                default_pin: true,
                                default_todo: false,
                            };
                            let id = st.store.capture_quick_note(&intent)?;
                            st.search_query.clear();
                            st.store.items.iter().position(|i| i.id == id)
                        });
                        if let Some(idx) = new_idx {
                            commit_paste_item_by_index(hwnd, idx, false);
                        }
                    } else {
                        commit_ephemeral_secret_paste_with_delay(
                            hwnd,
                            &decrypted_plain,
                            "已无痕键入解锁明文（不写入历史 · 30s后自动擦除）".to_string(),
                            30_000,
                        );
                    }
                }
                iclip_core::security::SecretCapsuleCommand::LockAwaitingInput { hint } => {
                    set_toast(hwnd, hint);
                }
                iclip_core::security::SecretCapsuleCommand::UnlockPending {
                    has_target_capsule,
                    ..
                } => {
                    set_toast(
                        hwnd,
                        if has_target_capsule {
                            "请输入正确的解锁口令".to_string()
                        } else {
                            "未在剪贴历史中找到 ICLPMSG1 密文信封".to_string()
                        },
                    );
                }
            }
            return;
        }
        if let Some(pw_cand) = iclip_core::security::evaluate_secure_password_query(&query_snapshot)
        {
            if shift_down {
                let new_idx = APP_STATE.with(|c| {
                    let mut b = c.borrow_mut();
                    let st = b.as_mut()?;
                    let intent = iclip_core::intelligence::QuickCaptureIntent {
                        alias: Some(pw_cand.default_vault_alias),
                        body: pw_cand.secret_value.clone(),
                        default_pin: true,
                        default_todo: false,
                    };
                    let id = st.store.capture_quick_note(&intent)?;
                    st.search_query.clear();
                    st.store.items.iter().position(|i| i.id == id)
                });
                iclip_core::security::bump_password_generation_salt();
                if let Some(idx) = new_idx {
                    commit_paste_item_by_index(hwnd, idx, false);
                }
            } else {
                commit_ephemeral_secret_paste(hwnd, &pw_cand.secret_value, pw_cand.ephemeral_toast);
            }
            return;
        }
        let math_res = APP_STATE.with(|c| {
            let b = c.borrow();
            let st = b.as_ref()?;
            if st.store.config.minimal_mode_enabled {
                return None;
            }
            let ctx = st.store.items.iter().find_map(|i| i.text.as_deref());
            evaluate_instant_math(&st.search_query, ctx)
        });
        if let Some(m) = math_res {
            let out = if shift_down {
                m.rmb_uppercase.unwrap_or(m.plain_value)
            } else {
                m.plain_value
            };
            commit_direct_text_paste(hwnd, &out, format!("已键入计算结果 {out}"));
            return;
        }

        let inline_todo_created = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut()?;
            if st.selected_tab != ClipFilterTab::Todo {
                return None;
            }
            let q = st.search_query.trim().to_string();
            if q.is_empty() || q.starts_with('@') {
                return None;
            }
            let filtered = st.store.filtered_indices_ext(
                st.selected_tab,
                st.selected_pin_category,
                &st.search_query,
                st.active_target_app_name.as_deref(),
            );
            if !filtered.is_empty() && !ctrl_down {
                return None;
            }
            let (alias, body) = iclip_core::intelligence::split_alias_and_body(&q);
            let id = st.store.capture_quick_todo(&body, alias.as_deref())?;
            st.search_query.clear();
            st.selected_visible_pos = 0;
            st.scroll_row_offset = 0;
            Some(id)
        });
        if inline_todo_created.is_some() {
            set_toast(hwnd, "✓ 已加入待办清单".to_string());
            return;
        }

        let mut selected_store_idx = None;
        let mut first_quick_action = None;
        let mut mark_todo_done_id: Option<String> = None;
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow().as_ref() {
                let filtered = st.store.filtered_indices_ext(
                    st.selected_tab,
                    st.selected_pin_category,
                    &st.search_query,
                    st.active_target_app_name.as_deref(),
                );
                if let Some(&idx) = filtered.get(st.selected_visible_pos) {
                    selected_store_idx = Some(idx);
                    if ctrl_down && !shift_down && st.store.items[idx].is_pending_todo() {
                        mark_todo_done_id = Some(st.store.items[idx].id.clone());
                    } else if shift_down && !st.store.config.minimal_mode_enabled {
                        let item_snapshot = st.store.items[idx].clone();
                        first_quick_action = item_quick_actions_for_ui(st, &item_snapshot)
                            .into_iter()
                            .next();
                    }
                }
            }
        });
        if let Some(done_id) = mark_todo_done_id {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.mark_todo_completed_silently(&done_id);
                }
            });
        }
        if let (Some(idx), Some(act)) = (selected_store_idx, first_quick_action) {
            commit_quick_action(hwnd, idx, &act);
        } else if let Some(idx) = selected_store_idx {
            commit_paste_item_by_index(hwnd, idx, false);
        }
    }
}

unsafe fn handle_char_input(hwnd: HWND, ch_code: u32) {
    let ctrl_down = (GetKeyState(VK_CONTROL as i32) as u16 & 0x8000) != 0;
    if ctrl_down {
        return;
    }

    let skip = APP_STATE.with(|c| {
        c.borrow()
            .as_ref()
            .map(|s| s.recording_slot.is_some())
            .unwrap_or(true)
    });
    if skip {
        return;
    }

    if ch_code == VK_BACK as u32 {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                if st.editing_alias_item_id.is_some() {
                    st.alias_draft.pop();
                } else if st.view_mode == ActiveViewMode::MainList && !st.show_quick_look {
                    st.search_query.pop();
                    st.selected_visible_pos = 0;
                    st.scroll_row_offset = 0;
                }
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
        return;
    }

    if ch_code >= 0x20 {
        if let Some(ch) = char::from_u32(ch_code) {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    if st.editing_alias_item_id.is_some() {
                        if ch != '\r' && ch != '\n' {
                            st.alias_draft.push(ch);
                        }
                    } else if st.view_mode == ActiveViewMode::MainList && !st.show_quick_look {
                        if ch == ' ' && st.search_query.is_empty() {
                            return;
                        }
                        st.search_query.push(ch);
                        st.selected_visible_pos = 0;
                        st.scroll_row_offset = 0;
                    }
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
    }
}

unsafe fn install_or_update_tray_icon(hwnd: HWND, is_modify: bool) {
    let hk_disp = APP_STATE
        .with(|c| {
            c.borrow()
                .as_ref()
                .map(|s| s.store.config.hotkey_toggle.display_string())
        })
        .unwrap_or_else(|| "Alt + V".to_string());

    let mut nid: NOTIFYICONDATAW = zeroed();
    nid.cbSize = size_of::<NOTIFYICONDATAW>() as u32;
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_TRAYICON;
    let hinst = GetModuleHandleW(null());
    nid.hIcon = load_embedded_app_icon(hinst, SM_CXSMICON);
    let tip = to_wide(&format!(
        "iClip · {} ({hk_disp} 呼出)",
        ClipboardStore::edition_title()
    ));
    let copy_len = tip.len().min(nid.szTip.len());
    nid.szTip[..copy_len].copy_from_slice(&tip[..copy_len]);
    let _ = Shell_NotifyIconW(if is_modify { NIM_MODIFY } else { NIM_ADD }, &nid);
}

unsafe fn remove_tray_icon(hwnd: HWND) {
    let mut nid: NOTIFYICONDATAW = zeroed();
    nid.cbSize = size_of::<NOTIFYICONDATAW>() as u32;
    nid.hWnd = hwnd;
    nid.uID = 1;
    let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
}

unsafe fn show_tray_context_menu(hwnd: HWND) {
    let hmenu = CreatePopupMenu();
    if hmenu.is_null() {
        return;
    }

    let (minimal, always_top, otp_exp, paused, pinned_cnt, pending_todos, queue_active, hk_disp) =
        APP_STATE.with(|c| {
            let b = c.borrow();
            let st = b.as_ref().unwrap();
            (
                st.store.config.minimal_mode_enabled,
                st.store.config.always_on_top,
                st.store.config.auto_expire_otp,
                st.store.is_paused,
                st.store.pinned_count(),
                st.store.pending_todo_count(),
                st.store.queue_mode_active,
                st.store.config.hotkey_toggle.display_string(),
            )
        });
    let autostart = is_autostart_enabled();

    AppendMenuW(
        hmenu,
        MF_STRING | MF_GRAYED,
        0,
        to_wide(&format!(
            "iClip v{} · {}",
            env!("CARGO_PKG_VERSION"),
            ClipboardStore::edition_title()
        ))
        .as_ptr(),
    );
    AppendMenuW(
        hmenu,
        MF_STRING,
        CMD_OPEN_PANEL,
        to_wide(&format!("打开 iClip 面板 ({hk_disp})")).as_ptr(),
    );
    if !is_installed_in_system_dir() {
        AppendMenuW(
            hmenu,
            MF_STRING,
            CMD_INSTALL_TO_SYSTEM,
            to_wide("一键安装至系统并生成开始菜单图标").as_ptr(),
        );
    }
    if !minimal {
        let todo_label = if pending_todos > 0 {
            format!("打开待办清单 ({pending_todos} 项未完成 · Alt+2)")
        } else {
            "打开待办清单 (Alt+2)".to_string()
        };
        AppendMenuW(
            hmenu,
            MF_STRING,
            CMD_OPEN_TODO_LIST,
            to_wide(&todo_label).as_ptr(),
        );
        AppendMenuW(
            hmenu,
            MF_STRING,
            CMD_PIN_TODO_BOARD,
            to_wide("钉住待办悬浮板 (始终在前)").as_ptr(),
        );
    }
    AppendMenuW(
        hmenu,
        MF_STRING,
        CMD_OPEN_SETTINGS,
        to_wide("偏好设置与液态玻璃调节 (Ctrl+,)").as_ptr(),
    );
    AppendMenuW(hmenu, MF_SEPARATOR, 0, null());

    AppendMenuW(
        hmenu,
        MF_STRING | if always_top { MF_CHECKED } else { 0 },
        CMD_TOGGLE_PIN_WINDOW,
        to_wide("窗口始终在前 (Ctrl+P)").as_ptr(),
    );
    AppendMenuW(
        hmenu,
        MF_STRING | if minimal { MF_CHECKED } else { 0 },
        CMD_TOGGLE_MINIMAL,
        to_wide("极简纯净模式 (Ctrl+E)").as_ptr(),
    );
    AppendMenuW(
        hmenu,
        MF_STRING | if queue_active { MF_CHECKED } else { 0 },
        CMD_TOGGLE_QUEUE_MODE,
        to_wide("FIFO 顺序复制连填队列").as_ptr(),
    );
    AppendMenuW(
        hmenu,
        MF_STRING | if otp_exp { MF_CHECKED } else { 0 },
        CMD_TOGGLE_OTP_EXPIRE,
        to_wide("验证码粘贴 30 秒无痕销毁").as_ptr(),
    );
    AppendMenuW(
        hmenu,
        MF_STRING | if autostart { MF_CHECKED } else { 0 },
        CMD_TOGGLE_AUTOSTART,
        to_wide("开机自动启动").as_ptr(),
    );

    AppendMenuW(hmenu, MF_SEPARATOR, 0, null());
    AppendMenuW(
        hmenu,
        MF_STRING,
        CMD_EXPORT_ARCHIVE,
        to_wide(&format!("导出置顶收藏资产 (.iclip，共 {pinned_cnt} 条)...")).as_ptr(),
    );
    AppendMenuW(
        hmenu,
        MF_STRING,
        CMD_IMPORT_ARCHIVE,
        to_wide("导入合并收藏资产 (.iclip · 与 Mac 互通)...").as_ptr(),
    );

    AppendMenuW(hmenu, MF_SEPARATOR, 0, null());
    if paused {
        AppendMenuW(
            hmenu,
            MF_STRING,
            CMD_TOGGLE_PAUSE,
            to_wide("立即恢复剪贴板记录").as_ptr(),
        );
    } else {
        AppendMenuW(
            hmenu,
            MF_STRING,
            CMD_PAUSE_15M,
            to_wide("无痕暂停 15 分钟（自动恢复）").as_ptr(),
        );
        AppendMenuW(
            hmenu,
            MF_STRING,
            CMD_PAUSE_60M,
            to_wide("无痕暂停 60 分钟（自动恢复）").as_ptr(),
        );
        AppendMenuW(
            hmenu,
            MF_STRING,
            CMD_TOGGLE_PAUSE,
            to_wide("持续暂停剪贴板记录").as_ptr(),
        );
    }
    AppendMenuW(
        hmenu,
        MF_STRING,
        CMD_CLEAR_UNPINNED,
        to_wide("清空未固定历史").as_ptr(),
    );
    AppendMenuW(hmenu, MF_SEPARATOR, 0, null());
    AppendMenuW(
        hmenu,
        MF_STRING,
        CMD_CHECK_UPDATES,
        to_wide("检查软件更新 (OTA)...").as_ptr(),
    );
    AppendMenuW(
        hmenu,
        MF_STRING,
        CMD_QUIT_APP,
        to_wide("退出 iClip").as_ptr(),
    );

    let mut pt = POINT { x: 0, y: 0 };
    let _ = GetCursorPos(&mut pt);
    let _ = SetForegroundWindow(hwnd);
    let _ = TrackPopupMenu(
        hmenu,
        TPM_BOTTOMALIGN | TPM_LEFTALIGN,
        pt.x,
        pt.y,
        0,
        hwnd,
        null(),
    );
    let _ = DestroyMenu(hmenu);
}

unsafe fn handle_menu_command(hwnd: HWND, cmd: usize) {
    match cmd {
        CMD_OPEN_PANEL => show_panel_near_cursor(hwnd),
        CMD_OPEN_TODO_LIST => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.config.minimal_mode_enabled = false;
                    st.view_mode = ActiveViewMode::MainList;
                    st.selected_tab = ClipFilterTab::Todo;
                    st.seg_pill_target_ratio = 1.0;
                    st.seg_pill_ratio = 1.0;
                    st.selected_visible_pos = 0;
                    st.scroll_row_offset = 0;
                }
            });
            show_panel_near_cursor(hwnd);
        }
        CMD_PIN_TODO_BOARD => {
            let need_pin = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let Some(st) = b.as_mut() else { return false };
                st.store.config.minimal_mode_enabled = false;
                st.view_mode = ActiveViewMode::MainList;
                st.selected_tab = ClipFilterTab::Todo;
                st.seg_pill_target_ratio = 1.0;
                st.seg_pill_ratio = 1.0;
                st.selected_visible_pos = 0;
                st.scroll_row_offset = 0;
                !st.store.config.always_on_top
            });
            show_panel_near_cursor(hwnd);
            if need_pin {
                toggle_always_on_top(hwnd);
            }
            set_toast(hwnd, "已钉住待办悬浮板 (Ctrl+P 可取消置顶)".to_string());
        }
        CMD_OPEN_SETTINGS => {
            show_panel_near_cursor(hwnd);
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.view_mode = ActiveViewMode::Settings;
                    st.autostart_cached = is_autostart_enabled();
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        CMD_CHECK_UPDATES => {
            show_panel_near_cursor(hwnd);
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.view_mode = ActiveViewMode::Settings;
                    st.settings_scroll_px = 0;
                    st.autostart_cached = is_autostart_enabled();
                }
            });
            trigger_ota_check(hwnd, false);
        }
        CMD_TOGGLE_PIN_WINDOW => {
            show_panel_near_cursor(hwnd);
            toggle_always_on_top(hwnd);
        }
        CMD_TOGGLE_MINIMAL => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.minimal_mode_enabled);
        }
        CMD_TOGGLE_QUEUE_MODE => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.queue_mode_active = !st.store.queue_mode_active;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        CMD_TOGGLE_OTP_EXPIRE => {
            toggle_config_bool(hwnd, |cfg| &mut cfg.auto_expire_otp);
        }
        CMD_PAUSE_15M => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.pause_for_minutes(Some(15), now_unix_secs());
                }
            });
            set_toast(hwnd, "已开启 15 分钟无痕暂停（到点自动恢复）".to_string());
        }
        CMD_PAUSE_60M => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.pause_for_minutes(Some(60), now_unix_secs());
                }
            });
            set_toast(hwnd, "已开启 60 分钟无痕暂停（到点自动恢复）".to_string());
        }
        CMD_TOGGLE_PAUSE => {
            let resumed = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let Some(st) = b.as_mut() else { return false };
                if st.store.is_paused {
                    st.store.resume_capture();
                    true
                } else {
                    st.store.pause_for_minutes(None, now_unix_secs());
                    false
                }
            });
            set_toast(
                hwnd,
                if resumed {
                    "已恢复记录剪贴板".to_string()
                } else {
                    "已持续暂停记录剪贴板".to_string()
                },
            );
        }
        CMD_TOGGLE_AUTOSTART => {
            let next = !is_autostart_enabled();
            set_autostart_enabled(next);
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.autostart_cached = next;
                }
            });
        }
        CMD_INSTALL_TO_SYSTEM => install_self_to_system_and_shortcuts(hwnd),
        CMD_EXPORT_ARCHIVE => export_archive_via_dialog(hwnd),
        CMD_IMPORT_ARCHIVE => import_archive_via_dialog(hwnd),
        CMD_CLEAR_UNPINNED => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.clear_unpinned();
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        CMD_QUIT_APP => {
            DestroyWindow(hwnd);
        }
        _ => {}
    }
}

unsafe fn export_archive_via_dialog(hwnd: HWND) {
    let pinned = APP_STATE.with(|c| {
        c.borrow()
            .as_ref()
            .map(|s| s.store.pinned_count())
            .unwrap_or(0)
    });
    if pinned == 0 {
        show_panel_near_cursor(hwnd);
        set_toast(hwnd, "当前暂无已固定的收藏记录可导出".to_string());
        return;
    }

    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            st.suppress_deactivate_hide = true;
        }
    });

    let mut file_buf = vec![0u16; 260];
    let default_name = to_wide("iClip-收藏资产备份.iclip");
    file_buf[..default_name.len()].copy_from_slice(&default_name);
    let filter: Vec<u16> = "iClip 归档包 (*.iclip)\0*.iclip\0所有文件 (*.*)\0*.*\0\0"
        .encode_utf16()
        .collect();
    let def_ext = to_wide("iclip");

    let mut ofn: OPENFILENAMEW = zeroed();
    ofn.lStructSize = size_of::<OPENFILENAMEW>() as u32;
    ofn.hwndOwner = hwnd;
    ofn.lpstrFilter = filter.as_ptr();
    ofn.lpstrFile = file_buf.as_mut_ptr();
    ofn.nMaxFile = file_buf.len() as u32;
    ofn.lpstrDefExt = def_ext.as_ptr();
    ofn.Flags = OFN_EXPLORER | OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;

    let ok = GetSaveFileNameW(&mut ofn) != FALSE;
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            st.suppress_deactivate_hide = false;
        }
    });

    if ok {
        let dest = PathBuf::from(from_wide_slice(&file_buf));
        let (res, sensitive_pinned) = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut().unwrap();
            let raw_q = st.search_query.trim().to_string();
            let pw_opt = raw_q
                .strip_prefix("@口令 ")
                .or_else(|| raw_q.strip_prefix("@密码 "))
                .or_else(|| raw_q.strip_prefix("pw:"))
                .map(|s| s.trim().to_string())
                .or_else(|| {
                    if st.view_mode == ActiveViewMode::Settings && !raw_q.is_empty() {
                        Some(raw_q)
                    } else {
                        None
                    }
                })
                .filter(|s| !s.is_empty());
            if pw_opt.is_some() {
                st.search_query.clear();
            }
            let r = st
                .store
                .export_archive_to_file_with_passphrase(&dest, pw_opt.as_deref());
            (r, st.store.pinned_sensitive_count())
        });
        show_panel_near_cursor(hwnd);
        match res {
            Ok((n, true)) => set_toast(
                hwnd,
                format!("已口令加密导出 {n} 条收藏资产（与 Mac 互通）"),
            ),
            Ok((n, false)) => {
                if sensitive_pinned > 0 {
                    set_toast(
                        hwnd,
                        format!("已导出 {n} 条收藏（提示：搜索框输入 @口令 xxx 再导出可加密）"),
                    );
                } else {
                    set_toast(hwnd, format!("已成功导出 {n} 条收藏资产"));
                }
            }
            Err(e) => set_toast(hwnd, e.message()),
        }
    }
}

unsafe fn import_archive_via_dialog(hwnd: HWND) {
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            st.suppress_deactivate_hide = true;
        }
    });

    let mut file_buf = vec![0u16; 260];
    let filter: Vec<u16> =
        "支持导入的收藏与常用语 (*.iclip;*.json;*.md;*.markdown;*.csv;*.tsv)\0*.iclip;*.json;*.md;*.markdown;*.alfredsnippets;*.csv;*.tsv\0所有文件 (*.*)\0*.*\0\0"
            .encode_utf16()
            .collect();

    let mut ofn: OPENFILENAMEW = zeroed();
    ofn.lStructSize = size_of::<OPENFILENAMEW>() as u32;
    ofn.hwndOwner = hwnd;
    ofn.lpstrFilter = filter.as_ptr();
    ofn.lpstrFile = file_buf.as_mut_ptr();
    ofn.nMaxFile = file_buf.len() as u32;
    ofn.Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;

    let ok = GetOpenFileNameW(&mut ofn) != FALSE;
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            st.suppress_deactivate_hide = false;
        }
    });

    if ok {
        let src = PathBuf::from(from_wide_slice(&file_buf));
        let clip_pw = read_unicode_text_from_clipboard(hwnd);
        let res = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut().unwrap();
            let q_pw = Some(st.search_query.trim().to_string()).filter(|s| !s.is_empty());
            let first_try = st
                .store
                .import_archive_from_file_with_passphrase(&src, q_pw.as_deref());
            if first_try
                == Err(iclip_core::archive::ArchiveBackupError::PassphraseRequiredOrIncorrect)
            {
                if let Some(cp) = clip_pw.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                    return st
                        .store
                        .import_archive_from_file_with_passphrase(&src, Some(cp));
                }
            }
            first_try
        });
        show_panel_near_cursor(hwnd);
        match res {
            Ok(s) => set_toast(
                hwnd,
                format!(
                    "已从{}迁入 {} 条，合并更新 {} 条",
                    s.source_format_label, s.imported_new_count, s.updated_existing_count
                ),
            ),
            Err(iclip_core::archive::ArchiveBackupError::PassphraseRequiredOrIncorrect) => {
                set_toast(
                    hwnd,
                    "加密归档：请先复制口令或在搜索框输入口令后再点导入".to_string(),
                )
            }
            Err(e) => set_toast(hwnd, e.message()),
        }
    }
}

unsafe fn is_autostart_enabled() -> bool {
    let subkey = to_wide("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
    let val_name = to_wide("iClip");
    let mut hkey = null_mut();
    if RegOpenKeyExW(HKEY_CURRENT_USER, subkey.as_ptr(), 0, KEY_READ, &mut hkey) != 0 {
        return false;
    }
    let exists = RegQueryValueExW(
        hkey,
        val_name.as_ptr(),
        null_mut(),
        null_mut(),
        null_mut(),
        null_mut(),
    ) == 0;
    let _ = RegCloseKey(hkey);
    exists
}

unsafe fn set_autostart_enabled(enable: bool) {
    let subkey = to_wide("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
    let val_name = to_wide("iClip");
    let mut hkey = null_mut();
    if RegOpenKeyExW(
        HKEY_CURRENT_USER,
        subkey.as_ptr(),
        0,
        KEY_SET_VALUE,
        &mut hkey,
    ) != 0
    {
        return;
    }
    if enable {
        if let Ok(exe_path) = std::env::current_exe() {
            let clean_exe: String = exe_path
                .display()
                .to_string()
                .chars()
                .filter(|c| !c.is_control() && *c != '"')
                .collect();
            let quoted = format!("\"{clean_exe}\"");
            let wide = to_wide(&quoted);
            let _ = RegSetValueExW(
                hkey,
                val_name.as_ptr(),
                0,
                REG_SZ,
                wide.as_ptr() as *const u8,
                (wide.len() * 2) as u32,
            );
        }
    } else {
        let _ = RegDeleteValueW(hkey, val_name.as_ptr());
    }
    let _ = RegCloseKey(hkey);
}

unsafe fn install_self_to_system_and_shortcuts(hwnd: HWND) {
    let Ok(cur_exe) = std::env::current_exe() else {
        set_toast(hwnd, "无法读取当前程序路径".to_string());
        return;
    };
    let Some(target_exe) = preferred_windows_install_exe() else {
        set_toast(hwnd, "无法定位系统应用目录".to_string());
        return;
    };
    if let Some(parent) = target_exe.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            set_toast(hwnd, format!("创建安装目录失败：{e}"));
            return;
        }
    }
    if let Ok(meta) = std::fs::symlink_metadata(&target_exe) {
        if meta.file_type().is_symlink() {
            set_toast(hwnd, "目标路径存在异常符号链接，已拒绝覆盖".to_string());
            return;
        }
    }
    if !cur_exe
        .to_string_lossy()
        .eq_ignore_ascii_case(&target_exe.to_string_lossy())
    {
        if let Err(e) = std::fs::copy(&cur_exe, &target_exe) {
            set_toast(hwnd, format!("复制程序文件失败：{e}"));
            return;
        }
    }
    let _ = std::fs::remove_file(format!("{}:Zone.Identifier", target_exe.display()));

    // 若已开启开机自启，同步把注册表启动路径修正为正式目录
    if is_autostart_enabled() {
        let subkey = to_wide("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
        let val_name = to_wide("iClip");
        let mut hkey = null_mut();
        if RegOpenKeyExW(
            HKEY_CURRENT_USER,
            subkey.as_ptr(),
            0,
            KEY_SET_VALUE,
            &mut hkey,
        ) == 0
        {
            let clean_target: String = target_exe
                .display()
                .to_string()
                .chars()
                .filter(|c| !c.is_control() && *c != '"')
                .collect();
            let quoted = format!("\"{clean_target}\"");
            let wide = to_wide(&quoted);
            let _ = RegSetValueExW(
                hkey,
                val_name.as_ptr(),
                0,
                REG_SZ,
                wide.as_ptr() as *const u8,
                (wide.len() * 2) as u32,
            );
            let _ = RegCloseKey(hkey);
        }
    }

    // 静默生成开始菜单快捷方式（绑定 %SystemRoot%\System32 绝对路径阻断 CWE-426 同目录劫持）
    let target_escaped = target_exe.display().to_string().replace('\'', "''");
    let work_dir = target_exe
        .parent()
        .map(|p| p.display().to_string().replace('\'', "''"))
        .unwrap_or_default();
    let ps_cmd = format!(
        "$s=(New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'iClip.lnk'));$s.TargetPath='{target_escaped}';$s.WorkingDirectory='{work_dir}';$s.IconLocation='{target_escaped},0';$s.Save()"
    );
    let sys_root = std::env::var_os("SystemRoot")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    let ps_bin = sys_root
        .join("System32")
        .join("WindowsPowerShell")
        .join("v1.0")
        .join("powershell.exe");
    let _ = std::process::Command::new(&ps_bin)
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-Command",
            &ps_cmd,
        ])
        .spawn();

    set_toast(hwnd, "已安装至本机并创建开始菜单图标".to_string());
}

unsafe fn trigger_ota_check(hwnd: HWND, silent: bool) {
    let maybe_shared: Option<Arc<Mutex<OtaState>>> = APP_STATE.with(|c| {
        let mut b = c.borrow_mut();
        let st = b.as_mut()?;
        if st.ota_state.is_busy() {
            return None;
        }
        if !silent {
            st.ota_state = OtaState::Checking;
            if let Ok(mut g) = st.ota_shared.lock() {
                *g = OtaState::Checking;
            }
        }
        Some(Arc::clone(&st.ota_shared))
    });
    let Some(shared) = maybe_shared else {
        return;
    };
    if !silent {
        let _ = InvalidateRect(hwnd, null(), FALSE);
    }

    let hwnd_raw = hwnd as isize;
    let current_ver = env!("CARGO_PKG_VERSION").to_string();
    let edition = ClipboardStore::edition_key().to_string();
    std::thread::spawn(move || {
        let next =
            match iclip_core::updater::win_runtime::check_latest_release(&current_ver, &edition) {
                Ok(Some(info)) => OtaState::Available(info),
                Ok(None) => OtaState::UpToDate {
                    latest: current_ver,
                },
                Err(err) => {
                    if silent {
                        OtaState::Idle
                    } else {
                        OtaState::Failed(err)
                    }
                }
            };
        if let Ok(mut g) = shared.lock() {
            *g = next;
        }
        let target = hwnd_raw as HWND;
        if !target.is_null() {
            let _ = PostMessageW(target, WM_APP_OTA_STATE, if silent { 1 } else { 0 }, 0);
        }
    });
}

unsafe fn trigger_ota_download_and_install(hwnd: HWND) {
    let ctx: Option<(OtaReleaseInfo, Arc<Mutex<OtaState>>, Arc<AtomicBool>)> =
        APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut()?;
            let info = match &st.ota_state {
                OtaState::Available(info) => info.clone(),
                _ => return None,
            };
            st.ota_cancel.store(false, Ordering::SeqCst);
            let init = OtaState::Downloading {
                info: info.clone(),
                progress_pct: 0,
                downloaded_kb: 0,
                total_kb: 0,
            };
            st.ota_state = init.clone();
            if let Ok(mut g) = st.ota_shared.lock() {
                *g = init;
            }
            Some((info, Arc::clone(&st.ota_shared), Arc::clone(&st.ota_cancel)))
        });
    let Some((info, shared, cancel)) = ctx else {
        return;
    };
    let _ = InvalidateRect(hwnd, null(), FALSE);

    let hwnd_raw = hwnd as isize;
    std::thread::spawn(move || {
        let mut last_pct: u8 = 255;
        let dl_res = iclip_core::updater::win_runtime::download_and_verify_release(
            &info,
            &cancel,
            |downloaded, total| {
                let pct = if total > 0 {
                    ((downloaded.saturating_mul(100)) / total).min(100) as u8
                } else {
                    0
                };
                if pct != last_pct && (pct == 0 || pct == 100 || pct.abs_diff(last_pct) >= 3) {
                    last_pct = pct;
                    if let Ok(mut g) = shared.lock() {
                        *g = OtaState::Downloading {
                            info: info.clone(),
                            progress_pct: pct,
                            downloaded_kb: downloaded / 1024,
                            total_kb: total / 1024,
                        };
                    }
                    let target = hwnd_raw as HWND;
                    if !target.is_null() {
                        let _ = PostMessageW(target, WM_APP_OTA_STATE, 1, 0);
                    }
                }
            },
        );

        let zip_bytes = match dl_res {
            Ok(bytes) => bytes,
            Err(err) => {
                if let Ok(mut g) = shared.lock() {
                    if cancel.load(Ordering::Relaxed) {
                        *g = OtaState::Available(info);
                    } else {
                        *g = OtaState::Failed(err);
                    }
                }
                let target = hwnd_raw as HWND;
                if !target.is_null() {
                    let _ = PostMessageW(target, WM_APP_OTA_STATE, 0, 0);
                }
                return;
            }
        };

        if let Ok(mut g) = shared.lock() {
            *g = OtaState::Installing(info.clone());
        }
        let target = hwnd_raw as HWND;
        if !target.is_null() {
            let _ = PostMessageW(target, WM_APP_OTA_STATE, 1, 0);
        }

        match iclip_core::updater::win_runtime::apply_zip_and_restart(&zip_bytes) {
            Ok(_) => {
                if !target.is_null() {
                    let _ = PostMessageW(target, WM_APP_OTA_RESTART, 0, 0);
                }
            }
            Err(err) => {
                if let Ok(mut g) = shared.lock() {
                    *g = OtaState::Failed(err);
                }
                if !target.is_null() {
                    let _ = PostMessageW(target, WM_APP_OTA_STATE, 0, 0);
                }
            }
        }
    });
}

unsafe fn cancel_ota_download(hwnd: HWND) {
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            st.ota_cancel.store(true, Ordering::SeqCst);
            if let OtaState::Downloading { info, .. } = &st.ota_state {
                let back = OtaState::Available(info.clone());
                st.ota_state = back.clone();
                if let Ok(mut g) = st.ota_shared.lock() {
                    *g = back;
                }
            }
        }
    });
    set_toast(hwnd, "已取消更新下载".to_string());
}
