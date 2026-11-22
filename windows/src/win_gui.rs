#![cfg(target_os = "windows")]

use iclip_core::engines::{
    analyze_text_actions, clean_tracking_url, compress_png_to_white_bg_jpeg,
    render_dynamic_template, render_mockup_frame_png,
};
use iclip_core::model::{now_unix_secs, ClipContentType, ClipFilterTab, ClipItem, QuickAction};
use iclip_core::store::ClipboardStore;
use image::{codecs::png::PngEncoder, ColorType, ImageEncoder};
use std::cell::RefCell;
use std::ffi::OsString;
use std::mem::{size_of, zeroed};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::PathBuf;
use std::ptr::{null, null_mut};
use std::time::Instant;

use windows_sys::Win32::Foundation::{
    CloseHandle, FALSE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM,
};
use windows_sys::Win32::Graphics::Dwm::{
    DwmExtendFrameIntoClientArea, DwmSetWindowAttribute,
};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, CreateFontW, CreatePen,
    CreateRoundRectRgn, CreateSolidBrush, DeleteDC, DeleteObject, DrawTextW, EndPaint, FillRect,
    FillRgn, GetDC, InvalidateRect, MonitorFromPoint, GetMonitorInfoW, ReleaseDC, RoundRect,
    SelectObject, SetBkMode, SetTextColor, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CLEARTYPE_QUALITY,
    CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DIB_RGB_COLORS, DT_END_ELLIPSIS, DT_LEFT, DT_NOPREFIX,
    DT_SINGLELINE, DT_VCENTER, FW_BOLD, FW_MEDIUM, FW_NORMAL, HDC, MONITORINFO,
    MONITOR_DEFAULTTONEAREST, OUT_DEFAULT_PRECIS, PAINTSTRUCT, PS_SOLID, SRCCOPY, TRANSPARENT,
};
use windows_sys::Win32::System::DataExchange::{
    AddClipboardFormatListener, CloseClipboard, EmptyClipboard, GetClipboardData,
    IsClipboardFormatAvailable, OpenClipboard, RegisterClipboardFormatW,
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
use windows_sys::Win32::UI::Controls::Dialogs::{
    GetOpenFileNameW, GetSaveFileNameW, OFN_EXPLORER, OFN_FILEMUSTEXIST, OFN_NOCHANGEDIR,
    OFN_OVERWRITEPROMPT, OFN_PATHMUSTEXIST, OPENFILENAMEW,
};
use windows_sys::Win32::UI::Controls::MARGINS;
use windows_sys::Win32::UI::HiDpi::{
    GetDpiForWindow, SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    ReleaseCapture, SendInput, SetFocus, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT,
    KEYEVENTF_KEYUP, MOD_ALT, MOD_NOREPEAT, RegisterHotKey, UnregisterHotKey,
    VK_BACK, VK_CONTROL, VK_DELETE, VK_DOWN, VK_ESCAPE, VK_RETURN, VK_SHIFT, VK_TAB, VK_UP,
};
#[cfg(feature = "flow")]
use windows_sys::Win32::UI::Input::KeyboardAndMouse::MOD_CONTROL;
use windows_sys::Win32::UI::Shell::{
    DragQueryFileW, Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE,
    NOTIFYICONDATAW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

const WM_TRAYICON: u32 = WM_USER + 101;
const WM_CLIPBOARDUPDATE_MSG: u32 = 0x031D;

const HOTKEY_ID_TOGGLE: i32 = 1001;
const HOTKEY_ID_QUEUE_POP: i32 = 1002;
const TIMER_ID_OTP_SWEEP: usize = 2001;
const TIMER_ID_TOAST_CLEAR: usize = 2002;

const CMD_OPEN_PANEL: usize = 3001;
const CMD_TOGGLE_MINIMAL: usize = 3002;
const CMD_TOGGLE_OTP_EXPIRE: usize = 3003;
const CMD_EXPORT_ARCHIVE: usize = 3004;
const CMD_IMPORT_ARCHIVE: usize = 3005;
const CMD_TOGGLE_PAUSE: usize = 3006;
const CMD_TOGGLE_AUTOSTART: usize = 3007;
const CMD_CLEAR_UNPINNED: usize = 3008;
const CMD_QUIT_APP: usize = 3009;
#[cfg(feature = "flow")]
const CMD_TOGGLE_QUEUE_MODE: usize = 3010;

const CF_UNICODETEXT_ID: u32 = 13;
const CF_DIB_ID: u32 = 8;
const CF_HDROP_ID: u32 = 15;

// DWM 属性常量（Windows 11 原生圆角与 Acrylic/Mica 背景）
const DWMWA_USE_IMMERSIVE_DARK_MODE_ATTR: u32 = 20;
const DWMWA_WINDOW_CORNER_PREFERENCE_ATTR: u32 = 33;
const DWMWA_SYSTEMBACKDROP_TYPE_ATTR: u32 = 38;
const DWMWCP_ROUND_VAL: u32 = 2;
const DWMSBT_TRANSIENTWINDOW_VAL: u32 = 3; // Acrylic 浮窗毛玻璃

#[derive(Clone)]
struct HitRegion {
    rect: RECT,
    action: HitAction,
}

#[derive(Clone)]
enum HitAction {
    ToggleMinimalMode,
    SelectTab(ClipFilterTab),
    SelectCard(usize),
    TriggerQuickAction { item_idx: usize, action: QuickAction },
    CompressImageJpeg(usize),
    MockupImagePng(usize),
    TogglePin(String),
    DeleteItem(String),
}

struct WinAppState {
    store: ClipboardStore,
    visible: bool,
    previous_foreground: HWND,
    ignore_next_clipboard_seq: bool,
    selected_tab: ClipFilterTab,
    search_query: String,
    selected_visible_pos: usize,
    scroll_offset: usize,
    hovered_visible_pos: Option<usize>,
    toast_message: Option<String>,
    hit_regions: Vec<HitRegion>,
    cf_html_format: u32,
    cf_exclude_monitor: u32,
    cf_viewer_ignore: u32,
    suppress_deactivate_hide: bool,
}

thread_local! {
    static APP_STATE: RefCell<Option<WinAppState>> = const { RefCell::new(None) };
}

fn to_wide(s: &str) -> Vec<u16> {
    OsString::from(s).encode_wide().chain(std::iter::once(0)).collect()
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
            430,
            570,
            null_mut(),
            null_mut(),
            hinstance,
            null(),
        );
        if hwnd.is_null() {
            return 1;
        }

        apply_dwm_glass_style(hwnd);

        let cf_html = RegisterClipboardFormatW(to_wide("HTML Format").as_ptr());
        let cf_excl = RegisterClipboardFormatW(
            to_wide("ExcludeClipboardContentFromMonitorProcessing").as_ptr(),
        );
        let cf_ignore = RegisterClipboardFormatW(to_wide("Clipboard Viewer Ignore").as_ptr());

        let store = ClipboardStore::new(ClipboardStore::default_app_data_dir());
        APP_STATE.with(|cell| {
            *cell.borrow_mut() = Some(WinAppState {
                store,
                visible: false,
                previous_foreground: null_mut(),
                ignore_next_clipboard_seq: false,
                selected_tab: ClipFilterTab::All,
                search_query: String::new(),
                selected_visible_pos: 0,
                scroll_offset: 0,
                hovered_visible_pos: None,
                toast_message: None,
                hit_regions: Vec::new(),
                cf_html_format: cf_html,
                cf_exclude_monitor: cf_excl,
                cf_viewer_ignore: cf_ignore,
                suppress_deactivate_hide: false,
            });
        });

        // 零轮询系统级剪贴板监听（后台 0.00% CPU 开销）
        let _ = AddClipboardFormatListener(hwnd);

        // 全局呼出热键：Alt + V (0x56)
        let _ = RegisterHotKey(hwnd, HOTKEY_ID_TOGGLE, MOD_ALT | MOD_NOREPEAT, 0x56);
        // 心流办公版额外注册免开面板顺序出队热键：Ctrl + Alt + V
        #[cfg(feature = "flow")]
        {
            let _ = RegisterHotKey(
                hwnd,
                HOTKEY_ID_QUEUE_POP,
                MOD_CONTROL | MOD_ALT | MOD_NOREPEAT,
                0x56,
            );
        }

        // 低频 5 秒定时器仅用于扫描 OTP 阅后即焚到期项
        SetTimer(hwnd, TIMER_ID_OTP_SWEEP, 5_000, None);
        install_tray_icon(hwnd);

        // 首次启动时优雅展示面板让用户确认已就绪
        show_panel_near_cursor(hwnd);

        let mut msg: MSG = zeroed();
        while GetMessageW(&mut msg, null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        remove_tray_icon(hwnd);
        let _ = UnregisterHotKey(hwnd, HOTKEY_ID_TOGGLE);
        #[cfg(feature = "flow")]
        let _ = UnregisterHotKey(hwnd, HOTKEY_ID_QUEUE_POP);
        let _ = RemoveClipboardFormatListener(hwnd);
        0
    }
}

/// 在真实 Windows 系统（如 CI / 本地）上执行完整的 Win32 窗口、离屏 GDI 渲染与剪贴板双协议回环自检
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
            430,
            570,
            null_mut(),
            null_mut(),
            hinstance,
            null(),
        );
        if hwnd.is_null() {
            return Err("CreateWindowExW failed".to_string());
        }
        apply_dwm_glass_style(hwnd);

        if AddClipboardFormatListener(hwnd) == FALSE {
            DestroyWindow(hwnd);
            return Err("AddClipboardFormatListener failed".to_string());
        }

        let tmp_dir = std::env::temp_dir().join(format!("iclip-selftest-{}", now_unix_secs()));
        let mut store = ClipboardStore::new(tmp_dir.clone());
        store.insert_or_promote(ClipItem::new_text(
            "¥128,560.50".to_string(),
            Some("Excel".to_string()),
        ));
        store.insert_or_promote(ClipItem::new_text(
            "| 指标 | 数值 |\n| --- | --- |\n| 体积 | 850KB |".to_string(),
            Some("Cursor".to_string()),
        ));

        let cf_html = RegisterClipboardFormatW(to_wide("HTML Format").as_ptr());
        let mut state = WinAppState {
            store,
            visible: true,
            previous_foreground: null_mut(),
            ignore_next_clipboard_seq: false,
            selected_tab: ClipFilterTab::All,
            search_query: String::new(),
            selected_visible_pos: 0,
            scroll_offset: 0,
            hovered_visible_pos: Some(0),
            toast_message: Some("自检渲染正常".to_string()),
            hit_regions: Vec::new(),
            cf_html_format: cf_html,
            cf_exclude_monitor: 0,
            cf_viewer_ignore: 0,
            suppress_deactivate_hide: true,
        };

        // 1. 验证离屏双缓冲 GDI 绘制 430x570 帧无崩溃且命中热区正常生成
        let screen_dc = GetDC(hwnd);
        let mem_dc = CreateCompatibleDC(screen_dc);
        let bmp = CreateCompatibleBitmap(screen_dc, 430, 570);
        let old_bmp = SelectObject(mem_dc, bmp);
        render_panel_frame(mem_dc, 430, 570, 1.0, &mut state);
        SelectObject(mem_dc, old_bmp);
        DeleteObject(bmp);
        DeleteDC(mem_dc);
        ReleaseDC(hwnd, screen_dc);

        if state.hit_regions.len() < 6 {
            let _ = RemoveClipboardFormatListener(hwnd);
            DestroyWindow(hwnd);
            let _ = std::fs::remove_dir_all(&tmp_dir);
            return Err(format!(
                "Expected UI hit regions >= 6, got {}",
                state.hit_regions.len()
            ));
        }

        // 2. 验证真实 Win32 剪贴板写入与回读（UTF-16 文本 + CF_HTML 双协议）
        let test_marker = "iClip-Win32-Roundtrip-测试通过-2026";
        let html_payload = iclip_core::engines::build_windows_cf_html_payload("<table><tr><td>OK</td></tr></table>");
        // CI 环境中剪贴板偶发被其他进程短暂占用，最多重试 5 次
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
            return Err("Win32 clipboard UTF-16 + CF_HTML roundtrip verification failed".to_string());
        }

        let elapsed_ms = t0.elapsed().as_secs_f64() * 1000.0;
        println!(
            "{{\"status\":\"PASS\",\"edition\":\"{}\",\"version\":\"{}\",\"hit_regions\":{},\"startup_and_render_ms\":{:.2}}}",
            ClipboardStore::edition_key(),
            env!("CARGO_PKG_VERSION"),
            state.hit_regions.len(),
            elapsed_ms
        );
        Ok(())
    }
}

