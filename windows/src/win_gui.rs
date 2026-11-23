#![cfg(target_os = "windows")]

use iclip_core::canvas_ui::{
    build_display_rows, grid_move_selection, image_grid_row_height, standard_card_height, Color4,
    DisplayRow, GlassPalette, GridMoveDir, PixelCanvas,
};
use iclip_core::engines::{
    analyze_text_actions, clean_tracking_url, compress_png_to_white_bg_jpeg,
    render_dynamic_template, render_mockup_frame_png,
};
use iclip_core::hotkey::{
    static_hotkey_conflict_reason, DoubleTapOutcome, WinHotKeyShortcut, WinHotKeySlot,
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
use image::{codecs::png::PngEncoder, imageops::FilterType, ColorType, ImageEncoder};
use std::cell::RefCell;
use std::ffi::OsString;
use std::mem::{size_of, zeroed};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicIsize, Ordering};
use std::time::Instant;

use windows_sys::Win32::Foundation::{
    CloseHandle, FALSE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM,
};
use windows_sys::Win32::Graphics::Dwm::{DwmExtendFrameIntoClientArea, DwmSetWindowAttribute};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, BitBlt, CreateCompatibleDC, CreateDIBSection, CreateFontW, DeleteDC, DeleteObject,
    DrawTextW, EndPaint, GdiFlush, GetDC, GetMonitorInfoW, InvalidateRect, MonitorFromPoint,
    ReleaseDC, SelectObject, SetBkMode, SetTextColor, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
    CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DIB_RGB_COLORS, DT_CENTER,
    DT_END_ELLIPSIS, DT_LEFT, DT_NOPREFIX, DT_RIGHT, DT_SINGLELINE, DT_VCENTER, DT_WORDBREAK,
    FW_BOLD, FW_MEDIUM, FW_NORMAL, FW_SEMIBOLD, HDC, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    OUT_DEFAULT_PRECIS, PAINTSTRUCT, SRCCOPY, TRANSPARENT,
};
use windows_sys::Win32::System::DataExchange::{
    AddClipboardFormatListener, CloseClipboard, EmptyClipboard, GetClipboardData,
    GetClipboardOwner, IsClipboardFormatAvailable, OpenClipboard, RegisterClipboardFormatW,
    RemoveClipboardFormatListener, SetClipboardData,
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

// 标准面板逻辑尺寸（1:1 对齐 macOS v2.4 面板 420×560）
const PANEL_BASE_W: i32 = 420;
const PANEL_BASE_H: i32 = 560;

const WM_TRAYICON: u32 = WM_USER + 101;
const WM_APP_DOUBLETAP: u32 = WM_USER + 102;
const WM_CLIPBOARDUPDATE_MSG: u32 = 0x031D;

const HOTKEY_ID_TOGGLE: i32 = 1001;
const HOTKEY_ID_QUEUE_POP: i32 = 1002;
const HOTKEY_ID_COPY_APPEND: i32 = 1003;
const HOTKEY_ID_PROBE: i32 = 1099;

const TIMER_ID_OTP_SWEEP: usize = 2001;
const TIMER_ID_TOAST_CLEAR: usize = 2002;
const TIMER_ID_COPY_FLASH_CLEAR: usize = 2003;
const TIMER_ID_DEFERRED_APPEND: usize = 2004;

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

#[derive(Clone)]
struct HitRegion {
    rect: RECT,
    interactive_cursor: bool,
    action: HitAction,
}

#[derive(Clone)]
enum HitAction {
    ClearSearch,
    ToggleMinimalMode,
    ToggleAlwaysOnTop,
    ToggleSettingsView,
    SelectTab(ClipFilterTab),
    SelectPinCategory(Option<PinCategory>),
    CommitMathResult(String),
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
    DeleteItem(String),
    UndoDelete,
    CloseOverlay,
    ToggleQuickLookDiffMode,
    SaveAliasEdit,
    // 内嵌设置页交互热区
    StartRecordHotkey(WinHotKeySlot),
    ResetHotkeyDefault(WinHotKeySlot),
    ToggleAutoPaste,
    ToggleCopyAppend,
    ToggleDoubleCopySpark,
    ToggleStripRichFormat,
    ToggleAutoCleanUrl,
    ToggleAutoExpireOtp,
    ToggleQueueMode,
    ToggleQueueAutoTab,
    ToggleAutostart,
    AdjustBlurConcentration {
        track_left: i32,
        track_width: i32,
    },
    SelectMaxHistory(usize),
    ExportArchive,
    ImportArchive,
    ClearUnpinnedHistory,
    TogglePauseCapture,
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
    previous_foreground: HWND,
    active_target_app_name: Option<String>,
    ignore_next_clipboard_seq: bool,
    pending_append_capture: bool,
    last_copy_hash: String,
    last_copy_at_ms: u64,
    selected_tab: ClipFilterTab,
    selected_pin_category: Option<PinCategory>,
    search_query: String,
    selected_visible_pos: usize,
    scroll_row_offset: usize,
    settings_scroll_px: i32,
    settings_max_scroll_px: i32,
    hovered_visible_pos: Option<usize>,
    copied_flash_item_id: Option<String>,
    // 快捷键录制与冲突提示状态
    recording_slot: Option<WinHotKeySlot>,
    hotkey_conflict_error: Option<String>,
    hotkey_recording_hint: Option<String>,
    // 原位速览 / Diff 与内联备注编辑浮层
    show_quick_look: bool,
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
    suppress_deactivate_hide: bool,
    autostart_cached: bool,
    kbd_hook: HHOOK,
    mouse_hook: HHOOK,
    boot_instant: Instant,
    double_tap_machine: WinModifierDoubleTapMachine,
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

pub fn run_windows_app() -> i32 {
    unsafe {
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
            hIcon: LoadIconW(null_mut(), IDI_APPLICATION),
            hCursor: LoadCursorW(null_mut(), IDC_ARROW),
            hbrBackground: null_mut(),
            lpszMenuName: null(),
            lpszClassName: class_name.as_ptr(),
            hIconSm: LoadIconW(null_mut(), IDI_APPLICATION),
        };
        RegisterClassExW(&wc);

        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
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

        let store = ClipboardStore::new(ClipboardStore::default_app_data_dir());
        let appearance = store.config.glass_appearance;
        apply_dwm_glass_style(hwnd, appearance);

        let cf_html = RegisterClipboardFormatW(to_wide("HTML Format").as_ptr());
        let cf_excl = RegisterClipboardFormatW(
            to_wide("ExcludeClipboardContentFromMonitorProcessing").as_ptr(),
        );
        let cf_ignore = RegisterClipboardFormatW(to_wide("Clipboard Viewer Ignore").as_ptr());
        let autostart = is_autostart_enabled();

        APP_STATE.with(|cell| {
            *cell.borrow_mut() = Some(WinAppState {
                store,
                visible: false,
                view_mode: ActiveViewMode::MainList,
                previous_foreground: null_mut(),
                active_target_app_name: None,
                ignore_next_clipboard_seq: false,
                pending_append_capture: false,
                last_copy_hash: String::new(),
                last_copy_at_ms: 0,
                selected_tab: ClipFilterTab::All,
                selected_pin_category: None,
                search_query: String::new(),
                selected_visible_pos: 0,
                scroll_row_offset: 0,
                settings_scroll_px: 0,
                settings_max_scroll_px: 0,
                hovered_visible_pos: None,
                copied_flash_item_id: None,
                recording_slot: None,
                hotkey_conflict_error: None,
                hotkey_recording_hint: None,
                show_quick_look: false,
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
                suppress_deactivate_hide: false,
                autostart_cached: autostart,
                kbd_hook: null_mut(),
                mouse_hook: null_mut(),
                boot_instant: Instant::now(),
                double_tap_machine: WinModifierDoubleTapMachine::default(),
            });
        });

        let _ = AddClipboardFormatListener(hwnd);
        reload_global_hotkeys_and_hooks(hwnd);
        SetTimer(hwnd, TIMER_ID_OTP_SWEEP, 5_000, None);
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
        let _ = RemoveClipboardFormatListener(hwnd);
        MAIN_HWND_RAW.store(0, Ordering::SeqCst);
        0
    }
}

/// 在真实 Windows 系统（如 CI / 本地）上执行完整的 Win32 窗口、32-bit DIB 抗锯齿渲染（主面板 + 设置页 + Diff 速览）与剪贴板双协议自检
pub fn run_windows_self_test() -> Result<(), String> {
    unsafe {
        let t0 = Instant::now();
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let hinstance = GetModuleHandleW(null());
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
        apply_dwm_glass_style(hwnd, GlassAppearance::Tinted);

        if AddClipboardFormatListener(hwnd) == FALSE {
            DestroyWindow(hwnd);
            return Err("AddClipboardFormatListener failed".to_string());
        }

        let tmp_dir = std::env::temp_dir().join(format!("iclip-selftest-{}", now_unix_secs()));
        let mut store = ClipboardStore::new(tmp_dir.clone());
        let fin_id = store.insert_or_promote(ClipItem::new_text(
            "¥128,560.50".to_string(),
            Some("EXCEL".to_string()),
        ));
        store.set_custom_alias(&fin_id, "Q4 对公结算尾款");
        store.insert_or_promote(ClipItem::new_text(
            "https://github.com/fanaruto/iClip/releases/tag/v2.4.0".to_string(),
            Some("chrome".to_string()),
        ));
        store.insert_or_promote(ClipItem::new_text(
            "| 指标 | 数值 |\n| --- | --- |\n| 体积 | 480KB |".to_string(),
            Some("Code".to_string()),
        ));

        let cf_html = RegisterClipboardFormatW(to_wide("HTML Format").as_ptr());
        let mut state = WinAppState {
            store,
            visible: true,
            view_mode: ActiveViewMode::MainList,
            previous_foreground: null_mut(),
            active_target_app_name: Some("EXCEL".to_string()),
            ignore_next_clipboard_seq: false,
            pending_append_capture: false,
            last_copy_hash: String::new(),
            last_copy_at_ms: 0,
            selected_tab: ClipFilterTab::All,
            selected_pin_category: None,
            search_query: "* 13%".to_string(),
            selected_visible_pos: 0,
            scroll_row_offset: 0,
            settings_scroll_px: 0,
            settings_max_scroll_px: 0,
            hovered_visible_pos: Some(1),
            copied_flash_item_id: None,
            recording_slot: None,
            hotkey_conflict_error: Some(
                "「Ctrl + C」与系统「复制 (Ctrl+C)」冲突，禁止设定".to_string(),
            ),
            hotkey_recording_hint: None,
            show_quick_look: false,
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
            suppress_deactivate_hide: true,
            autostart_cached: false,
            kbd_hook: null_mut(),
            mouse_hook: null_mut(),
            boot_instant: Instant::now(),
            double_tap_machine: WinModifierDoubleTapMachine::default(),
        };

        let screen_dc = GetDC(hwnd);
        // 1) 校验主面板 + 即时速算横幅 + 链接徽标帧渲染
        let main_rgba =
            render_to_dib_and_capture(screen_dc, PANEL_BASE_W, PANEL_BASE_H, 1.0, &mut state)?;
        let main_hits = state.hit_regions.len();
        if main_hits < 10 {
            ReleaseDC(hwnd, screen_dc);
            let _ = RemoveClipboardFormatListener(hwnd);
            DestroyWindow(hwnd);
            let _ = std::fs::remove_dir_all(&tmp_dir);
            return Err(format!(
                "Expected main panel hit regions >= 10, got {main_hits}"
            ));
        }

        // 2) 校验内嵌设置页（含快捷键录制槽位、冲突硬拦截红字与全套开关）帧渲染
        state.search_query.clear();
        state.view_mode = ActiveViewMode::Settings;
        let _settings_rgba =
            render_to_dib_and_capture(screen_dc, PANEL_BASE_W, PANEL_BASE_H, 1.0, &mut state)?;
        let settings_hits = state.hit_regions.len();
        if settings_hits < 12 {
            ReleaseDC(hwnd, screen_dc);
            let _ = RemoveClipboardFormatListener(hwnd);
            DestroyWindow(hwnd);
            let _ = std::fs::remove_dir_all(&tmp_dir);
            return Err(format!(
                "Expected settings hit regions >= 12, got {settings_hits}"
            ));
        }

        // 3) 校验原位速览 + Diff 浮层渲染
        state.view_mode = ActiveViewMode::MainList;
        state.show_quick_look = true;
        state.quick_look_diff_mode = true;
        let _diff_rgba =
            render_to_dib_and_capture(screen_dc, PANEL_BASE_W, PANEL_BASE_H, 1.0, &mut state)?;
        ReleaseDC(hwnd, screen_dc);

        if main_rgba.iter().all(|&b| b == 0) {
            let _ = RemoveClipboardFormatListener(hwnd);
            DestroyWindow(hwnd);
            let _ = std::fs::remove_dir_all(&tmp_dir);
            return Err("Rendered DIB pixels were unexpectedly empty".to_string());
        }

        // 4) 验证真实 Win32 剪贴板写入与回读（UTF-16 文本 + CF_HTML 双协议）
        let test_marker = "iClip-Win32-Unified-v2.4-测试通过";
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

unsafe fn render_to_dib_and_capture(
    ref_dc: HDC,
    w: i32,
    h: i32,
    scale: f32,
    st: &mut WinAppState,
) -> Result<Vec<u8>, String> {
    let mem_dc = CreateCompatibleDC(ref_dc);
    let mut bmi: BITMAPINFO = zeroed();
    bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // Top-Down 32-bit DIB
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

    render_panel_frame_dib(mem_dc, dib_slice, w, h, scale, st);

    let mut rgba = vec![0u8; pixel_count * 4];
    for (i, &px) in dib_slice.iter().enumerate() {
        rgba[i * 4] = ((px >> 16) & 0xFF) as u8;
        rgba[i * 4 + 1] = ((px >> 8) & 0xFF) as u8;
        rgba[i * 4 + 2] = (px & 0xFF) as u8;
        rgba[i * 4 + 3] = ((px >> 24) & 0xFF) as u8;
    }

    SelectObject(mem_dc, old_bmp);
    DeleteObject(hbmp);
    DeleteDC(mem_dc);
    Ok(rgba)
}

unsafe fn apply_dwm_glass_style(hwnd: HWND, appearance: GlassAppearance) {
    let dark: i32 = 1;
    let _ = DwmSetWindowAttribute(
        hwnd,
        DWMWA_USE_IMMERSIVE_DARK_MODE_ATTR,
        &dark as *const _ as *const _,
        size_of::<i32>() as u32,
    );
    let corner: u32 = DWMWCP_ROUND_VAL;
    let _ = DwmSetWindowAttribute(
        hwnd,
        DWMWA_WINDOW_CORNER_PREFERENCE_ATTR,
        &corner as *const _ as *const _,
        size_of::<u32>() as u32,
    );
    let backdrop: u32 = match appearance {
        GlassAppearance::Clear => DWMSBT_TRANSIENTWINDOW_VAL,
        GlassAppearance::Tinted => DWMSBT_MAINWINDOW_VAL,
        GlassAppearance::Solid => DWMSBT_NONE_VAL,
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

unsafe fn get_dpi_scale(hwnd: HWND) -> f32 {
    let dpi = GetDpiForWindow(hwnd);
    if dpi == 0 {
        1.0
    } else {
        (dpi as f32 / 96.0).clamp(1.0, 3.0)
    }
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

    let (hk_toggle, hk_queue, append_on, recording) = APP_STATE.with(|c| {
        let b = c.borrow();
        let st = b.as_ref().unwrap();
        (
            st.store.config.hotkey_toggle.clone(),
            st.store.config.hotkey_queue_pop.clone(),
            st.store.config.copy_append_enabled,
            st.recording_slot.is_some(),
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

    let need_hooks = hk_toggle.is_double_tap() || hk_queue.is_double_tap() || recording;
    if need_hooks {
        install_low_level_hooks_if_needed();
    } else {
        uninstall_low_level_hooks();
    }
    install_or_update_tray_icon(hwnd, true);
}

/// 5 层静态规则 + Win32 内核级 `RegisterHotKey` 排他冲突硬拦截校验
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

    // 第 5 层：向 Windows 内核实测该组合键是否已被其他软件排他占用
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
            "「{}」已被系统或其他运行中软件占用，禁止设定",
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
        // 忽略 SendInput 模拟注入按键（LLKHF_INJECTED = 0x10），杜绝自激循环
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

    // 若当前正在设置页录制快捷键，则将该单键双击作为候选提交校验
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
    set_toast(hwnd, format!("快捷键已更新为「{disp}」"));
}

// ============================================================================
// 面板显示定位（支持始终在前坐标记忆）与焦点无感切换
// ============================================================================

unsafe fn show_panel_near_cursor(hwnd: HWND) {
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
            st.autostart_cached = is_autostart_enabled();
        }
    });

    SetWindowPos(hwnd, HWND_TOPMOST, x, y, win_w, win_h, SWP_SHOWWINDOW);
    let _ = SetForegroundWindow(hwnd);
    let _ = SetFocus(hwnd);
    let _ = InvalidateRect(hwnd, null(), FALSE);
}

unsafe fn hide_panel(hwnd: HWND, restore_focus: bool) {
    let mut target_fg: HWND = null_mut();
    let mut was_recording = false;
    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            st.visible = false;
            st.hovered_visible_pos = None;
            st.show_quick_look = false;
            st.editing_alias_item_id = None;
            if st.recording_slot.is_some() {
                st.recording_slot = None;
                st.hotkey_conflict_error = None;
                st.hotkey_recording_hint = None;
                was_recording = true;
            }
            if restore_focus {
                target_fg = st.previous_foreground;
            }
        }
    });
    if was_recording {
        reload_global_hotkeys_and_hooks(hwnd);
    }
    ShowWindow(hwnd, SW_HIDE);
    if restore_focus && !target_fg.is_null() && IsWindow(target_fg) != FALSE {
        let _ = SetForegroundWindow(target_fg);
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

// ============================================================================
// 主窗口消息循环分发
// ============================================================================

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
        WM_TIMER => {
            if wparam == TIMER_ID_OTP_SWEEP {
                let swept = APP_STATE.with(|c| {
                    c.borrow_mut()
                        .as_mut()
                        .map(|s| s.store.sweep_expired_otps(now_unix_secs()))
                        .unwrap_or(0)
                });
                if swept > 0 {
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
                    // 始终在前模式下，记录外部新激活的目标应用，以便点击粘贴时准确切回
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
            bmi.bmiHeader.biHeight = -h; // Top-Down 32-bit BGRA DIB
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
                        render_panel_frame_dib(mem_dc, dib_slice, w, h, scale, st);
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
            handle_mouse_move(hwnd, x, y);
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
                        let step = 44;
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
                        let rows = build_display_rows(&filtered, &st.store.items);
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
    // 稍延 55ms 等用户松开 Alt/Ctrl 组合键后再注入 Ctrl+C，确保前台应用稳定响应复制
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
        if st.store.is_paused {
            st.pending_append_capture = false;
            return true;
        }
        if (st.cf_exclude_monitor != 0
            && IsClipboardFormatAvailable(st.cf_exclude_monitor) != FALSE)
            || (st.cf_viewer_ignore != 0
                && IsClipboardFormatAvailable(st.cf_viewer_ignore) != FALSE)
        {
            return true;
        }
        false
    });
    if should_skip {
        return;
    }

    let source_app = detect_clipboard_source_app(hwnd);

    // 1. 文件列表 CF_HDROP
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

    // 2. 文本与链接 CF_UNICODETEXT
    if IsClipboardFormatAvailable(CF_UNICODETEXT_ID) != FALSE {
        if let Some(mut raw_text) = read_unicode_text_from_clipboard(hwnd) {
            if !raw_text.trim().is_empty() {
                let mut rewrite_clipboard_text: Option<String> = None;
                let mut feedback_toast: Option<String> = None;

                APP_STATE.with(|cell| {
                    if let Some(st) = cell.borrow_mut().as_mut() {
                        let minimal = st.store.config.minimal_mode_enabled;
                        let has_html = st.cf_html_format != 0
                            && IsClipboardFormatAvailable(st.cf_html_format) != FALSE;
                        let from_ide = is_code_editor_or_terminal_app(source_app.as_deref());

                        // A) 若处于 Ctrl+Alt+C 跨处选段续接复制模式
                        if st.pending_append_capture {
                            st.pending_append_capture = false;
                            if let Some(merged) = st.store.append_to_latest_text(&raw_text, "\n") {
                                rewrite_clipboard_text = Some(merged);
                                feedback_toast = Some("已跨处续接追加至首条记录".to_string());
                            }
                            return;
                        }

                        // B) 检测 1.1s 内 Ctrl+C × 2 连按两次复制零离手智变
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
                            let acts = st.store.rank_actions_for_item(
                                &ClipItem::new_text(raw_text.clone(), source_app.clone()),
                                analyze_text_actions(&raw_text, false),
                            );
                            if let Some(top_act) = acts.first() {
                                raw_text = top_act.result_text.clone();
                                rewrite_clipboard_text = Some(raw_text.clone());
                                feedback_toast =
                                    Some(format!("双按复制智变：{}", top_act.toast_text));
                            } else if has_html && !from_ide {
                                rewrite_clipboard_text = Some(raw_text.clone());
                                feedback_toast = Some("双按复制：已剥离富文本脏样式".to_string());
                            }
                        } else if !minimal {
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
                    APP_STATE.with(|c| {
                        if let Some(st) = c.borrow_mut().as_mut() {
                            st.ignore_next_clipboard_seq = true;
                        }
                    });
                    let _ = write_text_and_html_to_clipboard(hwnd, &clean_out, None);
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

    // 3. 位图截图 CF_DIB
    if IsClipboardFormatAvailable(CF_DIB_ID) != FALSE {
        if let Some((png_bytes, w, h)) = read_dib_as_png_from_clipboard(hwnd) {
            APP_STATE.with(|cell| {
                if let Some(st) = cell.borrow_mut().as_mut() {
                    st.pending_append_capture = false;
                    let hash = iclip_core::model::sha256_hex(&png_bytes);
                    let file_name = format!("{}.png", &hash[0..24]);
                    let full_path = st.store.images_dir.join(&file_name);
                    if std::fs::write(&full_path, &png_bytes).is_ok() {
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
            let url = if item.kind == ClipContentType::Link {
                clean_tracking_url(raw.trim()).unwrap_or_else(|| raw.trim().to_string())
            } else if let Some(extracted) = extract_clean_share_url(raw) {
                extracted
            } else {
                return;
            };
            let url_w = to_wide(&url);
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
                let explorer = to_wide("explorer.exe");
                let param = to_wide(&format!("/select,\"{first_path}\""));
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
                    item.image_file_name
                        .as_ref()
                        .map(|f| st.store.images_dir.join(f))
                })
            });
            if let Some(p) = img_path {
                let pw = to_wide(&p.to_string_lossy());
                let _ = ShellExecuteW(
                    null_mut(),
                    op_open.as_ptr(),
                    pw.as_ptr(),
                    null(),
                    null(),
                    SW_SHOWNORMAL,
                );
            }
        }
    }
}

fn item_supports_external_jump(item: &ClipItem) -> bool {
    match item.kind {
        ClipContentType::Link | ClipContentType::File => true,
        ClipContentType::Text => item
            .text
            .as_deref()
            .and_then(|t| {
                let head = iclip_core::model::safe_utf8_prefix(t, 2048);
                if head.contains("http://") || head.contains("https://") {
                    extract_clean_share_url(head)
                } else {
                    None
                }
            })
            .is_some(),
        ClipContentType::Image => false,
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
        let u16_slice = std::slice::from_raw_parts(ptr, byte_len / 2);
        Some(from_wide_slice(u16_slice))
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
    if (bpp == 32 || bpp == 24) && w > 0 && h > 0 && w <= 8192 && h <= 8192 {
        let header_bytes = hdr.biSize as usize;
        let stride = (((w as usize * bpp as usize) + 31) & !31) / 8;
        if header_bytes + stride * (h as usize) <= total_size {
            let pixels = std::slice::from_raw_parts(ptr.add(header_bytes), stride * (h as usize));
            let mut rgba = vec![0u8; (w * h * 4) as usize];
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

    let _ = GlobalUnlock(hdib);
    let _ = CloseClipboard();
    result
}

unsafe fn write_text_and_html_to_clipboard(
    hwnd: HWND,
    text: &str,
    html_format_pair: Option<(u32, &str)>,
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

    let _ = CloseClipboard();
    true
}

unsafe fn write_image_bytes_to_clipboard(hwnd: HWND, encoded_img: &[u8]) -> bool {
    let Ok(dyn_img) = image::load_from_memory(encoded_img) else {
        return false;
    };
    let rgba = dyn_img.to_rgba8();
    let (w, h) = rgba.dimensions();
    let hdr_size = size_of::<BITMAPINFOHEADER>();
    let pixel_bytes = (w * h * 4) as usize;

    if OpenClipboard(hwnd) == FALSE {
        return false;
    }
    let _ = EmptyClipboard();
    let hdib = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, hdr_size + pixel_bytes);
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

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            st.ignore_next_clipboard_seq = true;
            if let Some(item) = st.store.items.get(item_idx).cloned() {
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
        let _ = write_text_and_html_to_clipboard(hwnd, &txt, None);
    } else if let Some(img_path) = image_path_to_write {
        if let Ok(bytes) = std::fs::read(img_path) {
            let _ = write_image_bytes_to_clipboard(hwnd, &bytes);
        }
    }

    SetTimer(hwnd, TIMER_ID_COPY_FLASH_CLEAR, 1_300, None);
    let _ = InvalidateRect(hwnd, null(), FALSE);
}

unsafe fn commit_paste_item_by_index(hwnd: HWND, item_idx: usize, force_plain: bool) {
    let mut auto_paste = true;
    let mut always_top = false;
    let mut target_fg: HWND = null_mut();
    let mut text_to_write: Option<String> = None;
    let mut image_path_to_write: Option<PathBuf> = None;
    let mut item_id_for_otp: Option<String> = None;

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            auto_paste = st.store.config.auto_paste_enabled;
            always_top = st.store.config.always_on_top;
            target_fg = st.previous_foreground;
            st.ignore_next_clipboard_seq = true;
            if let Some(item) = st.store.items.get(item_idx).cloned() {
                item_id_for_otp = Some(item.id.clone());
                let target_app = st.active_target_app_name.clone();
                st.store
                    .record_paste_usage(&item.content_hash, target_app.as_deref());
                match item.kind {
                    ClipContentType::Text | ClipContentType::Link => {
                        if let Some(raw) = &item.text {
                            if !force_plain
                                && !st.store.config.minimal_mode_enabled
                                && (raw.contains("{{clip") || raw.contains("{{date"))
                            {
                                let ctx = st
                                    .store
                                    .items
                                    .iter()
                                    .find(|c| c.id != item.id && c.text.is_some())
                                    .and_then(|c| c.text.as_deref());
                                text_to_write = Some(render_dynamic_template(raw, ctx));
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
        let _ = write_text_and_html_to_clipboard(hwnd, &txt, None);
    } else if let Some(img_path) = image_path_to_write {
        if let Ok(bytes) = std::fs::read(img_path) {
            let _ = write_image_bytes_to_clipboard(hwnd, &bytes);
        }
    }

    if let Some(id) = item_id_for_otp {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.store.schedule_otp_expire_if_needed(&id, 30);
            }
        });
    }

    if always_top {
        if !target_fg.is_null() && IsWindow(target_fg) != FALSE {
            let _ = SetForegroundWindow(target_fg);
        }
        set_toast(hwnd, "✓ 已键入目标窗口".to_string());
    } else {
        hide_panel(hwnd, true);
    }

    if auto_paste {
        std::thread::sleep(std::time::Duration::from_millis(35));
        simulate_ctrl_v(false);
    }
}

unsafe fn commit_direct_text_paste(hwnd: HWND, text: &str, toast: String) {
    let (auto_paste, always_top, target_fg) = APP_STATE.with(|c| {
        let mut b = c.borrow_mut();
        let st = b.as_mut().unwrap();
        st.ignore_next_clipboard_seq = true;
        st.search_query.clear();
        (
            st.store.config.auto_paste_enabled,
            st.store.config.always_on_top,
            st.previous_foreground,
        )
    });
    let _ = write_text_and_html_to_clipboard(hwnd, text, None);
    if always_top {
        if !target_fg.is_null() && IsWindow(target_fg) != FALSE {
            let _ = SetForegroundWindow(target_fg);
        }
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

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            auto_paste = st.store.config.auto_paste_enabled;
            always_top = st.store.config.always_on_top;
            target_fg = st.previous_foreground;
            cf_html_id = st.cf_html_format;
            st.ignore_next_clipboard_seq = true;
            if let Some(it) = st.store.items.get(item_idx).cloned() {
                item_id = Some(it.id);
                st.store
                    .record_action_habit(it.source_app_name.as_deref(), action.id);
            }
        }
    });

    let html_pair = action
        .html_table_payload
        .as_deref()
        .map(|h| (cf_html_id, h));
    let _ = write_text_and_html_to_clipboard(hwnd, &action.result_text, html_pair);

    if let Some(id) = item_id {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.store.schedule_otp_expire_if_needed(&id, 30);
            }
        });
    }

    if always_top {
        if !target_fg.is_null() && IsWindow(target_fg) != FALSE {
            let _ = SetForegroundWindow(target_fg);
        }
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

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            if st.store.config.minimal_mode_enabled {
                return;
            }
            auto_tab = st.store.config.queue_auto_tab;
            img_dir = st.store.images_dir.clone();
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

    if let Some(txt) = &item.text {
        let _ = write_text_and_html_to_clipboard(hwnd, txt, None);
    } else if item.kind == ClipContentType::Image {
        if let Some(f) = &item.image_file_name {
            if let Ok(bytes) = std::fs::read(img_dir.join(f)) {
                let _ = write_image_bytes_to_clipboard(hwnd, &bytes);
            }
        }
    }
    std::thread::sleep(std::time::Duration::from_millis(35));
    simulate_ctrl_v(auto_tab);
}

// ============================================================================
// 1:1 对齐 macOS 液态玻璃深曜石面板混合渲染器（SDF 抗锯齿图形 + ClearType 锐利排版）
// ============================================================================

struct TextDrawCmd {
    text: String,
    rect: RECT,
    color: Color4,
    font_kind: FontKind,
    flags: u32,
}

#[derive(Clone, Copy)]
enum FontKind {
    Headline,
    CardTitle,
    Body,
    Meta,
    BadgeBold,
    Mono,
}

unsafe fn make_ui_font(face_name: &str, px: i32, weight: i32) -> *mut core::ffi::c_void {
    let face = to_wide(face_name);
    CreateFontW(
        -px,
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
        CLEARTYPE_QUALITY as u32,
        0,
        face.as_ptr(),
    )
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
    let full_path = images_dir.join(file_name);
    let raw = std::fs::read(full_path).ok()?;
    let dyn_img = image::load_from_memory(&raw).ok()?;
    let (ow, oh) = (dyn_img.width(), dyn_img.height());
    let thumb = if ow > 240 || oh > 240 {
        dyn_img.resize(240, 240, FilterType::Triangle)
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

unsafe fn render_panel_frame_dib(
    hdc: HDC,
    dib_pixels: &mut [u32],
    w: i32,
    h: i32,
    scale: f32,
    st: &mut WinAppState,
) {
    st.hit_regions.clear();
    let s = |v: i32| ((v as f32) * scale).round() as i32;
    let sf = |v: f32| v * scale;

    let palette = GlassPalette::for_blur_concentration(st.store.config.blur_concentration_pct);
    let mut canvas = PixelCanvas::new(dib_pixels, w, h);
    let mut texts: Vec<TextDrawCmd> = Vec::with_capacity(96);

    // 1. 面板连续圆角液态玻璃底色 + 1px 光学高光细框
    canvas.clear(Color4::rgba(0, 0, 0, 0));
    canvas.fill_round_rect(0, 0, w, h, sf(18.0), palette.window_bg);
    canvas.stroke_round_rect(0, 0, w, h, sf(18.0), sf(1.0), palette.window_border);

    match st.view_mode {
        ActiveViewMode::MainList => {
            layout_and_draw_main_view(&mut canvas, &mut texts, w, h, scale, &palette, st);
        }
        ActiveViewMode::Settings => {
            layout_and_draw_settings_view(&mut canvas, &mut texts, w, h, scale, &palette, st);
        }
    }

    // 原位速览 / 行级 Diff 浮层或 Ctrl+R 备注编辑浮层
    if st.show_quick_look {
        layout_and_draw_quick_look_overlay(&mut canvas, &mut texts, w, h, scale, &palette, st);
    } else if st.editing_alias_item_id.is_some() {
        layout_and_draw_alias_editor_overlay(&mut canvas, &mut texts, w, h, scale, &palette, st);
    }

    // 刷新像素缓冲，随后在同一内存 DC 上叠加 ClearType 高清文字
    let _ = GdiFlush();
    SetBkMode(hdc, TRANSPARENT as i32);

    let f_head = make_ui_font("Segoe UI Variable Text", s(15), FW_BOLD as i32);
    let f_title = make_ui_font("Microsoft YaHei UI", s(13), FW_SEMIBOLD as i32);
    let f_body = make_ui_font("Microsoft YaHei UI", s(12), FW_NORMAL as i32);
    let f_meta = make_ui_font("Microsoft YaHei UI", s(11), FW_NORMAL as i32);
    let f_badge = make_ui_font("Microsoft YaHei UI", s(11), FW_BOLD as i32);
    let f_mono = make_ui_font("Consolas", s(11), FW_MEDIUM as i32);

    let old_font = SelectObject(hdc, f_title);
    for cmd in &texts {
        let font_handle = match cmd.font_kind {
            FontKind::Headline => f_head,
            FontKind::CardTitle => f_title,
            FontKind::Body => f_body,
            FontKind::Meta => f_meta,
            FontKind::BadgeBold => f_badge,
            FontKind::Mono => f_mono,
        };
        SelectObject(hdc, font_handle);
        SetTextColor(hdc, cmd.color.to_colorref());
        let mut wide = to_wide(&cmd.text);
        let mut r = cmd.rect;
        let _ = DrawTextW(
            hdc,
            wide.as_mut_ptr(),
            (wide.len().saturating_sub(1)) as i32,
            &mut r,
            cmd.flags | DT_NOPREFIX,
        );
    }
    SelectObject(hdc, old_font);
    DeleteObject(f_head);
    DeleteObject(f_title);
    DeleteObject(f_body);
    DeleteObject(f_meta);
    DeleteObject(f_badge);
    DeleteObject(f_mono);

    let _ = GdiFlush();
    // 修复 GDI DrawTextW 将文字笔画 Alpha 置 0 的问题，确保 DWM Acrylic 合成下笔画 100% 实心锐利
    for px in dib_pixels.iter_mut() {
        if (*px >> 24) == 0 && (*px & 0x00FF_FFFF) != 0 {
            *px |= 0xFF00_0000;
        }
    }
}

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
    let minimal = st.store.config.minimal_mode_enabled;
    let always_top = st.store.config.always_on_top;

    // 1. 顶栏：左侧胶囊搜索框 + 右侧 3 枚 32x32 几何圆钮（绿叶极简 / 图钉置顶 / 齿轮设置）
    let btn_size = s(32);
    let btn_gap = s(6);
    let right_cluster_w = btn_size * 3 + btn_gap * 2;
    let search_w = w - pad * 2 - right_cluster_w - s(8);
    let top_y = s(13);

    canvas.fill_round_rect(pad, top_y, search_w, btn_size, sf(16.0), palette.search_bg);
    canvas.stroke_round_rect(
        pad,
        top_y,
        search_w,
        btn_size,
        sf(16.0),
        sf(1.0),
        if st.search_query.is_empty() {
            palette.search_border
        } else {
            palette.cobalt.with_alpha(150)
        },
    );
    canvas.draw_icon_search(
        (pad + s(16)) as f32,
        (top_y + btn_size / 2) as f32,
        sf(14.0),
        sf(1.65),
        palette.text_secondary,
    );

    let search_text_right = if st.search_query.is_empty() {
        pad + search_w - s(10)
    } else {
        let clear_rc = RECT {
            left: pad + search_w - s(28),
            top: top_y + s(4),
            right: pad + search_w - s(4),
            bottom: top_y + btn_size - s(4),
        };
        canvas.fill_circle(
            (clear_rc.left + clear_rc.right) as f32 * 0.5,
            (clear_rc.top + clear_rc.bottom) as f32 * 0.5,
            sf(8.5),
            Color4::rgba(148, 172, 214, 42),
        );
        canvas.draw_icon_close(
            (clear_rc.left + clear_rc.right) as f32 * 0.5,
            (clear_rc.top + clear_rc.bottom) as f32 * 0.5,
            sf(9.0),
            sf(1.5),
            palette.text_primary,
        );
        st.hit_regions.push(HitRegion {
            rect: clear_rc,
            interactive_cursor: true,
            action: HitAction::ClearSearch,
        });
        clear_rc.left - s(4)
    };

    let hk_hint = st.store.config.hotkey_toggle.compact_string();
    texts.push(TextDrawCmd {
        text: if st.search_query.is_empty() {
            format!("搜索、拼音速查或算式... ({hk_hint})")
        } else {
            st.search_query.clone()
        },
        rect: RECT {
            left: pad + s(30),
            top: top_y,
            right: search_text_right,
            bottom: top_y + btn_size,
        },
        color: if st.search_query.is_empty() {
            palette.text_muted
        } else {
            palette.text_primary
        },
        font_kind: FontKind::Body,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
    });

    // 右侧 3 枚圆钮：极简绿叶 / 始终在前图钉 / 设置齿轮
    let b1_x = pad + search_w + s(8);
    let b2_x = b1_x + btn_size + btn_gap;
    let b3_x = b2_x + btn_size + btn_gap;

    for (bx, is_active, accent_c, kind) in [
        (b1_x, minimal, palette.emerald, 0u8),
        (b2_x, always_top, palette.cobalt, 1u8),
        (b3_x, false, palette.cobalt, 2u8),
    ] {
        let fill = if is_active {
            accent_c.with_alpha(232)
        } else {
            palette.search_bg
        };
        let border = if is_active {
            Color4::rgba(255, 255, 255, 90)
        } else {
            palette.search_border
        };
        canvas.fill_round_rect(bx, top_y, btn_size, btn_size, sf(16.0), fill);
        canvas.stroke_round_rect(bx, top_y, btn_size, btn_size, sf(16.0), sf(1.0), border);

        let cx = (bx + btn_size / 2) as f32;
        let cy = (top_y + btn_size / 2) as f32;
        let icon_c = if is_active {
            Color4::rgb(255, 255, 255)
        } else {
            palette.text_secondary
        };
        let rc = RECT {
            left: bx,
            top: top_y,
            right: bx + btn_size,
            bottom: top_y + btn_size,
        };
        match kind {
            0 => {
                canvas.draw_icon_leaf(cx, cy, sf(15.0), sf(1.65), icon_c);
                st.hit_regions.push(HitRegion {
                    rect: rc,
                    interactive_cursor: true,
                    action: HitAction::ToggleMinimalMode,
                });
            }
            1 => {
                canvas.draw_icon_pin(cx, cy, sf(15.0), sf(1.65), icon_c, is_active);
                st.hit_regions.push(HitRegion {
                    rect: rc,
                    interactive_cursor: true,
                    action: HitAction::ToggleAlwaysOnTop,
                });
            }
            _ => {
                canvas.draw_icon_gear(cx, cy, sf(15.5), sf(1.65), icon_c);
                st.hit_regions.push(HitRegion {
                    rect: rc,
                    interactive_cursor: true,
                    action: HitAction::ToggleSettingsView,
                });
            }
        }
    }

    // 2. 一体式 6 大分类分段胶囊底槽（对齐 macOS Segmented Capsule Track）
    let track_top = top_y + btn_size + s(9);
    let track_h = s(30);
    let track_w = w - pad * 2;
    canvas.fill_round_rect(pad, track_top, track_w, track_h, sf(15.0), palette.track_bg);
    canvas.stroke_round_rect(
        pad,
        track_top,
        track_w,
        track_h,
        sf(15.0),
        sf(1.0),
        palette.track_border,
    );

    let inner_pad = s(3);
    let seg_w = (track_w - inner_pad * 2) / 6;
    for (idx, tab) in ClipFilterTab::ALL_TABS.iter().enumerate() {
        let sx = pad + inner_pad + (idx as i32) * seg_w;
        let sw = if idx == 5 {
            pad + track_w - inner_pad - sx
        } else {
            seg_w
        };
        let sy = track_top + inner_pad;
        let sh = track_h - inner_pad * 2;
        let active = st.selected_tab == *tab;
        if active {
            canvas.fill_round_rect(sx, sy, sw, sh, sf(12.0), palette.cobalt);
        }
        let rc = RECT {
            left: sx,
            top: sy,
            right: sx + sw,
            bottom: sy + sh,
        };
        texts.push(TextDrawCmd {
            text: tab.title().to_string(),
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
            rect: rc,
            interactive_cursor: true,
            action: HitAction::SelectTab(*tab),
        });
    }

    let mut cur_y = track_top + track_h + s(8);

    // 2.5 若选中「收藏」页，展开 4 大分组子筛选胶囊栏（全部收藏 / 常用话术 / 开票财务 / 地址名片 / 合同模板）
    if st.selected_tab == ClipFilterTab::Pinned {
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
                .unwrap_or(palette.amber);
            canvas.fill_round_rect(
                cx,
                cur_y,
                cw,
                sub_h,
                sf(12.0),
                if active {
                    accent.with_alpha(220)
                } else {
                    palette.track_bg
                },
            );
            if !active {
                canvas.stroke_round_rect(
                    cx,
                    cur_y,
                    cw,
                    sub_h,
                    sf(12.0),
                    sf(1.0),
                    palette.track_border,
                );
            }
            let rc = RECT {
                left: cx,
                top: cur_y,
                right: cx + cw,
                bottom: cur_y + sub_h,
            };
            texts.push(TextDrawCmd {
                text: opt_cat.map(|c| c.title()).unwrap_or("全部").to_string(),
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
                rect: rc,
                interactive_cursor: true,
                action: HitAction::SelectPinCategory(*opt_cat),
            });
        }
        cur_y += sub_h + s(8);
    }

    // 3. 搜索框智能三合一内嵌横幅（即时速算 + 刚复制金额续算 / `>` 闪念速记 / `@建议` 自我进化）
    if !minimal && !st.search_query.trim().is_empty() {
        let latest_txt = st.store.items.iter().find_map(|it| it.text.as_deref());
        if let Some(sug) = extract_suggestion_payload(&st.search_query) {
            let bh = s(46);
            canvas.fill_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(12.0),
                Color4::rgba(68, 48, 18, 235),
            );
            canvas.stroke_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(12.0),
                sf(1.0),
                palette.amber.with_alpha(150),
            );
            let title = if sug.is_empty() {
                "输入偏好指令后按 Enter 立即生效（如：开启始终在前 / 双击 Ctrl 呼出）".to_string()
            } else {
                format!("采纳建议：「{sug}」 · 按 Enter 立即生效")
            };
            texts.push(TextDrawCmd {
                text: title,
                rect: RECT {
                    left: pad + s(12),
                    top: cur_y,
                    right: w - pad - s(12),
                    bottom: cur_y + bh,
                },
                color: Color4::rgb(254, 243, 199),
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
            let bh = s(46);
            canvas.fill_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(12.0),
                Color4::rgba(14, 62, 48, 235),
            );
            canvas.stroke_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(12.0),
                sf(1.0),
                palette.emerald.with_alpha(150),
            );
            let desc = if cap.body.is_empty() {
                "闪念速记：输入 `> 备注名 :: 正文` 按 Enter 直接入库并自动收藏".to_string()
            } else if let Some(al) = &cap.alias {
                format!("新建收藏「{al}」：{} · Enter 保存", cap.body)
            } else {
                format!("速记入库：{} · Enter 保存", cap.body)
            };
            texts.push(TextDrawCmd {
                text: desc,
                rect: RECT {
                    left: pad + s(12),
                    top: cur_y,
                    right: w - pad - s(12),
                    bottom: cur_y + bh,
                },
                color: Color4::rgb(209, 250, 229),
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
        } else if let Some(math) = evaluate_instant_math(&st.search_query, latest_txt) {
            let bh = s(52);
            canvas.fill_vgrad_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(13.0),
                Color4::rgba(26, 66, 178, 238),
                Color4::rgba(19, 49, 138, 238),
            );
            canvas.stroke_round_rect(
                pad,
                cur_y,
                track_w,
                bh,
                sf(13.0),
                sf(1.0),
                palette.select_border,
            );
            let ctx_tag = if math.used_clipboard_context {
                " (续算剪贴板金额)"
            } else {
                ""
            };
            texts.push(TextDrawCmd {
                text: format!("= {}", math.plain_value),
                rect: RECT {
                    left: pad + s(12),
                    top: cur_y + s(5),
                    right: w - pad - s(12),
                    bottom: cur_y + s(28),
                },
                color: Color4::rgb(255, 255, 255),
                font_kind: FontKind::Headline,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            let sub = if let Some(rmb) = &math.rmb_uppercase {
                format!(
                    "{}{} · {rmb} (Enter 数值 / Shift+Enter 大写)",
                    math.expression_display, ctx_tag
                )
            } else {
                format!(
                    "{}{} · 按 Enter 直接粘贴计算结果",
                    math.expression_display, ctx_tag
                )
            };
            texts.push(TextDrawCmd {
                text: sub,
                rect: RECT {
                    left: pad + s(12),
                    top: cur_y + s(27),
                    right: w - pad - s(12),
                    bottom: cur_y + bh - s(4),
                },
                color: Color4::rgb(208, 224, 255),
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
        }
    }

    // 4. 主列表区（连续图片自动 3 列圆角宫格 + 常驻零抖动标准卡片）
    let filtered = st.store.filtered_indices_ext(
        st.selected_tab,
        st.selected_pin_category,
        &st.search_query,
        st.active_target_app_name.as_deref(),
    );
    if st.selected_visible_pos >= filtered.len() {
        st.selected_visible_pos = filtered.len().saturating_sub(1);
    }

    let rows = build_display_rows(&filtered, &st.store.items);
    if st.scroll_row_offset >= rows.len() {
        st.scroll_row_offset = rows.len().saturating_sub(1);
    }

    let footer_h = s(32);
    let max_list_bottom = h - footer_h - s(6);

    if rows.is_empty() {
        texts.push(TextDrawCmd {
            text: "暂无匹配记录".to_string(),
            rect: RECT {
                left: pad,
                top: cur_y + s(74),
                right: w - pad,
                bottom: cur_y + s(102),
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
        texts.push(TextDrawCmd {
            text: "复制文本、链接、截图或输入 `> 备注 :: 正文` 即可归档".to_string(),
            rect: RECT {
                left: pad + s(12),
                top: cur_y + s(104),
                right: w - pad - s(12),
                bottom: cur_y + s(132),
            },
            color: palette.text_muted,
            font_kind: FontKind::Meta,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
    } else {
        let images_dir = st.store.images_dir.clone();
        for row in rows.iter().skip(st.scroll_row_offset) {
            match row {
                DisplayRow::ImageGridRow { cells } => {
                    let row_h = image_grid_row_height(scale);
                    let studio_h = if minimal { 0 } else { s(28) };
                    if cur_y + row_h + studio_h > max_list_bottom {
                        break;
                    }
                    let gap = s(8);
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
                                    tx + s(2),
                                    cur_y + s(2),
                                    tw - s(4),
                                    row_h - s(4),
                                    sf(11.0),
                                    rgba,
                                    iw,
                                    ih,
                                );
                            }
                        }

                        // 底部暗角信息条（分辨率尺寸）
                        let bar_h = s(22);
                        canvas.fill_round_rect(
                            tx + s(2),
                            cur_y + row_h - bar_h - s(2),
                            tw - s(4),
                            bar_h,
                            sf(9.0),
                            Color4::rgba(10, 14, 24, 178),
                        );
                        let dim_txt = match (item.image_width, item.image_height) {
                            (Some(iw), Some(ih)) => format!("{iw}×{ih}"),
                            _ => "PNG".to_string(),
                        };
                        texts.push(TextDrawCmd {
                            text: dim_txt,
                            rect: RECT {
                                left: tx + s(8),
                                top: cur_y + row_h - bar_h - s(2),
                                right: tx + tw - s(8),
                                bottom: cur_y + row_h - s(2),
                            },
                            color: Color4::rgb(232, 238, 250),
                            font_kind: FontKind::Mono,
                            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                        });

                        let border_c = if is_sel {
                            palette.cobalt
                        } else if item.is_pinned {
                            palette.amber
                        } else if is_hov {
                            Color4::rgba(255, 255, 255, 95)
                        } else {
                            palette.card_border
                        };
                        canvas.stroke_round_rect(
                            tx,
                            cur_y,
                            tw,
                            row_h,
                            sf(13.0),
                            if is_sel { sf(2.2) } else { sf(1.0) },
                            border_c,
                        );

                        // 右上角悬停操作或快捷键角标
                        if is_hov || is_sel {
                            let b_sz = s(22);
                            let del_x = tx + tw - b_sz - s(5);
                            let pin_x = del_x - b_sz - s(4);
                            let by = cur_y + s(5);

                            canvas.fill_round_rect(
                                pin_x,
                                by,
                                b_sz,
                                b_sz,
                                sf(11.0),
                                Color4::rgba(15, 22, 36, 210),
                            );
                            canvas.draw_icon_star(
                                (pin_x + b_sz / 2) as f32,
                                (by + b_sz / 2) as f32,
                                sf(12.0),
                                sf(1.5),
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

                            canvas.fill_round_rect(
                                del_x,
                                by,
                                b_sz,
                                b_sz,
                                sf(11.0),
                                palette.danger.with_alpha(220),
                            );
                            canvas.draw_icon_trash(
                                (del_x + b_sz / 2) as f32,
                                (by + b_sz / 2) as f32,
                                sf(11.5),
                                sf(1.5),
                                Color4::rgb(255, 255, 255),
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
                        } else if vis_pos < 9 {
                            let bw = s(44);
                            let bh = s(18);
                            let bx = tx + tw - bw - s(5);
                            let by = cur_y + s(5);
                            canvas.fill_round_rect(
                                bx,
                                by,
                                bw,
                                bh,
                                sf(9.0),
                                Color4::rgba(12, 18, 30, 195),
                            );
                            texts.push(TextDrawCmd {
                                text: format!("^{}", vis_pos + 1),
                                rect: RECT {
                                    left: bx,
                                    top: by,
                                    right: bx + bw,
                                    bottom: by + bh,
                                },
                                color: Color4::rgb(220, 230, 248),
                                font_kind: FontKind::Mono,
                                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                            });
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
                    if !minimal && !cells.is_empty() {
                        let target_store_idx = cells
                            .iter()
                            .find(|(vp, _)| *vp == st.selected_visible_pos)
                            .map(|(_, si)| *si)
                            .unwrap_or(cells[0].1);
                        let chip_y = cur_y + row_h + s(5);
                        let chip_h = s(21);
                        let mut cx = pad;
                        for (lbl, is_jpg) in [("轻量瘦身 JPEG", true), ("圆角阴影样机图", false)]
                        {
                            let cw = s(108);
                            canvas.fill_round_rect(
                                cx,
                                chip_y,
                                cw,
                                chip_h,
                                sf(10.5),
                                Color4::rgba(30, 94, 255, 36),
                            );
                            canvas.stroke_round_rect(
                                cx,
                                chip_y,
                                cw,
                                chip_h,
                                sf(10.5),
                                sf(1.0),
                                palette.cobalt.with_alpha(115),
                            );
                            texts.push(TextDrawCmd {
                                text: lbl.to_string(),
                                rect: RECT {
                                    left: cx + s(6),
                                    top: chip_y,
                                    right: cx + cw - s(6),
                                    bottom: chip_y + chip_h,
                                },
                                color: palette.text_primary,
                                font_kind: FontKind::BadgeBold,
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
                    cur_y += row_h + studio_h + s(8);
                }

                DisplayRow::StandardCard { vis_pos, store_idx } => {
                    let vis_pos = *vis_pos;
                    let store_idx = *store_idx;
                    let item = st.store.items[store_idx].clone();
                    let is_selected = vis_pos == st.selected_visible_pos;
                    let is_hovered = st.hovered_visible_pos == Some(vis_pos);

                    // 零抖动关键：快捷动作与选中态解耦常驻计算，切换选中高度恒定不变！
                    let quick_actions = if !minimal {
                        if let Some(raw) = &item.text {
                            st.store
                                .rank_actions_for_item(&item, analyze_text_actions(raw, false))
                        } else {
                            Vec::new()
                        }
                    } else {
                        Vec::new()
                    };
                    let has_chips = !quick_actions.is_empty();
                    let card_h = standard_card_height(has_chips, scale);
                    if cur_y + card_h > max_list_bottom {
                        break;
                    }

                    // 卡片底板与 1px 静态描边（绝不叠加阴影）
                    if is_selected {
                        canvas.fill_vgrad_round_rect(
                            pad,
                            cur_y,
                            track_w,
                            card_h,
                            sf(14.0),
                            palette.select_top,
                            palette.select_bottom,
                        );
                        canvas.stroke_round_rect(
                            pad,
                            cur_y,
                            track_w,
                            card_h,
                            sf(14.0),
                            sf(1.0),
                            palette.select_border,
                        );
                    } else {
                        let bg = if item.is_pinned {
                            if is_hovered {
                                palette.card_pinned_hover_bg
                            } else {
                                palette.card_pinned_bg
                            }
                        } else if is_hovered {
                            palette.card_hover_bg
                        } else {
                            palette.card_bg
                        };
                        let bd = if item.is_pinned {
                            palette.card_pinned_border
                        } else {
                            palette.card_border
                        };
                        canvas.fill_round_rect(pad, cur_y, track_w, card_h, sf(14.0), bg);
                        canvas.stroke_round_rect(
                            pad,
                            cur_y,
                            track_w,
                            card_h,
                            sf(14.0),
                            sf(1.0),
                            bd,
                        );
                    }

                    // 左侧 42x42 视觉徽标（链接与含网页口令卡片为电光蓝跃迁徽标，文件卡片为青蓝文档徽标）
                    let can_jump = item_supports_external_jump(&item);
                    let mut text_left = pad + s(12);
                    if can_jump {
                        let badge_sz = s(40);
                        let bx = pad + s(10);
                        let by = cur_y + s(11);
                        let badge_bg = if is_selected {
                            Color4::rgba(255, 255, 255, 42)
                        } else if item.kind == ClipContentType::File {
                            Color4::rgba(16, 185, 129, 38)
                        } else {
                            Color4::rgba(30, 94, 255, 46)
                        };
                        let badge_bd = if is_selected {
                            Color4::rgba(255, 255, 255, 86)
                        } else if item.kind == ClipContentType::File {
                            palette.emerald.with_alpha(110)
                        } else {
                            palette.cobalt.with_alpha(130)
                        };
                        canvas.fill_round_rect(bx, by, badge_sz, badge_sz, sf(11.0), badge_bg);
                        canvas.stroke_round_rect(
                            bx,
                            by,
                            badge_sz,
                            badge_sz,
                            sf(11.0),
                            sf(1.0),
                            badge_bd,
                        );

                        let ic_c = if is_selected {
                            Color4::rgb(255, 255, 255)
                        } else if item.kind == ClipContentType::File {
                            palette.emerald
                        } else {
                            Color4::rgb(104, 158, 255)
                        };
                        let ic_cx = (bx + badge_sz / 2) as f32;
                        let ic_cy = (by + badge_sz / 2) as f32;
                        if item.kind == ClipContentType::File {
                            canvas.draw_icon_file(ic_cx, ic_cy, sf(17.0), sf(1.65), ic_c);
                        } else {
                            canvas.draw_icon_external_link(ic_cx, ic_cy, sf(16.0), sf(1.8), ic_c);
                        }

                        st.hit_regions.push(HitRegion {
                            rect: RECT {
                                left: bx,
                                top: by,
                                right: bx + badge_sz,
                                bottom: by + badge_sz,
                            },
                            interactive_cursor: true,
                            action: HitAction::OpenExternalTarget(store_idx),
                        });
                        text_left = bx + badge_sz + s(10);
                    }

                    // 右上角悬停磨砂圆钮（`↗` 直达 + 五角星收藏 + 垃圾桶删除）或 `Ctrl+1..9` 胶囊
                    let action_area_w = if is_hovered {
                        if can_jump {
                            s(82)
                        } else {
                            s(56)
                        }
                    } else {
                        s(58)
                    };

                    if is_hovered {
                        let b_sz = s(22);
                        let by = cur_y + s(8);
                        let del_x = w - pad - s(8) - b_sz;
                        let pin_x = del_x - s(4) - b_sz;

                        if can_jump {
                            let open_x = pin_x - s(4) - b_sz;
                            canvas.fill_round_rect(
                                open_x,
                                by,
                                b_sz,
                                b_sz,
                                sf(11.0),
                                if is_selected {
                                    Color4::rgba(255, 255, 255, 48)
                                } else {
                                    palette.cobalt.with_alpha(210)
                                },
                            );
                            canvas.draw_icon_external_link(
                                (open_x + b_sz / 2) as f32,
                                (by + b_sz / 2) as f32,
                                sf(11.5),
                                sf(1.6),
                                Color4::rgb(255, 255, 255),
                            );
                            st.hit_regions.push(HitRegion {
                                rect: RECT {
                                    left: open_x,
                                    top: by,
                                    right: open_x + b_sz,
                                    bottom: by + b_sz,
                                },
                                interactive_cursor: true,
                                action: HitAction::OpenExternalTarget(store_idx),
                            });
                        }

                        canvas.fill_round_rect(
                            pin_x,
                            by,
                            b_sz,
                            b_sz,
                            sf(11.0),
                            if item.is_pinned {
                                palette.amber.with_alpha(225)
                            } else if is_selected {
                                Color4::rgba(255, 255, 255, 42)
                            } else {
                                Color4::rgba(52, 64, 88, 220)
                            },
                        );
                        canvas.draw_icon_star(
                            (pin_x + b_sz / 2) as f32,
                            (by + b_sz / 2) as f32,
                            sf(12.0),
                            sf(1.5),
                            Color4::rgb(255, 255, 255),
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

                        canvas.fill_round_rect(
                            del_x,
                            by,
                            b_sz,
                            b_sz,
                            sf(11.0),
                            palette.danger.with_alpha(220),
                        );
                        canvas.draw_icon_trash(
                            (del_x + b_sz / 2) as f32,
                            (by + b_sz / 2) as f32,
                            sf(11.5),
                            sf(1.5),
                            Color4::rgb(255, 255, 255),
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
                    } else if let Some(q_rank) = st.store.queue_rank(&item.id) {
                        let bw = s(48);
                        let bh = s(19);
                        let bx = w - pad - bw - s(8);
                        let by = cur_y + s(9);
                        canvas.fill_round_rect(bx, by, bw, bh, sf(9.5), palette.emerald);
                        texts.push(TextDrawCmd {
                            text: format!("队列#{q_rank}"),
                            rect: RECT {
                                left: bx,
                                top: by,
                                right: bx + bw,
                                bottom: by + bh,
                            },
                            color: Color4::rgb(255, 255, 255),
                            font_kind: FontKind::BadgeBold,
                            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                        });
                    } else if vis_pos < 9 {
                        let bw = s(50);
                        let bh = s(19);
                        let bx = w - pad - bw - s(8);
                        let by = cur_y + s(9);
                        canvas.fill_round_rect(
                            bx,
                            by,
                            bw,
                            bh,
                            sf(9.5),
                            if is_selected {
                                Color4::rgba(255, 255, 255, 36)
                            } else {
                                Color4::rgba(148, 172, 214, 24)
                            },
                        );
                        texts.push(TextDrawCmd {
                            text: format!("Ctrl+{}", vis_pos + 1),
                            rect: RECT {
                                left: bx,
                                top: by,
                                right: bx + bw,
                                bottom: by + bh,
                            },
                            color: if is_selected {
                                Color4::rgb(255, 255, 255)
                            } else {
                                palette.text_muted
                            },
                            font_kind: FontKind::Mono,
                            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                        });
                    }

                    // 主标题
                    texts.push(TextDrawCmd {
                        text: item.primary_title(minimal),
                        rect: RECT {
                            left: text_left,
                            top: cur_y + s(8),
                            right: w - pad - action_area_w - s(6),
                            bottom: cur_y + s(30),
                        },
                        color: if is_selected {
                            Color4::rgb(255, 255, 255)
                        } else {
                            palette.text_primary
                        },
                        font_kind: FontKind::CardTitle,
                        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                    });

                    // 副标题左侧矢量星标 + 分类彩点 + 元信息 + 右侧等宽相对时间
                    let mut meta_x = text_left;
                    let meta_cy = (cur_y + s(41)) as f32;
                    if item.is_pinned {
                        canvas.draw_icon_star(
                            meta_x as f32 + sf(5.5),
                            meta_cy,
                            sf(11.0),
                            sf(1.4),
                            if is_selected {
                                Color4::rgb(255, 255, 255)
                            } else {
                                palette.amber
                            },
                            true,
                        );
                        meta_x += s(15);
                    }
                    if !minimal {
                        if let Some(cat) = item.pin_category {
                            let dot_c = if is_selected {
                                Color4::rgb(255, 255, 255)
                            } else {
                                GlassPalette::pin_category_color(cat)
                            };
                            canvas.fill_circle(meta_x as f32 + sf(3.5), meta_cy, sf(3.2), dot_c);
                            meta_x += s(10);
                        }
                    }

                    let mut sub_parts: Vec<String> = Vec::new();
                    if !minimal {
                        if let Some(cat) = item.pin_category {
                            sub_parts.push(cat.title().to_string());
                        }
                    }
                    sub_parts.push(item.subtitle_info());
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

                    let rel_time = format_relative_time(item.created_unix_secs);
                    let time_w = s(58);
                    texts.push(TextDrawCmd {
                        text: sub_parts.join(" · "),
                        rect: RECT {
                            left: meta_x,
                            top: cur_y + s(31),
                            right: w - pad - time_w - s(10),
                            bottom: cur_y + s(51),
                        },
                        color: if st.copied_flash_item_id.as_deref() == Some(item.id.as_str()) {
                            if is_selected {
                                Color4::rgb(255, 255, 255)
                            } else {
                                palette.emerald
                            }
                        } else if is_selected {
                            Color4::rgb(214, 228, 255)
                        } else {
                            palette.text_secondary
                        },
                        font_kind: FontKind::Meta,
                        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                    });
                    texts.push(TextDrawCmd {
                        text: rel_time,
                        rect: RECT {
                            left: w - pad - time_w - s(8),
                            top: cur_y + s(31),
                            right: w - pad - s(10),
                            bottom: cur_y + s(51),
                        },
                        color: if is_selected {
                            Color4::rgb(206, 222, 255)
                        } else {
                            palette.text_muted
                        },
                        font_kind: FontKind::Meta,
                        flags: DT_RIGHT | DT_VCENTER | DT_SINGLELINE,
                    });

                    // 常驻智能变换动作胶囊条（零高度跳变）
                    if has_chips {
                        let mut chip_x = pad + s(10);
                        let chip_top = cur_y + s(56);
                        let chip_h = s(22);
                        for (a_idx, act) in quick_actions.iter().enumerate() {
                            let char_len = act.title.chars().count().min(18) as i32;
                            let cw = (char_len * s(10) + s(30)).min(w - pad - chip_x - s(8));
                            if cw < s(56) {
                                break;
                            }
                            let chip_bg = if act.is_security {
                                if is_selected {
                                    Color4::rgba(196, 98, 18, 230)
                                } else {
                                    Color4::rgba(245, 158, 11, 38)
                                }
                            } else if is_selected {
                                Color4::rgba(255, 255, 255, 38)
                            } else {
                                Color4::rgba(30, 94, 255, 36)
                            };
                            let chip_bd = if is_selected {
                                Color4::rgba(255, 255, 255, 92)
                            } else if act.is_security {
                                palette.amber.with_alpha(115)
                            } else {
                                palette.cobalt.with_alpha(115)
                            };
                            canvas.fill_round_rect(chip_x, chip_top, cw, chip_h, sf(11.0), chip_bg);
                            canvas.stroke_round_rect(
                                chip_x,
                                chip_top,
                                cw,
                                chip_h,
                                sf(11.0),
                                sf(1.0),
                                chip_bd,
                            );
                            let bolt_c = if is_selected {
                                Color4::rgb(255, 255, 255)
                            } else if act.is_security {
                                palette.amber
                            } else {
                                Color4::rgb(112, 164, 255)
                            };
                            canvas.draw_icon_bolt(
                                (chip_x + s(11)) as f32,
                                (chip_top + chip_h / 2) as f32,
                                sf(10.0),
                                sf(1.4),
                                bolt_c,
                            );
                            let label = if a_idx == 0 && is_selected {
                                format!("{} ⇧↵", act.title)
                            } else {
                                act.title.clone()
                            };
                            texts.push(TextDrawCmd {
                                text: label,
                                rect: RECT {
                                    left: chip_x + s(19),
                                    top: chip_top,
                                    right: chip_x + cw - s(6),
                                    bottom: chip_top + chip_h,
                                },
                                color: if is_selected {
                                    Color4::rgb(255, 255, 255)
                                } else {
                                    palette.text_primary
                                },
                                font_kind: FontKind::BadgeBold,
                                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                            });
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
                    cur_y += card_h + s(8);
                }
            }
        }
    }

    // 5. 底栏：左侧翡翠状态圆点 + 条数统计/Toast/撤销按钮 + 右侧精简键帽提示（对齐 Mac 底栏）
    let foot_top = h - footer_h;
    canvas.draw_line(
        pad as f32,
        foot_top as f32,
        (w - pad) as f32,
        foot_top as f32,
        sf(1.0),
        palette.track_border,
    );

    let dot_c = if st.store.is_paused {
        palette.amber
    } else {
        palette.emerald
    };
    canvas.fill_circle(
        (pad + s(5)) as f32,
        (foot_top + footer_h / 2) as f32,
        sf(3.5),
        dot_c,
    );

    let now_s = now_unix_secs();
    if let Some(toast) = &st.toast_message {
        texts.push(TextDrawCmd {
            text: toast.clone(),
            rect: RECT {
                left: pad + s(14),
                top: foot_top,
                right: w - pad,
                bottom: h - s(2),
            },
            color: palette.emerald,
            font_kind: FontKind::BadgeBold,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
    } else if st.store.has_active_undo(now_s) {
        let undo_w = s(106);
        let ux = w - pad - undo_w;
        let uy = foot_top + s(5);
        let uh = footer_h - s(10);
        canvas.fill_round_rect(ux, uy, undo_w, uh, sf(10.0), palette.cobalt.with_alpha(210));
        texts.push(TextDrawCmd {
            text: "撤销删除 Ctrl+Z".to_string(),
            rect: RECT {
                left: ux,
                top: uy,
                right: ux + undo_w,
                bottom: uy + uh,
            },
            color: Color4::rgb(255, 255, 255),
            font_kind: FontKind::BadgeBold,
            flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        });
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: ux,
                top: uy,
                right: ux + undo_w,
                bottom: uy + uh,
            },
            interactive_cursor: true,
            action: HitAction::UndoDelete,
        });
        texts.push(TextDrawCmd {
            text: format!("已删除记录 · 共 {} 条", filtered.len()),
            rect: RECT {
                left: pad + s(14),
                top: foot_top,
                right: ux - s(8),
                bottom: h - s(2),
            },
            color: palette.text_secondary,
            font_kind: FontKind::Meta,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
    } else {
        let left_stat = if st.store.is_paused {
            "已暂停监听".to_string()
        } else if always_top {
            format!("{} 条 · 钉住模式（单击复制 / 双击键入）", filtered.len())
        } else {
            format!(
                "{} 条 · {}",
                filtered.len(),
                ClipboardStore::edition_title()
            )
        };
        texts.push(TextDrawCmd {
            text: left_stat,
            rect: RECT {
                left: pad + s(14),
                top: foot_top,
                right: w / 2 + s(26),
                bottom: h - s(2),
            },
            color: palette.text_muted,
            font_kind: FontKind::Meta,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        });
        texts.push(TextDrawCmd {
            text: "Space 速览 · ^R 备注 · ^, 设置".to_string(),
            rect: RECT {
                left: w / 2 + s(28),
                top: foot_top,
                right: w - pad,
                bottom: h - s(2),
            },
            color: palette.text_muted,
            font_kind: FontKind::Meta,
            flags: DT_RIGHT | DT_VCENTER | DT_SINGLELINE,
        });
    }
}

// ============================================================================
// 面板内嵌偏好设置视图（全量对齐 Mac 端配置能力、单键双击录制与冲突硬拦截）
// ============================================================================

fn layout_and_draw_settings_view(
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
    let content_w = w - pad * 2;

    // 1. 设置页固定顶栏（返回圆钮 + 偏好设置标题 + 版本角色徽章）
    let header_h = s(48);
    let back_sz = s(30);
    let bx = pad;
    let by = s(12);
    canvas.fill_round_rect(bx, by, back_sz, back_sz, sf(15.0), palette.search_bg);
    canvas.stroke_round_rect(
        bx,
        by,
        back_sz,
        back_sz,
        sf(15.0),
        sf(1.0),
        palette.search_border,
    );
    canvas.draw_icon_back(
        (bx + back_sz / 2) as f32,
        (by + back_sz / 2) as f32,
        sf(13.0),
        sf(1.8),
        palette.text_primary,
    );
    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: bx,
            top: by,
            right: bx + back_sz,
            bottom: by + back_sz,
        },
        interactive_cursor: true,
        action: HitAction::ToggleSettingsView,
    });

    texts.push(TextDrawCmd {
        text: "偏好设置".to_string(),
        rect: RECT {
            left: bx + back_sz + s(10),
            top: by,
            right: w - pad - s(130),
            bottom: by + back_sz,
        },
        color: palette.text_primary,
        font_kind: FontKind::Headline,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
    });

    let ver_tag = format!(
        "v{} · {}",
        env!("CARGO_PKG_VERSION"),
        ClipboardStore::edition_title()
    );
    texts.push(TextDrawCmd {
        text: ver_tag,
        rect: RECT {
            left: w - pad - s(160),
            top: by,
            right: w - pad,
            bottom: by + back_sz,
        },
        color: palette.text_muted,
        font_kind: FontKind::Meta,
        flags: DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
    });

    canvas.draw_line(
        pad as f32,
        header_h as f32,
        (w - pad) as f32,
        header_h as f32,
        sf(1.0),
        palette.track_border,
    );

    let view_top = header_h + s(6);
    let view_bottom = h - s(30);
    let mut y = view_top - st.settings_scroll_px;

    let in_viewport =
        |ry: i32, rh: i32| -> bool { ry >= view_top - s(4) && (ry + rh) <= view_bottom + s(4) };

    // 区块 1：全局快捷键录制（支持单键双击 Ctrl/Alt/Shift/Win + 5层冲突硬拦截）
    let hk_card_h = if st.hotkey_conflict_error.is_some() || st.hotkey_recording_hint.is_some() {
        s(128)
    } else {
        s(102)
    };
    if in_viewport(y, hk_card_h) {
        canvas.fill_round_rect(pad, y, content_w, hk_card_h, sf(14.0), palette.card_bg);
        canvas.stroke_round_rect(
            pad,
            y,
            content_w,
            hk_card_h,
            sf(14.0),
            sf(1.0),
            palette.card_border,
        );

        for (row_i, (slot, label, cur_hk)) in [
            (
                WinHotKeySlot::MainToggle,
                "呼出 / 隐藏主面板",
                st.store.config.hotkey_toggle.clone(),
            ),
            (
                WinHotKeySlot::QueuePop,
                "顺序粘贴队列出队",
                st.store.config.hotkey_queue_pop.clone(),
            ),
        ]
        .into_iter()
        .enumerate()
        {
            let ry = y + s(10) + (row_i as i32) * s(42);
            let rh = s(32);
            texts.push(TextDrawCmd {
                text: label.to_string(),
                rect: RECT {
                    left: pad + s(12),
                    top: ry,
                    right: pad + s(156),
                    bottom: ry + rh,
                },
                color: palette.text_primary,
                font_kind: FontKind::Body,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
            });

            let reset_w = s(44);
            let rx_reset = w - pad - s(10) - reset_w;
            let pill_w = s(142);
            let rx_pill = rx_reset - s(6) - pill_w;
            let is_rec = st.recording_slot == Some(slot);
            let has_conflict = is_rec && st.hotkey_conflict_error.is_some();

            canvas.fill_round_rect(
                rx_pill,
                ry + s(2),
                pill_w,
                rh - s(4),
                sf(10.0),
                if has_conflict {
                    palette.danger
                } else if is_rec {
                    palette.cobalt.with_alpha(230)
                } else {
                    palette.track_bg
                },
            );
            canvas.stroke_round_rect(
                rx_pill,
                ry + s(2),
                pill_w,
                rh - s(4),
                sf(10.0),
                sf(1.0),
                if is_rec {
                    Color4::rgb(255, 255, 255)
                } else {
                    palette.search_border
                },
            );
            texts.push(TextDrawCmd {
                text: if has_conflict {
                    "冲突 · 请重按".to_string()
                } else if is_rec {
                    "等待按键...".to_string()
                } else {
                    cur_hk.display_string()
                },
                rect: RECT {
                    left: rx_pill + s(6),
                    top: ry + s(2),
                    right: rx_pill + pill_w - s(6),
                    bottom: ry + rh - s(2),
                },
                color: Color4::rgb(255, 255, 255),
                font_kind: if is_rec {
                    FontKind::BadgeBold
                } else {
                    FontKind::Mono
                },
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: rx_pill,
                    top: ry + s(2),
                    right: rx_pill + pill_w,
                    bottom: ry + rh - s(2),
                },
                interactive_cursor: true,
                action: HitAction::StartRecordHotkey(slot),
            });

            canvas.fill_round_rect(
                rx_reset,
                ry + s(4),
                reset_w,
                rh - s(8),
                sf(8.0),
                Color4::rgba(148, 172, 214, 24),
            );
            texts.push(TextDrawCmd {
                text: "默认".to_string(),
                rect: RECT {
                    left: rx_reset,
                    top: ry + s(4),
                    right: rx_reset + reset_w,
                    bottom: ry + rh - s(4),
                },
                color: palette.text_secondary,
                font_kind: FontKind::Meta,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: rx_reset,
                    top: ry + s(4),
                    right: rx_reset + reset_w,
                    bottom: ry + rh - s(4),
                },
                interactive_cursor: true,
                action: HitAction::ResetHotkeyDefault(slot),
            });
        }

        if let Some(err) = &st.hotkey_conflict_error {
            texts.push(TextDrawCmd {
                text: err.clone(),
                rect: RECT {
                    left: pad + s(12),
                    top: y + s(96),
                    right: w - pad - s(10),
                    bottom: y + hk_card_h - s(6),
                },
                color: Color4::rgb(255, 106, 116),
                font_kind: FontKind::BadgeBold,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
        } else if let Some(hint) = &st.hotkey_recording_hint {
            texts.push(TextDrawCmd {
                text: hint.clone(),
                rect: RECT {
                    left: pad + s(12),
                    top: y + s(96),
                    right: w - pad - s(10),
                    bottom: y + hk_card_h - s(6),
                },
                color: palette.emerald,
                font_kind: FontKind::Meta,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
        }
    }
    y += hk_card_h + s(10);

    // 区块 2：苹果官方风格液态玻璃背景模糊浓度单轴滑块 + 预设档位 + 历史容量上限
    let seg_card_h = s(128);
    if in_viewport(y, seg_card_h) {
        canvas.fill_round_rect(pad, y, content_w, seg_card_h, sf(14.0), palette.card_bg);
        canvas.stroke_round_rect(
            pad,
            y,
            content_w,
            seg_card_h,
            sf(14.0),
            sf(1.0),
            palette.card_border,
        );

        let pct = st.store.config.blur_concentration_pct;
        texts.push(TextDrawCmd {
            text: "液态玻璃 · 背景模糊浓度".to_string(),
            rect: RECT {
                left: pad + s(12),
                top: y + s(8),
                right: w - pad - s(70),
                bottom: y + s(32),
            },
            color: palette.text_primary,
            font_kind: FontKind::CardTitle,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        });
        texts.push(TextDrawCmd {
            text: format!("{pct}%"),
            rect: RECT {
                left: w - pad - s(66),
                top: y + s(8),
                right: w - pad - s(14),
                bottom: y + s(32),
            },
            color: palette.text_secondary,
            font_kind: FontKind::Mono,
            flags: DT_RIGHT | DT_VCENTER | DT_SINGLELINE,
        });

        let sl_x = pad + s(14);
        let sl_w = content_w - s(28);
        let sl_y = y + s(36);
        let sl_h = s(24);
        canvas.draw_concentration_slider(sl_x, sl_y, sl_w, sl_h, pct, palette.cobalt);
        st.hit_regions.push(HitRegion {
            rect: RECT {
                left: sl_x,
                top: sl_y,
                right: sl_x + sl_w,
                bottom: sl_y + sl_h,
            },
            interactive_cursor: true,
            action: HitAction::AdjustBlurConcentration {
                track_left: sl_x,
                track_width: sl_w,
            },
        });

        let gx0 = pad + s(118);
        let gw_total = w - pad - s(10) - gx0;
        texts.push(TextDrawCmd {
            text: "保留上限".to_string(),
            rect: RECT {
                left: pad + s(12),
                top: y + s(74),
                right: pad + s(112),
                bottom: y + s(108),
            },
            color: palette.text_primary,
            font_kind: FontKind::Body,
            flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        });
        let caps = [100usize, 200, 500, 1000];
        let cw = (gw_total - s(12)) / 4;
        for (i, &cap) in caps.iter().enumerate() {
            let cx = gx0 + (i as i32) * (cw + s(4));
            let active = st.store.config.max_history_count == cap;
            canvas.fill_round_rect(
                cx,
                y + s(78),
                cw,
                s(26),
                sf(9.0),
                if active {
                    palette.cobalt
                } else {
                    palette.track_bg
                },
            );
            let rc = RECT {
                left: cx,
                top: y + s(78),
                right: cx + cw,
                bottom: y + s(104),
            };
            texts.push(TextDrawCmd {
                text: format!("{cap}"),
                rect: rc,
                color: if active {
                    Color4::rgb(255, 255, 255)
                } else {
                    palette.text_secondary
                },
                font_kind: FontKind::Mono,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            st.hit_regions.push(HitRegion {
                rect: rc,
                interactive_cursor: true,
                action: HitAction::SelectMaxHistory(cap),
            });
        }
    }
    y += seg_card_h + s(10);

    // 区块 3：10 项全量效率与净化拨动开关（1:1 同步 Mac 偏好设置）
    let toggles: [(&str, &str, bool, Color4, HitAction); 10] = [
        (
            "极简纯净模式 (Ctrl+E)",
            "仅保留纯粹复制检索与收藏，隐藏行业增强胶囊",
            st.store.config.minimal_mode_enabled,
            palette.emerald,
            HitAction::ToggleMinimalMode,
        ),
        (
            "窗口始终在前 (Ctrl+P)",
            "钉在桌面不自动收起，单击复制不跳序、双击键入",
            st.store.config.always_on_top,
            palette.cobalt,
            HitAction::ToggleAlwaysOnTop,
        ),
        (
            "选中后自动键入粘贴",
            "回车或双击卡片自动向目标窗口发送 Ctrl+V",
            st.store.config.auto_paste_enabled,
            palette.cobalt,
            HitAction::ToggleAutoPaste,
        ),
        (
            "跨处选段续接复制 (Ctrl+Alt+C)",
            "按下自动复制当前选段并换行追加至最新文本末尾",
            st.store.config.copy_append_enabled,
            palette.cobalt,
            HitAction::ToggleCopyAppend,
        ),
        (
            "双按 Ctrl+C×2 零离手智变",
            "连按两次复制自动触发首选净化或剥离网页脏样式",
            st.store.config.double_copy_spark_enabled,
            palette.cobalt,
            HitAction::ToggleDoubleCopySpark,
        ),
        (
            "自动剥离富文本脏样式",
            "过滤网页/文档背景字号，IDE 代码着色智能豁免",
            st.store.config.auto_strip_rich_formatting,
            palette.cobalt,
            HitAction::ToggleStripRichFormat,
        ),
        (
            "复制链接自动剥离追踪尾巴",
            "自动清除 utm_source / spm / fbclid 等营销参数",
            st.store.config.auto_clean_tracking_url,
            palette.cobalt,
            HitAction::ToggleAutoCleanUrl,
        ),
        (
            "验证码粘贴 30 秒无痕销毁",
            "短信/邮件一次性验证码使用后到期自动清理",
            st.store.config.auto_expire_otp,
            palette.cobalt,
            HitAction::ToggleAutoExpireOtp,
        ),
        (
            "FIFO 顺序复制连填队列",
            "复制项依次入队，按顺序出队热键逐格填表",
            st.store.queue_mode_active,
            palette.emerald,
            HitAction::ToggleQueueMode,
        ),
        (
            "开机自动静默启动",
            "随 Windows 登录驻留系统托盘（0.00% 待机 CPU）",
            st.autostart_cached,
            palette.cobalt,
            HitAction::ToggleAutostart,
        ),
    ];

    let row_h = s(46);
    for (title, sub, is_on, acc, act) in toggles {
        if in_viewport(y, row_h) {
            canvas.fill_round_rect(pad, y, content_w, row_h, sf(12.0), palette.card_bg);
            canvas.stroke_round_rect(
                pad,
                y,
                content_w,
                row_h,
                sf(12.0),
                sf(1.0),
                palette.card_border,
            );

            let sw_w = s(38);
            let sw_h = s(22);
            let sw_x = w - pad - s(12) - sw_w;
            let sw_y = y + (row_h - sw_h) / 2;
            canvas.draw_toggle_switch(sw_x, sw_y, sw_w, sw_h, is_on, acc);

            texts.push(TextDrawCmd {
                text: title.to_string(),
                rect: RECT {
                    left: pad + s(12),
                    top: y + s(5),
                    right: sw_x - s(10),
                    bottom: y + s(24),
                },
                color: palette.text_primary,
                font_kind: FontKind::CardTitle,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });
            texts.push(TextDrawCmd {
                text: sub.to_string(),
                rect: RECT {
                    left: pad + s(12),
                    top: y + s(24),
                    right: sw_x - s(10),
                    bottom: y + row_h - s(4),
                },
                color: palette.text_muted,
                font_kind: FontKind::Meta,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            });

            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: pad,
                    top: y,
                    right: w - pad,
                    bottom: y + row_h,
                },
                interactive_cursor: true,
                action: act,
            });
        }
        y += row_h + s(6);
    }

    // 队列出队后自动补 Tab 子开关
    if st.store.queue_mode_active {
        if in_viewport(y, s(38)) {
            canvas.fill_round_rect(pad, y, content_w, s(38), sf(11.0), palette.track_bg);
            let sw_w = s(36);
            let sw_h = s(20);
            let sw_x = w - pad - s(12) - sw_w;
            canvas.draw_toggle_switch(
                sw_x,
                y + s(9),
                sw_w,
                sw_h,
                st.store.config.queue_auto_tab,
                palette.emerald,
            );
            texts.push(TextDrawCmd {
                text: "顺序出队粘贴后自动敲击 Tab 跳下一格".to_string(),
                rect: RECT {
                    left: pad + s(12),
                    top: y,
                    right: sw_x - s(8),
                    bottom: y + s(38),
                },
                color: palette.text_secondary,
                font_kind: FontKind::Body,
                flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE,
            });
            st.hit_regions.push(HitRegion {
                rect: RECT {
                    left: pad,
                    top: y,
                    right: w - pad,
                    bottom: y + s(38),
                },
                interactive_cursor: true,
                action: HitAction::ToggleQueueAutoTab,
            });
        }
        y += s(44);
    }

    // 区块 4：跨平台 .iclip 资产导入导出与历史清理按钮组
    let btn_row_h = s(36);
    let half_w = (content_w - s(8)) / 2;
    if in_viewport(y, btn_row_h) {
        for (i, (label, act)) in [
            ("导出收藏 (.iclip)", HitAction::ExportArchive),
            ("导入合并 (.iclip · Mac互通)", HitAction::ImportArchive),
        ]
        .into_iter()
        .enumerate()
        {
            let bx = pad + (i as i32) * (half_w + s(8));
            canvas.fill_round_rect(bx, y, half_w, btn_row_h, sf(11.0), palette.search_bg);
            canvas.stroke_round_rect(
                bx,
                y,
                half_w,
                btn_row_h,
                sf(11.0),
                sf(1.0),
                palette.cobalt.with_alpha(110),
            );
            let rc = RECT {
                left: bx,
                top: y,
                right: bx + half_w,
                bottom: y + btn_row_h,
            };
            texts.push(TextDrawCmd {
                text: label.to_string(),
                rect: rc,
                color: Color4::rgb(164, 198, 255),
                font_kind: FontKind::BadgeBold,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            st.hit_regions.push(HitRegion {
                rect: rc,
                interactive_cursor: true,
                action: act,
            });
        }
    }
    y += btn_row_h + s(8);

    if in_viewport(y, btn_row_h) {
        let pause_txt = if st.store.is_paused {
            "恢复剪贴监听"
        } else {
            "暂停剪贴监听"
        };
        for (i, (label, is_danger, act)) in [
            (pause_txt, false, HitAction::TogglePauseCapture),
            ("清空未收藏历史", true, HitAction::ClearUnpinnedHistory),
        ]
        .into_iter()
        .enumerate()
        {
            let bx = pad + (i as i32) * (half_w + s(8));
            canvas.fill_round_rect(bx, y, half_w, btn_row_h, sf(11.0), palette.search_bg);
            canvas.stroke_round_rect(
                bx,
                y,
                half_w,
                btn_row_h,
                sf(11.0),
                sf(1.0),
                if is_danger {
                    palette.danger.with_alpha(120)
                } else {
                    palette.search_border
                },
            );
            let rc = RECT {
                left: bx,
                top: y,
                right: bx + half_w,
                bottom: y + btn_row_h,
            };
            texts.push(TextDrawCmd {
                text: label.to_string(),
                rect: rc,
                color: if is_danger {
                    Color4::rgb(255, 136, 144)
                } else {
                    palette.text_secondary
                },
                font_kind: FontKind::BadgeBold,
                flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            });
            st.hit_regions.push(HitRegion {
                rect: rc,
                interactive_cursor: true,
                action: act,
            });
        }
    }
    y += btn_row_h + s(14);

    let total_content_h = (y + st.settings_scroll_px) - view_top;
    let visible_h = (view_bottom - view_top).max(1);
    st.settings_max_scroll_px = (total_content_h - visible_h).max(0);

    // 设置页底栏提示
    let foot_top = h - s(30);
    canvas.draw_line(
        pad as f32,
        foot_top as f32,
        (w - pad) as f32,
        foot_top as f32,
        sf(1.0),
        palette.track_border,
    );
    let foot_msg = st
        .toast_message
        .clone()
        .unwrap_or_else(|| "滚轮浏览全部配置 · 按 Esc 或 Ctrl+, 返回剪贴面板".to_string());
    texts.push(TextDrawCmd {
        text: foot_msg,
        rect: RECT {
            left: pad,
            top: foot_top,
            right: w - pad,
            bottom: h - s(2),
        },
        color: if st.toast_message.is_some() {
            palette.emerald
        } else {
            palette.text_muted
        },
        font_kind: FontKind::Meta,
        flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
    });
}

// ============================================================================
// 原位速览 & 行级红绿 Diff 浮层（Space / Alt+Space）与内联备注编辑浮层（Ctrl+R）
// ============================================================================

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
    canvas.fill_round_rect(0, 0, w, h, sf(18.0), Color4::rgba(6, 10, 18, 212));

    let mx = s(16);
    let my = s(36);
    let mw = w - mx * 2;
    let mh = h - my * 2;
    canvas.fill_round_rect(mx, my, mw, mh, sf(16.0), Color4::rgb(17, 23, 38));
    canvas.stroke_round_rect(mx, my, mw, mh, sf(16.0), sf(1.0), palette.select_border);

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

    // 浮层顶栏：原文速览 / 差异比对切换胶囊 + 关闭按钮
    let tab_w = s(86);
    let tab_h = s(24);
    for (i, (lbl, is_diff)) in [("全文速览", false), ("差异比对", true)]
        .into_iter()
        .enumerate()
    {
        let tx = mx + s(12) + (i as i32) * (tab_w + s(6));
        let ty = my + s(10);
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
                palette.track_bg
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
    let cy = my + s(10);
    canvas.fill_round_rect(cx, cy, close_sz, close_sz, sf(12.0), palette.track_bg);
    canvas.draw_icon_close(
        (cx + close_sz / 2) as f32,
        (cy + close_sz / 2) as f32,
        sf(10.0),
        sf(1.6),
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

    let body_top = my + s(44);
    let body_bottom = my + mh - s(32);

    if st.quick_look_diff_mode {
        let cur_txt = item.text.as_deref().unwrap_or("");
        let older_txt = st
            .store
            .items
            .iter()
            .enumerate()
            .find(|(idx, it)| *idx != store_idx && it.text.is_some())
            .and_then(|(_, it)| it.text.as_deref())
            .unwrap_or("");
        let diff = compute_clipboard_diff(older_txt, cur_txt);

        texts.push(TextDrawCmd {
            text: format!("对比上一条文本记录：{}", diff.badge_title()),
            rect: RECT {
                left: mx + s(14),
                top: body_top,
                right: mx + mw - s(14),
                bottom: body_top + s(22),
            },
            color: palette.amber,
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
                    Some(Color4::rgba(16, 185, 129, 36)),
                    Color4::rgb(134, 239, 172),
                ),
                DiffLineKind::Removed => (
                    Some(Color4::rgba(225, 66, 78, 38)),
                    Color4::rgb(252, 165, 165),
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
        let joined = lines.join("\r\n");
        texts.push(TextDrawCmd {
            text: joined,
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

fn layout_and_draw_alias_editor_overlay(
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
    canvas.fill_round_rect(0, 0, w, h, sf(18.0), Color4::rgba(6, 10, 18, 198));

    let mw = w - s(40);
    let mh = s(134);
    let mx = s(20);
    let my = (h - mh) / 2 - s(20);
    canvas.fill_round_rect(mx, my, mw, mh, sf(16.0), Color4::rgb(20, 27, 44));
    canvas.stroke_round_rect(mx, my, mw, mh, sf(16.0), sf(1.0), palette.select_border);

    texts.push(TextDrawCmd {
        text: "设置卡片备注名称（非空备注自动开启收藏保护防误删）".to_string(),
        rect: RECT {
            left: mx + s(14),
            top: my + s(12),
            right: mx + mw - s(14),
            bottom: my + s(34),
        },
        color: palette.text_primary,
        font_kind: FontKind::CardTitle,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
    });

    let ib_y = my + s(42);
    let ib_h = s(36);
    canvas.fill_round_rect(
        mx + s(14),
        ib_y,
        mw - s(28),
        ib_h,
        sf(10.0),
        palette.track_bg,
    );
    canvas.stroke_round_rect(
        mx + s(14),
        ib_y,
        mw - s(28),
        ib_h,
        sf(10.0),
        sf(1.2),
        palette.cobalt,
    );
    texts.push(TextDrawCmd {
        text: if st.alias_draft.is_empty() {
            "输入如：总公司开票税号 / 顺丰收件地址...".to_string()
        } else {
            format!("{}|", st.alias_draft)
        },
        rect: RECT {
            left: mx + s(24),
            top: ib_y,
            right: mx + mw - s(24),
            bottom: ib_y + ib_h,
        },
        color: if st.alias_draft.is_empty() {
            palette.text_muted
        } else {
            Color4::rgb(255, 255, 255)
        },
        font_kind: FontKind::Body,
        flags: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
    });

    let btn_w = s(78);
    let btn_h = s(28);
    let save_x = mx + mw - s(14) - btn_w;
    let cancel_x = save_x - s(8) - btn_w;
    let by = my + mh - btn_h - s(12);

    canvas.fill_round_rect(cancel_x, by, btn_w, btn_h, sf(9.0), palette.track_bg);
    texts.push(TextDrawCmd {
        text: "取消 Esc".to_string(),
        rect: RECT {
            left: cancel_x,
            top: by,
            right: cancel_x + btn_w,
            bottom: by + btn_h,
        },
        color: palette.text_secondary,
        font_kind: FontKind::Meta,
        flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
    });
    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: cancel_x,
            top: by,
            right: cancel_x + btn_w,
            bottom: by + btn_h,
        },
        interactive_cursor: true,
        action: HitAction::CloseOverlay,
    });

    canvas.fill_round_rect(save_x, by, btn_w, btn_h, sf(9.0), palette.cobalt);
    texts.push(TextDrawCmd {
        text: "保存 Enter".to_string(),
        rect: RECT {
            left: save_x,
            top: by,
            right: save_x + btn_w,
            bottom: by + btn_h,
        },
        color: Color4::rgb(255, 255, 255),
        font_kind: FontKind::BadgeBold,
        flags: DT_CENTER | DT_VCENTER | DT_SINGLELINE,
    });
    st.hit_regions.push(HitRegion {
        rect: RECT {
            left: save_x,
            top: by,
            right: save_x + btn_w,
            bottom: by + btn_h,
        },
        interactive_cursor: true,
        action: HitAction::SaveAliasEdit,
    });
}

// ============================================================================
// 鼠标、手型光标、全键盘快捷键交互与系统托盘菜单
// ============================================================================

fn point_in_rect(x: i32, y: i32, r: &RECT) -> bool {
    x >= r.left && x < r.right && y >= r.top && y < r.bottom
}

unsafe fn handle_mouse_move(hwnd: HWND, x: i32, y: i32) {
    let mut changed = false;
    let mut use_hand = false;

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            for reg in &st.hit_regions {
                if point_in_rect(x, y, &reg.rect) {
                    use_hand = reg.interactive_cursor;
                    break;
                }
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
            let now_min = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut().unwrap();
                st.store.config.minimal_mode_enabled = !st.store.config.minimal_mode_enabled;
                st.store.save_config();
                st.store.config.minimal_mode_enabled
            });
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
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.selected_tab = tab;
                    st.selected_visible_pos = 0;
                    st.scroll_row_offset = 0;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
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
            commit_direct_text_paste(hwnd, &val, format!("已粘贴计算结果 {val}"));
        }
        HitAction::CommitQuickCapture => {
            commit_quick_capture_from_search(hwnd);
        }
        HitAction::CommitSuggestion(payload) => {
            let summary = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut().unwrap();
                st.search_query.clear();
                let s = st.store.adopt_user_suggestion(&payload);
                apply_dwm_glass_style(hwnd, st.store.config.glass_appearance);
                s
            });
            reload_global_hotkeys_and_hooks(hwnd);
            set_toast(hwnd, summary);
        }
        HitAction::SelectCard(vis_pos) => {
            let mut target_store_idx = None;
            let mut always_top = false;
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.selected_visible_pos = vis_pos;
                    always_top = st.store.config.always_on_top;
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
                } else if always_top {
                    // 始终在前模式：单击卡片直接复制进剪贴板且不跳序、不关窗
                    copy_only_item_in_place(hwnd, idx);
                } else {
                    let _ = InvalidateRect(hwnd, null(), FALSE);
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
        HitAction::DeleteItem(id) => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.delete_by_id(&id);
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::UndoDelete => {
            let restored = APP_STATE.with(|c| {
                c.borrow_mut()
                    .as_mut()
                    .and_then(|st| st.store.undo_last_delete(now_unix_secs()))
            });
            if let Some(n) = restored {
                set_toast(hwnd, format!("已原位恢复 {n} 条误删记录"));
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
                            Some("请按下组合键，或连按两次 Ctrl / Alt / Shift / Win".to_string());
                        st.double_tap_machine.reset();
                    }
                }
            });
            reload_global_hotkeys_and_hooks(hwnd);
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
        HitAction::ToggleQueueMode => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.queue_mode_active = !st.store.queue_mode_active;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
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
        HitAction::AdjustBlurConcentration {
            track_left,
            track_width,
        } => {
            let pct = (((x - track_left) as f32 / (track_width.max(1) as f32)) * 100.0)
                .round()
                .clamp(0.0, 100.0) as u8;
            let mapped_mode = if pct < 26 {
                GlassAppearance::Clear
            } else if pct >= 85 {
                GlassAppearance::Solid
            } else {
                GlassAppearance::Tinted
            };
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.config.blur_concentration_pct = pct;
                    st.store.config.glass_appearance = mapped_mode;
                    st.store.save_config();
                }
            });
            apply_dwm_glass_style(hwnd, mapped_mode);
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
                }
            });
            set_toast(
                hwnd,
                "已清空未收藏历史（8秒内可按 Ctrl+Z 恢复）".to_string(),
            );
        }
        HitAction::TogglePauseCapture => {
            let paused = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut().unwrap();
                st.store.is_paused = !st.store.is_paused;
                st.store.is_paused
            });
            set_toast(
                hwnd,
                if paused {
                    "已暂停后台剪贴板监听".to_string()
                } else {
                    "已恢复后台剪贴板监听".to_string()
                },
            );
        }
    }
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
            "已开启始终在前（单击卡片仅复制，双击键入）".to_string()
        } else {
            "已恢复自动收起浮窗模式".to_string()
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
        Some((id, intent.default_pin))
    });
    if let Some((_id, pinned)) = outcome {
        set_toast(
            hwnd,
            if pinned {
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
                "备注已保存，并自动点亮收藏保护防丢失".to_string()
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
    APP_STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            auto_paste = st.store.config.auto_paste_enabled;
            st.ignore_next_clipboard_seq = true;
            if let Some(it) = st.store.items.get(store_idx) {
                if let Some(f) = &it.image_file_name {
                    img_path = Some(st.store.images_dir.join(f));
                }
            }
        }
    });
    let Some(path) = img_path else { return };
    let Ok(raw_png) = std::fs::read(&path) else {
        return;
    };

    let transformed: Option<Vec<u8>> = if to_jpeg {
        compress_png_to_white_bg_jpeg(&raw_png, 82)
    } else {
        render_mockup_frame_png(&raw_png, 36).map(|(b, _, _)| b)
    };
    if let Some(bytes) = transformed {
        let _ = write_image_bytes_to_clipboard(hwnd, &bytes);
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

    // 1. 若当前处于快捷键录制态：拦截普通组合键并执行 5 层冲突校验
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
        // 纯修饰键按下交给 ll_kbd_proc 双击状态机处理
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

    // 2. 若处于 Ctrl+R 备注编辑浮层
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

    // 3. Esc 分层平滑退出（速览 -> 设置页 -> 清空搜索 -> 收起面板）
    if vk == VK_ESCAPE as u32 {
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
            if !st.search_query.is_empty() {
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

    // Ctrl + , (0xBC)：打开/关闭面板内嵌设置页
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

    // Ctrl + P (0x50)：一键切换窗口始终在前
    if ctrl_down && !alt_down && !shift_down && vk == 0x50 {
        toggle_always_on_top(hwnd);
        return;
    }

    // Ctrl + E (0x45)：一键切换极简纯净模式
    if ctrl_down && !alt_down && !shift_down && vk == 0x45 {
        let now_min = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut().unwrap();
            st.store.config.minimal_mode_enabled = !st.store.config.minimal_mode_enabled;
            st.store.save_config();
            st.store.config.minimal_mode_enabled
        });
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

    // Ctrl + Z (0x5A)：8 秒内原位恢复误删记录
    if ctrl_down && !alt_down && !shift_down && vk == 0x5A {
        let restored = APP_STATE.with(|c| {
            c.borrow_mut()
                .as_mut()
                .and_then(|st| st.store.undo_last_delete(now_unix_secs()))
        });
        if let Some(n) = restored {
            set_toast(hwnd, format!("已恢复 {n} 条误删记录"));
            return;
        }
    }

    // Alt + 1..6：直达切换 6 大分类标签
    if alt_down && !ctrl_down && (0x31..=0x36).contains(&vk) {
        let idx = (vk - 0x31) as usize;
        let tab = ClipFilterTab::ALL_TABS[idx];
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.view_mode = ActiveViewMode::MainList;
                st.selected_tab = tab;
                st.selected_visible_pos = 0;
                st.scroll_row_offset = 0;
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
        return;
    }

    // Ctrl + 1..9 / Shift+Ctrl+1..9 / Alt+Ctrl+1..9：一键顺位粘贴 / 首选净化粘贴
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
                        if let Some(raw) = &st.store.items[idx].text {
                            top_act = st
                                .store
                                .rank_actions_for_item(
                                    &st.store.items[idx],
                                    analyze_text_actions(raw, false),
                                )
                                .into_iter()
                                .next();
                        }
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

    // Ctrl + D (0x44)：切换收藏置顶
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

    // Ctrl + R (0x52)：打开内联备注命名浮层
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

    // Ctrl + O (0x4F)：直达打开链接或定位本地文件
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

    // Ctrl + K (0x4B)：加入/移出顺序粘贴队列
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

    // Space / Alt+Space：原位速览与行级红绿 Diff 比对（搜索框为空或按下 Alt 时触发）
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

    // 方向键（支持普通列表与 3 列图片宫格二维穿梭）
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
                let rows = build_display_rows(&filtered, &st.store.items);
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
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                let filtered = st.store.filtered_indices_ext(
                    st.selected_tab,
                    st.selected_pin_category,
                    &st.search_query,
                    st.active_target_app_name.as_deref(),
                );
                if let Some(&idx) = filtered.get(st.selected_visible_pos) {
                    let id = st.store.items[idx].id.clone();
                    st.store.delete_by_id(&id);
                }
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
        return;
    }

    if vk == VK_RETURN as u32 {
        // 优先处理搜索框三合一命令（@建议 / > 闪念速记 / 即时速算）
        let query_snapshot = APP_STATE.with(|c| {
            c.borrow()
                .as_ref()
                .map(|s| s.search_query.clone())
                .unwrap_or_default()
        });
        if let Some(sug) = extract_suggestion_payload(&query_snapshot) {
            let summary = APP_STATE.with(|c| {
                let mut b = c.borrow_mut();
                let st = b.as_mut().unwrap();
                st.search_query.clear();
                let s = st.store.adopt_user_suggestion(&sug);
                apply_dwm_glass_style(hwnd, st.store.config.glass_appearance);
                s
            });
            reload_global_hotkeys_and_hooks(hwnd);
            set_toast(hwnd, summary);
            return;
        }
        if parse_quick_capture(&query_snapshot).is_some() {
            commit_quick_capture_from_search(hwnd);
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
            commit_direct_text_paste(hwnd, &out, format!("已粘贴计算结果 {out}"));
            return;
        }

        let mut selected_store_idx = None;
        let mut first_quick_action = None;
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
                    if shift_down && !st.store.config.minimal_mode_enabled {
                        if let Some(raw) = &st.store.items[idx].text {
                            first_quick_action = st
                                .store
                                .rank_actions_for_item(
                                    &st.store.items[idx],
                                    analyze_text_actions(raw, false),
                                )
                                .into_iter()
                                .next();
                        }
                    }
                }
            }
        });
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
                        // 在空搜索框按空格键用于触发速览，不写入空白搜索词
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
    nid.hIcon = LoadIconW(null_mut(), IDI_APPLICATION);
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

    let (minimal, always_top, otp_exp, paused, pinned_cnt, queue_active, hk_disp) =
        APP_STATE.with(|c| {
            let b = c.borrow();
            let st = b.as_ref().unwrap();
            (
                st.store.config.minimal_mode_enabled,
                st.store.config.always_on_top,
                st.store.config.auto_expire_otp,
                st.store.is_paused,
                st.store.pinned_count(),
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
    AppendMenuW(
        hmenu,
        MF_STRING,
        CMD_OPEN_SETTINGS,
        to_wide("偏好设置与快捷键录制 (Ctrl+,)").as_ptr(),
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
    AppendMenuW(
        hmenu,
        MF_STRING,
        CMD_TOGGLE_PAUSE,
        to_wide(if paused {
            "恢复剪贴板记录"
        } else {
            "暂停剪贴板记录"
        })
        .as_ptr(),
    );
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
        CMD_TOGGLE_PAUSE => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.is_paused = !st.store.is_paused;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
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
        let res = APP_STATE.with(|c| {
            c.borrow()
                .as_ref()
                .unwrap()
                .store
                .export_archive_to_file(&dest)
        });
        show_panel_near_cursor(hwnd);
        match res {
            Ok(n) => set_toast(hwnd, format!("已成功导出 {n} 条收藏资产")),
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
    let filter: Vec<u16> = "iClip 归档包 (*.iclip)\0*.iclip\0JSON 文件 (*.json)\0*.json\0\0"
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
        let res = APP_STATE.with(|c| {
            c.borrow_mut()
                .as_mut()
                .unwrap()
                .store
                .import_archive_from_file(&src)
        });
        show_panel_near_cursor(hwnd);
        match res {
            Ok(s) => set_toast(
                hwnd,
                format!(
                    "导入新增 {} 条，合并更新 {} 条",
                    s.imported_new_count, s.updated_existing_count
                ),
            ),
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
            let quoted = format!("\"{}\"", exe_path.display());
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
