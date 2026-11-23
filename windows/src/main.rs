#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

#[cfg(target_os = "windows")]
mod win_gui;

use iclip_core::store::ClipboardStore;

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.iter().any(|a| a == "--version" || a == "-v") {
        let info = format!(
            "iClip v{} ({})",
            env!("CARGO_PKG_VERSION"),
            ClipboardStore::edition_key()
        );
        println!("{info}");
        return;
    }

    if let Some(pos) = args.iter().position(|a| a == "--self-test") {
        let out_file = args.get(pos + 1).cloned();
        #[cfg(target_os = "windows")]
        {
            match win_gui::run_windows_self_test() {
                Ok(()) => {
                    if let Some(path) = out_file {
                        let report = format!(
                            "{{\"status\":\"PASS\",\"platform\":\"windows\",\"edition\":\"{}\",\"version\":\"{}\"}}",
                            ClipboardStore::edition_key(),
                            env!("CARGO_PKG_VERSION")
                        );
                        let _ = std::fs::write(path, report);
                    }
                    std::process::exit(0);
                }
                Err(err) => {
                    if let Some(path) = out_file {
                        let report = format!("{{\"status\":\"FAIL\",\"error\":\"{err}\"}}");
                        let _ = std::fs::write(path, report);
                    }
                    eprintln!("SELF_TEST_FAILED: {err}");
                    std::process::exit(2);
                }
            }
        }
        #[cfg(not(target_os = "windows"))]
        {
            let _ = out_file;
            println!("iClip core self-test ready (host is non-Windows)");
            return;
        }
    }

    #[cfg(target_os = "windows")]
    {
        let code = win_gui::run_windows_app();
        std::process::exit(code);
    }

    #[cfg(not(target_os = "windows"))]
    {
        println!(
            "iClip Windows binary target (v{}, edition={}). Build with --target x86_64-pc-windows-msvc on Windows.",
            env!("CARGO_PKG_VERSION"),
            ClipboardStore::edition_key()
        );
    }
}