unsafe fn apply_dwm_glass_style(hwnd: HWND) {
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
    let backdrop: u32 = DWMSBT_TRANSIENTWINDOW_VAL;
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

unsafe fn show_panel_near_cursor(hwnd: HWND) {
    let prev_fg = GetForegroundWindow();
    let scale = get_dpi_scale(hwnd);
    let win_w = (430.0 * scale).round() as i32;
    let win_h = (570.0 * scale).round() as i32;

    let mut pt = POINT { x: 200, y: 200 };
    let _ = GetCursorPos(&mut pt);
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

    let gap = (14.0 * scale).round() as i32;
    let mut x = if pt.x + gap + win_w <= work_r - 10 {
        pt.x + gap
    } else {
        pt.x - gap - win_w
    };
    x = x.clamp(work_l + 10, (work_r - win_w - 10).max(work_l + 10));
    let mut y = pt.y - (48.0 * scale).round() as i32;
    y = y.clamp(work_t + 10, (work_b - win_h - 10).max(work_t + 10));

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            if prev_fg != hwnd && !prev_fg.is_null() {
                st.previous_foreground = prev_fg;
            }
            st.visible = true;
            st.search_query.clear();
            st.selected_visible_pos = 0;
            st.scroll_offset = 0;
        }
    });

    SetWindowPos(
        hwnd,
        HWND_TOPMOST,
        x,
        y,
        win_w,
        win_h,
        SWP_SHOWWINDOW,
    );
    let _ = SetForegroundWindow(hwnd);
    let _ = SetFocus(hwnd);
    let _ = InvalidateRect(hwnd, null(), FALSE);
}

