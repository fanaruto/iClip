import Foundation
import AppKit

/// 基于 GitHub Releases 的原生 OTA 更新管理器
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    struct ReleaseInfo: Equatable {
        let version: String
        let tagName: String
        let notes: String
        let assetName: String
        let assetSize: Int64
        let downloadURL: URL
        let htmlURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(latestVersion: String)
        case available(ReleaseInfo)
        case downloading(progress: Double, info: ReleaseInfo)
        case installing(info: ReleaseInfo)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let repoOwner = "fanaruto"
    private let repoName = "qingjian"
    private let expectedAssetName = "QingJian-macOS.zip"

    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeSession: URLSession?
    private var downloadingInfo: ReleaseInfo?

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    var hasUpdateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    private override init() {
        super.init()
    }

    /// 检查 GitHub 最新 Release
    func checkForUpdates(silent: Bool = false) {
        if case .checking = state { return }
        if case .downloading = state { return }
        if case .installing = state { return }

        if !silent {
            state = .checking
        }

        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            if !silent { state = .failed("更新地址无效") }
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QingJian/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    if !silent { state = .failed("网络响应异常") }
                    return
                }
                if http.statusCode == 404 {
                    if !silent { state = .upToDate(latestVersion: currentVersion) }
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    if !silent { state = .failed("检查失败（HTTP \(http.statusCode)）") }
                    return
                }

                let decoded = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
                let latestVer = Self.normalizeVersion(decoded.tagName)
                guard Self.isVersion(latestVer, newerThan: currentVersion) else {
                    if !silent { state = .upToDate(latestVersion: latestVer) }
                    return
                }

                guard let asset = decoded.assets.first(where: { $0.name == expectedAssetName })
                        ?? decoded.assets.first(where: { $0.name.hasSuffix(".zip") }),
                      let downloadURL = URL(string: asset.browserDownloadURL),
                      let htmlURL = URL(string: decoded.htmlURL) else {
                    if !silent { state = .failed("新版本 v\(latestVer) 尚未上传安装包") }
                    return
                }

                let info = ReleaseInfo(
                    version: latestVer,
                    tagName: decoded.tagName,
                    notes: (decoded.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    assetName: asset.name,
                    assetSize: asset.size,
                    downloadURL: downloadURL,
                    htmlURL: htmlURL
                )
                state = .available(info)
            } catch {
                if !silent {
                    state = .failed("无法连接 GitHub，请稍后重试")
                }
            }
        }
    }

    /// 开始从 GitHub 下载并 OTA 安装更新
    func startOTAUpdate() {
        guard case .available(let info) = state else { return }

        guard Bundle.main.bundleURL.pathExtension == "app" else {
            state = .failed("当前为开发二进制运行，请通过 iClip.app 进行 OTA 更新")
            return
        }

        downloadingInfo = info
        state = .downloading(progress: 0.0, info: info)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        activeSession = session

        var request = URLRequest(url: info.downloadURL)
        request.setValue("QingJian/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        activeDownloadTask = task
        task.resume()
    }

    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        activeSession?.invalidateAndCancel()
        activeSession = nil
        if let info = downloadingInfo {
            state = .available(info)
        } else {
            state = .idle
        }
    }

    // MARK: - 解压校验与无缝替换重启

    private func installDownloadedArchive(at tempZipURL: URL, info: ReleaseInfo) {
        state = .installing(info: info)

        let currentAppURL = Bundle.main.bundleURL
        let currentPID = ProcessInfo.processInfo.processIdentifier

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stageDir = fm.temporaryDirectory.appendingPathComponent("QingJian-OTA-\(UUID().uuidString)", isDirectory: true)
            let copiedZip = stageDir.appendingPathComponent("release.zip")
            let extractDir = stageDir.appendingPathComponent("extracted", isDirectory: true)

            do {
                try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
                try fm.copyItem(at: tempZipURL, to: copiedZip)
                try? fm.removeItem(at: tempZipURL)

                // 使用系统 ditto 解压，完整保留代码签名与符号链接
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-xk", copiedZip.path, extractDir.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else {
                    throw OTAError.extractFailed
                }

                // 定位解压后的 .app
                let extractedApps = (try? fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension == "app" } ?? []
                guard let newAppURL = extractedApps.first,
                      fm.isExecutableFile(atPath: newAppURL.appendingPathComponent("Contents/MacOS/QingJian").path) else {
                    throw OTAError.invalidAppBundle
                }

                // 写入独立脱离进程脚本：等旧进程退出 -> 原子替换 -> 清除隔离标记 -> 拉起新版
                let scriptURL = stageDir.appendingPathComponent("apply_ota.sh")
                let scriptContent = """
                #!/bin/zsh
                set -e
                OLD_PID=\(currentPID)
                TARGET_APP=\(Self.shellQuote(currentAppURL.path))
                NEW_APP=\(Self.shellQuote(newAppURL.path))
                STAGE_DIR=\(Self.shellQuote(stageDir.path))
                BACKUP_APP="${TARGET_APP}.ota-backup"

                # 等待旧版退出（最多 8 秒）
                for i in {1..40}; do
                  if ! kill -0 "$OLD_PID" 2>/dev/null; then
                    break
                  fi
                  sleep 0.2
                done

                rm -rf "$BACKUP_APP"
                if [ -d "$TARGET_APP" ]; then
                  mv "$TARGET_APP" "$BACKUP_APP"
                fi

                if mv "$NEW_APP" "$TARGET_APP"; then
                  xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
                  rm -rf "$BACKUP_APP"
                  open -n "$TARGET_APP"
                else
                  if [ -d "$BACKUP_APP" ]; then
                    mv "$BACKUP_APP" "$TARGET_APP"
                  fi
                  open -n "$TARGET_APP"
                fi

                rm -rf "$STAGE_DIR"
                """
                try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

                let launcher = Process()
                launcher.executableURL = URL(fileURLWithPath: "/bin/zsh")
                launcher.arguments = ["-c", "nohup \(Self.shellQuote(scriptURL.path)) >/dev/null 2>&1 &"]
                try launcher.run()
                launcher.waitUntilExit()

                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                try? fm.removeItem(at: stageDir)
                await MainActor.run {
                    let message = (error as? OTAError)?.localizedDescription ?? "安装更新失败：\(error.localizedDescription)"
                    self.state = .failed(message)
                }
            }
        }
    }

    // MARK: - 语义化版本工具

    private static func normalizeVersion(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
    }

    private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum OTAError: LocalizedError {
        case extractFailed
        case invalidAppBundle

        var errorDescription: String? {
            switch self {
            case .extractFailed: return "解压更新包失败"
            case .invalidAppBundle: return "更新包中未找到有效的应用文件"
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 1
        let progress = min(max(Double(totalBytesWritten) / Double(expected), 0), 1)
        Task { @MainActor in
            if let info = self.downloadingInfo {
                self.state = .downloading(progress: progress, info: info)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let fm = FileManager.default
        let safeCopy = fm.temporaryDirectory.appendingPathComponent("qingjian-dl-\(UUID().uuidString).zip")
        do {
            try fm.copyItem(at: location, to: safeCopy)
            Task { @MainActor in
                self.activeSession?.finishTasksAndInvalidate()
                self.activeSession = nil
                self.activeDownloadTask = nil
                guard let info = self.downloadingInfo else {
                    try? fm.removeItem(at: safeCopy)
                    return
                }
                self.installDownloadedArchive(at: safeCopy, info: info)
            }
        } catch {
            Task { @MainActor in
                self.state = .failed("保存更新包失败")
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        Task { @MainActor in
            self.activeSession?.invalidateAndCancel()
            self.activeSession = nil
            self.activeDownloadTask = nil
            self.state = .failed("下载更新包失败，请检查网络连接")
        }
    }
}

// MARK: - GitHub API 模型

private struct GitHubReleaseDTO: Decodable {
    let tagName: String
    let htmlURL: String
    let body: String?
    let assets: [GitHubAssetDTO]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }
}

private struct GitHubAssetDTO: Decodable {
    let name: String
    let size: Int64
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case browserDownloadURL = "browser_download_url"
    }
}
