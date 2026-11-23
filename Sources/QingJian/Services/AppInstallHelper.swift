import AppKit
import Foundation

/// 安装落位与免证书隔离自愈助手：
/// - 若用户从浏览器解压到「下载/桌面」或直接在挂载的 `.dmg` 镜像中双击打开（触发 macOS App Translocation 只读沙盒），
///   会导致开机自启路径漂移及应用内 OTA 热替换失败。
/// - 启动时自动清除当前包上的 `com.apple.quarantine` 属性，并在非 `/Applications` 目录运行时提供一键丝滑移入「应用程序」并重启。
@MainActor
enum AppInstallHelper {

    /// 启动时静默尝试剥离当前应用包残留的隔离标记（在可写目录下生效）
    static func clearSelfQuarantineIfWritable() {
        let bundlePath = Bundle.main.bundleURL.path
        guard bundlePath.hasSuffix(".app"),
              FileManager.default.isWritableFile(atPath: bundlePath) else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            p.arguments = ["-dr", "com.apple.quarantine", bundlePath]
            try? p.run()
            p.waitUntilExit()
        }
    }

    /// 判断当前是否处于推荐的正式安装目录（`/Applications` 或 `~/Applications`）
    static var isInstalledInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        guard path.hasSuffix(".app") else {
            // 开发期 `swift run` 裸二进制不弹迁移提示
            return true
        }
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return false
        }
        let userApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApps + "/")
    }

    /// 启动后按需提示一键移入「应用程序」文件夹（测试/演示模式跳过）
    static func promptMoveToApplicationsIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo") || args.contains("--self-test") { return }
        guard !isInstalledInApplicationsFolder else { return }

        let suppressedKey = "iclip.suppressMoveToApplicationsPrompt"
        // 若处于只读 DMG 卷或 AppTranslocation 中，始终温和引导，确保开机自启与 OTA 正常可用
        let rawPath = Bundle.main.bundleURL.path
        let isTranslocatedOrDMG = rawPath.contains("/AppTranslocation/") || rawPath.hasPrefix("/Volumes/")
        if !isTranslocatedOrDMG && UserDefaults.standard.bool(forKey: suppressedKey) {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "将 iClip 移至「应用程序」文件夹？"
        alert.informativeText = "检测到 iClip 正在临时目录或磁盘镜像中运行。一键移入「应用程序」可自动解除系统隔离提示，并确保开机自启与一键更新正常工作。"
        alert.addButton(withTitle: "一键移入并启动（推荐）")
        alert.addButton(withTitle: "暂不移动")

        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            moveToApplicationsAndRelaunch()
        } else if !isTranslocatedOrDMG {
            UserDefaults.standard.set(true, forKey: suppressedKey)
        }
    }

    /// 执行免证书干净落位：复制到 `/Applications/iClip.app` -> 剥离隔离标记 -> 干净本地重签 -> 重启
    static func moveToApplicationsAndRelaunch() {
        let fm = FileManager.default
        let srcURL = Bundle.main.bundleURL
        let destDir: String = fm.isWritableFile(atPath: "/Applications")
            ? "/Applications"
            : ((NSHomeDirectory() as NSString).appendingPathComponent("Applications"))
        try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let destPath = (destDir as NSString).appendingPathComponent("iClip.app")

        let pid = ProcessInfo.processInfo.processIdentifier
        let qSrc = shellQuote(srcURL.path)
        let qDest = shellQuote(destPath)

        let script = """
        #!/bin/zsh
        for i in {1..30}; do
          kill -0 \(pid) 2>/dev/null || break
          sleep 0.15
        done
        rm -rf \(qDest)
        ditto \(qSrc) \(qDest)
        xattr -cr \(qDest) 2>/dev/null || true
        codesign --force --deep --identifier com.qingjian.clipboard --sign - \(qDest) >/dev/null 2>&1 || true
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f \(qDest) >/dev/null 2>&1 || true
        open -n \(qDest)
        rm -f "$0"
        """

        let tmpScript = fm.temporaryDirectory.appendingPathComponent("iclip-move-\(UUID().uuidString).sh")
        do {
            try script.write(to: tmpScript, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpScript.path)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-c", "nohup \(shellQuote(tmpScript.path)) >/dev/null 2>&1 &"]
            try proc.run()
            proc.waitUntilExit()
            NSApp.terminate(nil)
        } catch {
            let errAlert = NSAlert()
            errAlert.alertStyle = .warning
            errAlert.messageText = "自动移入「应用程序」未完成"
            errAlert.informativeText = "请手动将 iClip.app 拖入「应用程序」文件夹（\(error.localizedDescription)）。"
            errAlert.runModal()
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