unsafe fn hide_panel(hwnd: HWND, restore_focus: bool) {
    let mut target_fg: HWND = null_mut();
    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            st.visible = false;
            st.hovered_visible_pos = None;
            if restore_focus {
                target_fg = st.previous_foreground;
            }
        }
    });
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
    SetTimer(hwnd, TIMER_ID_TOAST_CLEAR, 1_800, None);
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
        WM_HOTKEY => {
            let id = wparam as i32;
            if id == HOTKEY_ID_TOGGLE {
                let is_vis = APP_STATE.with(|c| c.borrow().as_ref().map(|s| s.visible).unwrap_or(false));
                if is_vis {
                    hide_panel(hwnd, true);
                } else {
                    show_panel_near_cursor(hwnd);
                }
            } else if id == HOTKEY_ID_QUEUE_POP {
                handle_queue_pop_shortcut(hwnd);
            }
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
            }
            0
        }
        WM_ACTIVATE => {
            let active_state = (wparam & 0xFFFF) as u32;
            if active_state == WA_INACTIVE {
                let suppress = APP_STATE
                    .with(|c| c.borrow().as_ref().map(|s| s.suppress_deactivate_hide).unwrap_or(false));
                if !suppress {
                    hide_panel(hwnd, false);
                }
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
            let mem_bmp = CreateCompatibleBitmap(hdc, w, h);
            let old_bmp = SelectObject(mem_dc, mem_bmp);

            APP_STATE.with(|cell| {
                if let Some(st) = cell.borrow_mut().as_mut() {
                    render_panel_frame(mem_dc, w, h, scale, st);
                }
            });

            let _ = BitBlt(hdc, 0, 0, w, h, mem_dc, 0, 0, SRCCOPY);
            SelectObject(mem_dc, old_bmp);
            DeleteObject(mem_bmp);
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
                    let filtered_len = st
                        .store
                        .filtered_indices(st.selected_tab, &st.search_query)
                        .len();
                    if delta < 0 && st.scroll_offset + 5 < filtered_len {
                        st.scroll_offset += 1;
                    } else if delta > 0 && st.scroll_offset > 0 {
                        st.scroll_offset -= 1;
                    }
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
            0
        }
        WM_KEYDOWN => {
            handle_key_down(hwnd, wparam as u16);
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
// 零轮询剪贴板捕获、多协议写回与模拟粘贴
// ============================================================================

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
            return true;
        }
        if (st.cf_exclude_monitor != 0 && IsClipboardFormatAvailable(st.cf_exclude_monitor) != FALSE)
            || (st.cf_viewer_ignore != 0 && IsClipboardFormatAvailable(st.cf_viewer_ignore) != FALSE)
        {
            return true;
        }
        false
    });
    if should_skip {
        return;
    }

    // 1. 文件列表 CF_HDROP
    if IsClipboardFormatAvailable(CF_HDROP_ID) != FALSE {
        if let Some(paths) = read_files_from_clipboard(hwnd) {
            if !paths.is_empty() {
                APP_STATE.with(|cell| {
                    if let Some(st) = cell.borrow_mut().as_mut() {
                        st.store
                            .insert_or_promote(ClipItem::new_files(paths, Some("资源管理器".to_string())));
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
                let mut cleaned_for_pb: Option<String> = None;
                APP_STATE.with(|cell| {
                    if let Some(st) = cell.borrow_mut().as_mut() {
                        if !st.store.config.minimal_mode_enabled && st.store.config.auto_clean_tracking_url {
                            if let Some(clean) = clean_tracking_url(raw_text.trim()) {
                                raw_text = clean.clone();
                                cleaned_for_pb = Some(clean);
                            }
                        }
                        st.store.insert_or_promote(ClipItem::new_text(raw_text, None));
                    }
                });
                if let Some(clean) = cleaned_for_pb {
                    APP_STATE.with(|c| {
                        if let Some(st) = c.borrow_mut().as_mut() {
                            st.ignore_next_clipboard_seq = true;
                        }
                    });
                    let _ = write_text_and_html_to_clipboard(hwnd, &clean, None);
                }
                let _ = InvalidateRect(hwnd, null(), FALSE);
                return;
            }
        }
    }

    // 3. 位图截图 CF_DIB
    if IsClipboardFormatAvailable(CF_DIB_ID) != FALSE {
        if let Some((png_bytes, w, h)) = read_dib_as_png_from_clipboard(hwnd) {
            APP_STATE.with(|cell| {
                if let Some(st) = cell.borrow_mut().as_mut() {
                    let hash = iclip_core::model::sha256_hex(&png_bytes);
                    let file_name = format!("{}.png", &hash[0..24]);
                    let full_path = st.store.images_dir.join(&file_name);
                    if std::fs::write(&full_path, &png_bytes).is_ok() {
                        st.store.insert_or_promote(ClipItem::new_image(
                            file_name,
                            w,
                            h,
                            &png_bytes,
                            Some("截图".to_string()),
                        ));
                    }
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
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
            hdr.biHeight = h as i32; // bottom-up DIB
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

unsafe fn commit_paste_item_by_index(hwnd: HWND, item_idx: usize) {
    let mut auto_paste = true;
    let mut text_to_write: Option<String> = None;
    let mut image_path_to_write: Option<PathBuf> = None;
    let mut item_id_for_otp: Option<String> = None;

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            auto_paste = st.store.config.auto_paste_enabled;
            st.ignore_next_clipboard_seq = true;
            if let Some(item) = st.store.items.get(item_idx).cloned() {
                item_id_for_otp = Some(item.id.clone());
                match item.kind {
                    ClipContentType::Text | ClipContentType::Link => {
                        if let Some(raw) = &item.text {
                            if !st.store.config.minimal_mode_enabled
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

    hide_panel(hwnd, true);
    if auto_paste {
        std::thread::sleep(std::time::Duration::from_millis(35));
        simulate_ctrl_v(false);
    }
}

unsafe fn commit_quick_action(hwnd: HWND, item_idx: usize, action: &QuickAction) {
    let mut auto_paste = true;
    let mut cf_html_id = 0u32;
    let mut item_id: Option<String> = None;

    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
            auto_paste = st.store.config.auto_paste_enabled;
            cf_html_id = st.cf_html_format;
            st.ignore_next_clipboard_seq = true;
            if let Some(it) = st.store.items.get(item_idx) {
                item_id = Some(it.id.clone());
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

    hide_panel(hwnd, true);
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
    hide_panel(hwnd, true);

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
// 双缓冲高 DPI 原生视觉渲染（遵循 Impeccable 克制高对比美学，无廉价装饰）
// ============================================================================

const fn rgb(r: u8, g: u8, b: u8) -> u32 {
    (r as u32) | ((g as u32) << 8) | ((b as u32) << 16)
}

unsafe fn fill_round_rect(hdc: HDC, rc: &RECT, radius: i32, fill_color: u32, border_color: Option<u32>) {
    let rgn = CreateRoundRectRgn(rc.left, rc.top, rc.right, rc.bottom, radius, radius);
    let brush = CreateSolidBrush(fill_color);
    let _ = FillRgn(hdc, rgn, brush);
    DeleteObject(brush);
    DeleteObject(rgn);

    if let Some(bc) = border_color {
        let pen = CreatePen(PS_SOLID, 1, bc);
        let null_brush = windows_sys::Win32::Graphics::Gdi::GetStockObject(
            windows_sys::Win32::Graphics::Gdi::NULL_BRUSH,
        );
        let old_p = SelectObject(hdc, pen);
        let old_b = SelectObject(hdc, null_brush);
        let _ = RoundRect(hdc, rc.left, rc.top, rc.right, rc.bottom, radius, radius);
        SelectObject(hdc, old_p);
        SelectObject(hdc, old_b);
        DeleteObject(pen);
    }
}

unsafe fn make_font(px: i32, weight: i32) -> *mut core::ffi::c_void {
    let face = to_wide("Microsoft YaHei UI");
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

unsafe fn draw_label(hdc: HDC, text: &str, rc: &RECT, color: u32, flags: u32) {
    SetTextColor(hdc, color);
    let mut wide = to_wide(text);
    let mut r = *rc;
    let _ = DrawTextW(
        hdc,
        wide.as_mut_ptr(),
        (wide.len().saturating_sub(1)) as i32,
        &mut r,
        flags | DT_NOPREFIX,
    );
}

unsafe fn render_panel_frame(hdc: HDC, w: i32, h: i32, scale: f32, st: &mut WinAppState) {
    st.hit_regions.clear();
    let s = |v: i32| ((v as f32) * scale).round() as i32;

    // 1. 深邃云母石英底色（兼容 Win11 Acrylic 透射与 Win10 独立绘制）
    let full_rc = RECT { left: 0, top: 0, right: w, bottom: h };
    let bg_brush = CreateSolidBrush(rgb(20, 23, 31));
    let _ = FillRect(hdc, &full_rc, bg_brush);
    DeleteObject(bg_brush);

    SetBkMode(hdc, TRANSPARENT as i32);
    let font_title = make_font(s(14), FW_MEDIUM as i32);
    let font_sub = make_font(s(11), FW_NORMAL as i32);
    let font_badge = make_font(s(11), FW_BOLD as i32);

    let pad = s(14);
    let minimal = st.store.config.minimal_mode_enabled;

    // 2. 顶部搜索框 + 极简纯净模式圆钮
    let min_btn_w = s(74);
    let search_rc = RECT {
        left: pad,
        top: pad,
        right: w - pad - min_btn_w - s(8),
        bottom: pad + s(34),
    };
    fill_round_rect(hdc, &search_rc, s(10), rgb(32, 36, 48), Some(rgb(54, 60, 78)));

    let old_font = SelectObject(hdc, font_title);
    let search_text_rc = RECT {
        left: search_rc.left + s(12),
        top: search_rc.top,
        right: search_rc.right - s(8),
        bottom: search_rc.bottom,
    };
    if st.search_query.is_empty() {
        draw_label(
            hdc,
            "搜索剪贴历史... (Alt+V)",
            &search_text_rc,
            rgb(132, 140, 160),
            DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        );
    } else {
        draw_label(
            hdc,
            &st.search_query,
            &search_text_rc,
            rgb(244, 246, 252),
            DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        );
    }

    let min_btn_rc = RECT {
        left: search_rc.right + s(8),
        top: pad,
        right: w - pad,
        bottom: pad + s(34),
    };
    let min_fill = if minimal { rgb(28, 138, 86) } else { rgb(34, 38, 50) };
    let min_border = if minimal { rgb(62, 198, 128) } else { rgb(56, 62, 80) };
    fill_round_rect(hdc, &min_btn_rc, s(10), min_fill, Some(min_border));
    SelectObject(hdc, font_badge);
    draw_label(
        hdc,
        if minimal { "极简开" } else { "极简 Ctrl+E" },
        &RECT {
            left: min_btn_rc.left + s(6),
            top: min_btn_rc.top,
            right: min_btn_rc.right - s(4),
            bottom: min_btn_rc.bottom,
        },
        if minimal { rgb(255, 255, 255) } else { rgb(176, 184, 204) },
        DT_LEFT | DT_VCENTER | DT_SINGLELINE,
    );
    st.hit_regions.push(HitRegion {
        rect: min_btn_rc,
        action: HitAction::ToggleMinimalMode,
    });

    // 3. 6 大分类筛选胶囊条
    let tab_top = search_rc.bottom + s(10);
    let tab_h = s(26);
    let tab_gap = s(6);
    let tab_w = (w - pad * 2 - tab_gap * 5) / 6;
    for (idx, tab) in ClipFilterTab::ALL_TABS.iter().enumerate() {
        let left = pad + idx as i32 * (tab_w + tab_gap);
        let rc = RECT {
            left,
            top: tab_top,
            right: left + tab_w,
            bottom: tab_top + tab_h,
        };
        let active = st.selected_tab == *tab;
        fill_round_rect(
            hdc,
            &rc,
            s(13),
            if active { rgb(59, 118, 246) } else { rgb(30, 34, 45) },
            None,
        );
        SelectObject(hdc, if active { font_badge } else { font_sub });
        draw_label(
            hdc,
            tab.title(),
            &RECT {
                left: rc.left + s(10),
                top: rc.top,
                right: rc.right,
                bottom: rc.bottom,
            },
            if active { rgb(255, 255, 255) } else { rgb(168, 176, 196) },
            DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        );
        st.hit_regions.push(HitRegion {
            rect: rc,
            action: HitAction::SelectTab(*tab),
        });
    }

    // 4. 卡片列表区域
    let filtered = st.store.filtered_indices(st.selected_tab, &st.search_query);
    if st.selected_visible_pos >= filtered.len() {
        st.selected_visible_pos = filtered.len().saturating_sub(1);
    }

    let mut cur_y = tab_top + tab_h + s(10);
    let footer_h = s(30);
    let max_list_bottom = h - footer_h - s(6);

    if filtered.is_empty() {
        SelectObject(hdc, font_title);
        draw_label(
            hdc,
            "暂无匹配记录 · 复制任意文本、表格或截图即可自动归档",
            &RECT {
                left: pad + s(8),
                top: cur_y + s(60),
                right: w - pad,
                bottom: cur_y + s(110),
            },
            rgb(126, 134, 156),
            DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
        );
    } else {
        for vis_pos in st.scroll_offset..filtered.len() {
            let store_idx = filtered[vis_pos];
            let item = st.store.items[store_idx].clone();
            let is_selected = vis_pos == st.selected_visible_pos;
            let is_hovered = st.hovered_visible_pos == Some(vis_pos);

            let quick_actions = if !minimal && is_selected {
                if let Some(raw) = &item.text {
                    analyze_text_actions(raw, false)
                } else {
                    Vec::new()
                }
            } else {
                Vec::new()
            };
            let has_image_chips = !minimal && is_selected && item.kind == ClipContentType::Image;

            let card_h = if !quick_actions.is_empty() || has_image_chips {
                s(88)
            } else {
                s(60)
            };
            if cur_y + card_h > max_list_bottom {
                break;
            }

            let card_rc = RECT {
                left: pad,
                top: cur_y,
                right: w - pad,
                bottom: cur_y + card_h,
            };
            let card_fill = if is_selected {
                rgb(46, 98, 226)
            } else if item.is_pinned {
                if is_hovered { rgb(66, 52, 30) } else { rgb(54, 42, 24) }
            } else if is_hovered {
                rgb(36, 41, 56)
            } else {
                rgb(28, 32, 44)
            };
            let card_border = if is_selected {
                Some(rgb(96, 148, 255))
            } else if item.is_pinned {
                Some(rgb(214, 142, 42))
            } else {
                Some(rgb(44, 50, 66))
            };
            fill_round_rect(hdc, &card_rc, s(12), card_fill, card_border);

            // 主标题与快捷键徽标
            SelectObject(hdc, font_title);
            let title_str = item.primary_title(minimal);
            let title_rc = RECT {
                left: card_rc.left + s(12),
                top: card_rc.top + s(7),
                right: card_rc.right - s(64),
                bottom: card_rc.top + s(29),
            };
            draw_label(
                hdc,
                &title_str,
                &title_rc,
                if is_selected { rgb(255, 255, 255) } else { rgb(236, 240, 248) },
                DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            );

            // 右上角固定与删除快捷圆钮 + Ctrl+1..9 徽标
            let pin_rc = RECT {
                left: card_rc.right - s(54),
                top: card_rc.top + s(7),
                right: card_rc.right - s(32),
                bottom: card_rc.top + s(27),
            };
            let del_rc = RECT {
                left: card_rc.right - s(28),
                top: card_rc.top + s(7),
                right: card_rc.right - s(8),
                bottom: card_rc.top + s(27),
            };
            if is_selected || is_hovered {
                fill_round_rect(
                    hdc,
                    &pin_rc,
                    s(6),
                    if item.is_pinned { rgb(196, 118, 24) } else { rgb(46, 54, 74) },
                    None,
                );
                SelectObject(hdc, font_sub);
                draw_label(
                    hdc,
                    if item.is_pinned { "★" } else { "☆" },
                    &pin_rc,
                    rgb(255, 255, 255),
                    DT_LEFT | DT_VCENTER | DT_SINGLELINE,
                );
                st.hit_regions.push(HitRegion {
                    rect: pin_rc,
                    action: HitAction::TogglePin(item.id.clone()),
                });

                fill_round_rect(hdc, &del_rc, s(6), rgb(168, 48, 56), None);
                draw_label(
                    hdc,
                    "删",
                    &del_rc,
                    rgb(255, 255, 255),
                    DT_LEFT | DT_VCENTER | DT_SINGLELINE,
                );
                st.hit_regions.push(HitRegion {
                    rect: del_rc,
                    action: HitAction::DeleteItem(item.id.clone()),
                });
            } else if vis_pos < 9 {
                SelectObject(hdc, font_sub);
                let badge = format!("Ctrl+{}", vis_pos + 1);
                draw_label(
                    hdc,
                    &badge,
                    &RECT {
                        left: card_rc.right - s(58),
                        top: card_rc.top + s(8),
                        right: card_rc.right - s(8),
                        bottom: card_rc.top + s(26),
                    },
                    rgb(132, 142, 166),
                    DT_LEFT | DT_VCENTER | DT_SINGLELINE,
                );
            }

            // 副标题与收藏标识
            SelectObject(hdc, font_sub);
            let mut sub_line = String::new();
            if item.is_pinned {
                sub_line.push_str("★ ");
            }
            if !minimal {
                if let Some(cat) = item.pin_category {
                    sub_line.push_str(cat.title());
                    sub_line.push_str(" · ");
                }
            }
            sub_line.push_str(&item.subtitle_info());
            if let Some(app) = &item.source_app_name {
                sub_line.push_str(" · ");
                sub_line.push_str(app);
            }
            draw_label(
                hdc,
                &sub_line,
                &RECT {
                    left: card_rc.left + s(12),
                    top: card_rc.top + s(30),
                    right: card_rc.right - s(12),
                    bottom: card_rc.top + s(50),
                },
                if is_selected { rgb(214, 228, 255) } else { rgb(142, 150, 172) },
                DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
            );

            // 选中卡片底部的智能变换动作胶囊条（需优先于整卡点击命中）
            let mut chip_x = card_rc.left + s(12);
            let chip_top = card_rc.top + s(55);
            let chip_bottom = card_rc.top + s(80);

            if has_image_chips {
                for (label, is_jpeg) in [("轻量瘦身 JPEG", true), ("圆角阴影样机图", false)] {
                    let cw = s(108);
                    let crc = RECT {
                        left: chip_x,
                        top: chip_top,
                        right: chip_x + cw,
                        bottom: chip_bottom,
                    };
                    fill_round_rect(hdc, &crc, s(11), rgb(26, 62, 158), Some(rgb(122, 168, 255)));
                    SelectObject(hdc, font_badge);
                    draw_label(
                        hdc,
                        label,
                        &RECT {
                            left: crc.left + s(8),
                            top: crc.top,
                            right: crc.right - s(4),
                            bottom: crc.bottom,
                        },
                        rgb(255, 255, 255),
                        DT_LEFT | DT_VCENTER | DT_SINGLELINE,
                    );
                    st.hit_regions.push(HitRegion {
                        rect: crc,
                        action: if is_jpeg {
                            HitAction::CompressImageJpeg(store_idx)
                        } else {
                            HitAction::MockupImagePng(store_idx)
                        },
                    });
                    chip_x += cw + s(8);
                }
            } else {
                for (a_idx, act) in quick_actions.iter().enumerate() {
                    let char_len = act.title.chars().count().min(18) as i32;
                    let cw = (char_len * s(11) + s(26)).min(card_rc.right - chip_x - s(10));
                    if cw < s(54) {
                        break;
                    }
                    let crc = RECT {
                        left: chip_x,
                        top: chip_top,
                        right: chip_x + cw,
                        bottom: chip_bottom,
                    };
                    let c_fill = if act.is_security {
                        rgb(168, 86, 22)
                    } else {
                        rgb(26, 62, 158)
                    };
                    fill_round_rect(hdc, &crc, s(11), c_fill, Some(rgb(130, 174, 255)));
                    SelectObject(hdc, font_badge);
                    let chip_text = if a_idx == 0 {
                        format!("{} ⇧↵", act.title)
                    } else {
                        act.title.clone()
                    };
                    draw_label(
                        hdc,
                        &chip_text,
                        &RECT {
                            left: crc.left + s(8),
                            top: crc.top,
                            right: crc.right - s(6),
                            bottom: crc.bottom,
                        },
                        rgb(255, 255, 255),
                        DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                    );
                    st.hit_regions.push(HitRegion {
                        rect: crc,
                        action: HitAction::TriggerQuickAction {
                            item_idx: store_idx,
                            action: act.clone(),
                        },
                    });
                    chip_x += cw + s(6);
                }
            }

            st.hit_regions.push(HitRegion {
                rect: card_rc,
                action: HitAction::SelectCard(vis_pos),
            });

            cur_y += card_h + s(8);
        }
    }

    // 5. 底部状态提示与角色标识栏
    SelectObject(hdc, font_sub);
    let footer_text = if let Some(toast) = &st.toast_message {
        toast.clone()
    } else {
        format!(
            "iClip v{} · {} · 双击/↵ 键入 · ⇧↵ 智能转换 · 托盘右键更多",
            env!("CARGO_PKG_VERSION"),
            ClipboardStore::edition_title()
        )
    };
    draw_label(
        hdc,
        &footer_text,
        &RECT {
            left: pad,
            top: h - footer_h,
            right: w - pad,
            bottom: h - s(6),
        },
        if st.toast_message.is_some() {
            rgb(94, 222, 154)
        } else {
            rgb(122, 130, 152)
        },
        DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
    );

    SelectObject(hdc, old_font);
    DeleteObject(font_title);
    DeleteObject(font_sub);
    DeleteObject(font_badge);
}

// ============================================================================
// 鼠标、键盘、系统托盘与原生 .iclip 导入导出对话框
// ============================================================================

fn point_in_rect(x: i32, y: i32, r: &RECT) -> bool {
    x >= r.left && x < r.right && y >= r.top && y < r.bottom
}

unsafe fn handle_mouse_move(hwnd: HWND, x: i32, y: i32) {
    let mut changed = false;
    APP_STATE.with(|cell| {
        if let Some(st) = cell.borrow_mut().as_mut() {
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
        // 点击空白顶栏区域支持拖拽移动悬浮窗
        if y < 48 && !is_double {
            let _ = ReleaseCapture();
            SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION as usize, 0);
        }
        return;
    };

    match action {
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
                    "已开启极简纯净模式（基础功能版）".to_string()
                } else {
                    "已恢复行业进阶工具箱".to_string()
                },
            );
        }
        HitAction::SelectTab(tab) => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.selected_tab = tab;
                    st.selected_visible_pos = 0;
                    st.scroll_offset = 0;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        HitAction::SelectCard(vis_pos) => {
            let mut target_store_idx = None;
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.selected_visible_pos = vis_pos;
                    let filtered = st.store.filtered_indices(st.selected_tab, &st.search_query);
                    target_store_idx = filtered.get(vis_pos).copied();
                }
            });
            if is_double {
                if let Some(idx) = target_store_idx {
                    commit_paste_item_by_index(hwnd, idx);
                }
            } else {
                let _ = InvalidateRect(hwnd, null(), FALSE);
            }
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
    let Ok(raw_png) = std::fs::read(&path) else { return };

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

unsafe fn handle_key_down(hwnd: HWND, vk: u16) {
    let ctrl_down = (windows_sys::Win32::UI::Input::KeyboardAndMouse::GetKeyState(VK_CONTROL as i32) as u16 & 0x8000) != 0;
    let shift_down = (windows_sys::Win32::UI::Input::KeyboardAndMouse::GetKeyState(VK_SHIFT as i32) as u16 & 0x8000) != 0;

    if vk == VK_ESCAPE {
        hide_panel(hwnd, true);
        return;
    }

    // Ctrl + E (0x45)：一键切换极简纯净模式
    if ctrl_down && vk == 0x45 {
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
                "已开启极简纯净模式（基础功能版）".to_string()
            } else {
                "已恢复行业进阶功能".to_string()
            },
        );
        return;
    }

    // Ctrl + 1..9：一键盲贴前 9 条
    if ctrl_down && (0x31..=0x39).contains(&vk) {
        let pos = (vk - 0x31) as usize;
        let idx_opt = APP_STATE.with(|c| {
            let b = c.borrow();
            let st = b.as_ref()?;
            let filtered = st.store.filtered_indices(st.selected_tab, &st.search_query);
            filtered.get(pos).copied()
        });
        if let Some(idx) = idx_opt {
            commit_paste_item_by_index(hwnd, idx);
        }
        return;
    }

    // Ctrl + K (0x4B)：加入/移出顺序粘贴队列
    if ctrl_down && vk == 0x4B {
        let msg = APP_STATE.with(|c| {
            let mut b = c.borrow_mut();
            let st = b.as_mut()?;
            let filtered = st.store.filtered_indices(st.selected_tab, &st.search_query);
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

    if vk == VK_UP {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                if st.selected_visible_pos > 0 {
                    st.selected_visible_pos -= 1;
                    if st.selected_visible_pos < st.scroll_offset {
                        st.scroll_offset = st.selected_visible_pos;
                    }
                }
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
    } else if vk == VK_DOWN {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                let len = st
                    .store
                    .filtered_indices(st.selected_tab, &st.search_query)
                    .len();
                if st.selected_visible_pos + 1 < len {
                    st.selected_visible_pos += 1;
                    if st.selected_visible_pos >= st.scroll_offset + 5 {
                        st.scroll_offset = st.selected_visible_pos - 4;
                    }
                }
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
    } else if vk == VK_DELETE {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                let filtered = st.store.filtered_indices(st.selected_tab, &st.search_query);
                if let Some(&idx) = filtered.get(st.selected_visible_pos) {
                    let id = st.store.items[idx].id.clone();
                    st.store.delete_by_id(&id);
                }
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
    } else if vk == VK_RETURN {
        let mut selected_store_idx = None;
        let mut first_quick_action = None;
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow().as_ref() {
                let filtered = st.store.filtered_indices(st.selected_tab, &st.search_query);
                if let Some(&idx) = filtered.get(st.selected_visible_pos) {
                    selected_store_idx = Some(idx);
                    if shift_down && !st.store.config.minimal_mode_enabled {
                        if let Some(raw) = &st.store.items[idx].text {
                            first_quick_action = analyze_text_actions(raw, false).into_iter().next();
                        }
                    }
                }
            }
        });
        if let (Some(idx), Some(act)) = (selected_store_idx, first_quick_action) {
            commit_quick_action(hwnd, idx, &act);
        } else if let Some(idx) = selected_store_idx {
            commit_paste_item_by_index(hwnd, idx);
        }
    }
}

unsafe fn handle_char_input(hwnd: HWND, ch_code: u32) {
    if ch_code == VK_BACK as u32 {
        APP_STATE.with(|c| {
            if let Some(st) = c.borrow_mut().as_mut() {
                st.search_query.pop();
                st.selected_visible_pos = 0;
                st.scroll_offset = 0;
            }
        });
        let _ = InvalidateRect(hwnd, null(), FALSE);
        return;
    }
    if ch_code >= 0x20 {
        if let Some(ch) = char::from_u32(ch_code) {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.search_query.push(ch);
                    st.selected_visible_pos = 0;
                    st.scroll_offset = 0;
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
    }
}

unsafe fn install_tray_icon(hwnd: HWND) {
    let mut nid: NOTIFYICONDATAW = zeroed();
    nid.cbSize = size_of::<NOTIFYICONDATAW>() as u32;
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_TRAYICON;
    nid.hIcon = LoadIconW(null_mut(), IDI_APPLICATION);
    let tip = to_wide(&format!(
        "iClip · {} (Alt+V 呼出)",
        ClipboardStore::edition_title()
    ));
    let copy_len = tip.len().min(nid.szTip.len());
    nid.szTip[..copy_len].copy_from_slice(&tip[..copy_len]);
    let _ = Shell_NotifyIconW(NIM_ADD, &nid);
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

    let (minimal, otp_exp, paused, pinned_cnt, queue_active) = APP_STATE.with(|c| {
        let b = c.borrow();
        let st = b.as_ref().unwrap();
        (
            st.store.config.minimal_mode_enabled,
            st.store.config.auto_expire_otp,
            st.store.is_paused,
            st.store.pinned_count(),
            st.store.queue_mode_active,
        )
    });
    let autostart = is_autostart_enabled();

    AppendMenuW(
        hmenu,
        MF_STRING | MF_GRAYED,
        0,
        to_wide(&format!("当前角色：{}", ClipboardStore::edition_title())).as_ptr(),
    );
    AppendMenuW(hmenu, MF_STRING, CMD_OPEN_PANEL, to_wide("打开 iClip 面板 (Alt+V)").as_ptr());
    AppendMenuW(hmenu, MF_SEPARATOR, 0, null());

    AppendMenuW(
        hmenu,
        MF_STRING | if minimal { MF_CHECKED } else { 0 },
        CMD_TOGGLE_MINIMAL,
        to_wide("极简纯净模式（基础功能版） (Ctrl+E)").as_ptr(),
    );
    #[cfg(feature = "flow")]
    AppendMenuW(
        hmenu,
        MF_STRING | if queue_active { MF_CHECKED } else { 0 },
        CMD_TOGGLE_QUEUE_MODE,
        to_wide("开启 FIFO 顺序复制队列 (Ctrl+Alt+V 连填)").as_ptr(),
    );
    #[cfg(not(feature = "flow"))]
    let _ = queue_active;

    AppendMenuW(
        hmenu,
        MF_STRING | if otp_exp { MF_CHECKED } else { 0 },
        CMD_TOGGLE_OTP_EXPIRE,
        to_wide("验证码粘贴后 30 秒自动无痕销毁").as_ptr(),
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
        to_wide(if paused { "恢复剪贴板记录" } else { "暂停剪贴板记录" }).as_ptr(),
    );
    AppendMenuW(hmenu, MF_STRING, CMD_CLEAR_UNPINNED, to_wide("清空未固定历史").as_ptr());
    AppendMenuW(hmenu, MF_SEPARATOR, 0, null());
    AppendMenuW(hmenu, MF_STRING, CMD_QUIT_APP, to_wide("退出 iClip").as_ptr());

    let mut pt = POINT { x: 0, y: 0 };
    let _ = GetCursorPos(&mut pt);
    let _ = SetForegroundWindow(hwnd);
    let _ = TrackPopupMenu(hmenu, TPM_BOTTOMALIGN | TPM_LEFTALIGN, pt.x, pt.y, 0, hwnd, null());
    let _ = DestroyMenu(hmenu);
}

unsafe fn handle_menu_command(hwnd: HWND, cmd: usize) {
    match cmd {
        CMD_OPEN_PANEL => show_panel_near_cursor(hwnd),
        CMD_TOGGLE_MINIMAL => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.config.minimal_mode_enabled = !st.store.config.minimal_mode_enabled;
                    st.store.save_config();
                }
            });
            let _ = InvalidateRect(hwnd, null(), FALSE);
        }
        #[cfg(feature = "flow")]
        CMD_TOGGLE_QUEUE_MODE => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.queue_mode_active = !st.store.queue_mode_active;
                }
            });
        }
        CMD_TOGGLE_OTP_EXPIRE => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.config.auto_expire_otp = !st.store.config.auto_expire_otp;
                    st.store.save_config();
                }
            });
        }
        CMD_TOGGLE_PAUSE => {
            APP_STATE.with(|c| {
                if let Some(st) = c.borrow_mut().as_mut() {
                    st.store.is_paused = !st.store.is_paused;
                }
            });
        }
        CMD_TOGGLE_AUTOSTART => {
            set_autostart_enabled(!is_autostart_enabled());
        }
        CMD_EXPORT_ARCHIVE => {
            export_archive_via_dialog(hwnd);
        }
        CMD_IMPORT_ARCHIVE => {
            import_archive_via_dialog(hwnd);
        }
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
    let pinned = APP_STATE.with(|c| c.borrow().as_ref().map(|s| s.store.pinned_count()).unwrap_or(0));
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
    let exists = RegQueryValueExW(hkey, val_name.as_ptr(), null_mut(), null_mut(), null_mut(), null_mut()) == 0;
    let _ = RegCloseKey(hkey);
    exists
}

unsafe fn set_autostart_enabled(enable: bool) {
    let subkey = to_wide("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
    let val_name = to_wide("iClip");
    let mut hkey = null_mut();
    if RegOpenKeyExW(HKEY_CURRENT_USER, subkey.as_ptr(), 0, KEY_SET_VALUE, &mut hkey) != 0 {
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

#[allow(dead_code)]
fn _unused_close_guard() {
    let _ = CloseHandle;
    let _ = BITMAPINFO::default_stub;
    let _ = DIB_RGB_COLORS;
    let _ = FW_BOLD;
}

trait DefaultStub {
    fn default_stub() {}
}
impl DefaultStub for BITMAPINFO {}
