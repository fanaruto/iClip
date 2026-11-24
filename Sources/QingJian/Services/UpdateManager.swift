import Foundation
import AppKit
import CryptoKit

/// 基于 GitHub Releases 的角色感知多轨 OTA 更新与版本切换管理器
/// - 同角色升级：极客开发版仅拉取 `iClip-Dev-macOS.zip`，心流办公版仅拉取 `iClip-Flow-macOS.zip`
/// - 跨角色切换：当用户在设置或引导中选择另一角色时，支持同版本直接拉取目标角色专属包原子替换重启
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    struct ReleaseInfo: Equatable {
        let version: String
        let tagName: String
        let notes: String
        let edition: AppRoleEdition
        let isEditionSwitch: Bool
        let assetName: String
        let assetSize: Int64
        let expectedSHA256: String?
        let downloadURL: URL
        let htmlURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(latestVersion: String, edition: AppRoleEdition)
        case available(ReleaseInfo)
        case downloading(progress: Double, info: ReleaseInfo)
        case installing(info: ReleaseInfo)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let repoOwner = "fanaruto"
    private let repoName = "iClip"
    private let legacyAssetName = "iClip-macOS.zip"

    private var checkRequestEpoch: Int = 0
    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeSession: URLSession?
    private var downloadingInfo: ReleaseInfo?

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    var installedEdition: AppRoleEdition {
        AppRoleEdition.installed
    }

    var hasUpdateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    private override init() {
        super.init()
    }

    /// 检查目标角色的 GitHub 最新 Release（支持同角色升级检查与跨角色专属包切换）
    func checkForUpdates(targetEdition: AppRoleEdition? = nil, silent: Bool = false) {
        if case .installing = state { return }
        if case .downloading = state {
            if targetEdition == nil { return }
            cancelDownload()
        }

        let desiredEdition = targetEdition ?? ClipboardStore.shared.targetRoleEdition
        let isSwitchingEdition = (desiredEdition != installedEdition)

        checkRequestEpoch &+= 1
        let requestID = checkRequestEpoch
        Self.pruneStaleLocalOTACache(currentVersion: currentVersion)

        // 优先检测同级目录或本地 LocalOTA 缓存中是否存在与当前版本一致的目标角色签名包（零流量秒切且严防被远端旧 Release 降级覆盖）
        if isSwitchingEdition,
           let localArchive = Self.findLocalSiblingArchive(assetName: desiredEdition.expectedAssetName, matchingVersion: currentVersion) {
            let size = ((try? FileManager.default.attributesOfItem(atPath: localArchive.path))?[.size] as? Int64) ?? 0
            let localInfo = ReleaseInfo(
                version: currentVersion,
                tagName: "v\(currentVersion)",
                notes: "检测到本机已就绪同版本 v\(currentVersion)「\(desiredEdition.title)」签名包，支持离线秒速无损切换。",
                edition: desiredEdition,
                isEditionSwitch: true,
                assetName: desiredEdition.expectedAssetName,
                assetSize: size,
                expectedSHA256: nil,
                downloadURL: localArchive,
                htmlURL: URL(string: "https://github.com/\(repoOwner)/\(repoName)")!
            )
            state = .available(localInfo)
            return
        }

        if !silent || isSwitchingEdition {
            state = .checking
        }

        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            if !silent { state = .failed("更新地址无效") }
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iClip-\(installedEdition.rawValue)/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard requestID == self.checkRequestEpoch else { return }

                guard let http = response as? HTTPURLResponse else {
                    if !silent || isSwitchingEdition { state = .failed("网络响应异常") }
                    return
                }
                if http.statusCode == 404 {
                    if !silent { state = .upToDate(latestVersion: currentVersion, edition: installedEdition) }
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    if !silent || isSwitchingEdition { state = .failed("检查失败（HTTP \(http.statusCode)）") }
                    return
                }

                let decoded = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
                let latestVer = Self.normalizeVersion(decoded.tagName)
                let expectedAsset = desiredEdition.expectedAssetName

                if isSwitchingEdition {
                    // 防降级护栏：若当前本机版本超前于 GitHub Latest Release，严禁拉取线上旧包覆盖本地新版功能
                    if Self.isVersion(currentVersion, newerThan: latestVer) {
                        state = .failed("当前本机版本 v\(currentVersion) 高于线上 Release v\(latestVer)，已拦截降级覆盖")
                        return
                    }
                    // 跨角色切换：严格匹配目标角色专属安装包，禁止回退到其他角色的压缩包
                    guard let roleAsset = decoded.assets.first(where: { $0.name == expectedAsset }),
                          Self.isSafeAssetFileName(roleAsset.name),
                          let downloadURL = URL(string: roleAsset.browserDownloadURL),
                          Self.isTrustedRemoteDownloadURL(downloadURL),
                          let htmlURL = URL(string: decoded.htmlURL) else {
                        state = .failed("GitHub Release v\(latestVer) 尚未上传可信「\(desiredEdition.title)」专属包（\(expectedAsset)）")
                        return
                    }

                    let info = ReleaseInfo(
                        version: latestVer,
                        tagName: decoded.tagName,
                        notes: (decoded.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        edition: desiredEdition,
                        isEditionSwitch: true,
                        assetName: roleAsset.name,
                        assetSize: roleAsset.size,
                        expectedSHA256: Self.parseExpectedSHA256(
                            assetDigest: roleAsset.digest,
                            releaseBody: decoded.body,
                            assetName: roleAsset.name
                        ),
                        downloadURL: downloadURL,
                        htmlURL: htmlURL
                    )
                    state = .available(info)
                    return
                }

                // 同角色常规版本升级检查
                guard Self.isVersion(latestVer, newerThan: currentVersion) else {
                    if !silent { state = .upToDate(latestVersion: latestVer, edition: installedEdition) }
                    return
                }

                // 优先下载当前角色专属包，仅在远端未分包时兼容通用包名
                guard let asset = decoded.assets.first(where: { $0.name == expectedAsset })
                        ?? decoded.assets.first(where: { $0.name == legacyAssetName }),
                      Self.isSafeAssetFileName(asset.name),
                      let downloadURL = URL(string: asset.browserDownloadURL),
                      Self.isTrustedRemoteDownloadURL(downloadURL),
                      let htmlURL = URL(string: decoded.htmlURL) else {
                    if !silent { state = .failed("新版本 v\(latestVer) 尚未上传可信安装包 \(expectedAsset)") }
                    return
                }

                let info = ReleaseInfo(
                    version: latestVer,
                    tagName: decoded.tagName,
                    notes: (decoded.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    edition: desiredEdition,
                    isEditionSwitch: false,
                    assetName: asset.name,
                    assetSize: asset.size,
                    expectedSHA256: Self.parseExpectedSHA256(
                        assetDigest: asset.digest,
                        releaseBody: decoded.body,
                        assetName: asset.name
                    ),
                    downloadURL: downloadURL,
                    htmlURL: htmlURL
                )
                state = .available(info)
            } catch {
                guard requestID == self.checkRequestEpoch else { return }
                if !silent || isSwitchingEdition {
                    state = .failed("无法连接 GitHub，请稍后重试")
                }
            }
        }
    }

    /// 开始从 GitHub 下载目标角色专属包并执行原子替换重启
    func startOTAUpdate() {
        guard case .available(let info) = state else { return }

        guard Bundle.main.bundleURL.pathExtension == "app" else {
            state = .failed("当前为命令行裸二进制运行，请通过 iClip.app 执行 OTA 切换/更新")
            return
        }

        downloadingInfo = info
        if info.downloadURL.isFileURL {
            let fm = FileManager.default
            let tmpCopy = fm.temporaryDirectory.appendingPathComponent("local-ota-\(UUID().uuidString).zip")
            do {
                try fm.copyItem(at: info.downloadURL, to: tmpCopy)
                installDownloadedArchive(at: tmpCopy, info: info)
            } catch {
                state = .failed("读取本地角色安装包失败：\(error.localizedDescription)")
            }
            return
        }
        if !Self.isTrustedRemoteDownloadURL(info.downloadURL) {
            state = .failed("更新源未通过安全域名校验，已拦截下载")
            return
        }
        state = .downloading(progress: 0.0, info: info)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        activeSession = session

        var request = URLRequest(url: info.downloadURL)
        request.setValue("iClip-\(installedEdition.rawValue)/\(currentVersion)", forHTTPHeaderField: "User-Agent")
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
                try fm.createDirectory(
                    at: extractDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stageDir.path)
                try fm.copyItem(at: tempZipURL, to: copiedZip)
                try? fm.removeItem(at: tempZipURL)

                if info.assetSize > 0,
                   let actualSize = (try? fm.attributesOfItem(atPath: copiedZip.path)[.size] as? Int64),
                   actualSize != info.assetSize {
                    throw OTAError.corruptedDownloadSize
                }

                // 若 GitHub Release 元数据提供 SHA-256 摘要，强制逐字节核验密码学完整性（防御中间人或缓存污染）
                if let expectedHex = info.expectedSHA256 {
                    let zipData = try Data(contentsOf: copiedZip, options: .mappedIfSafe)
                    let actualHex = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
                    guard actualHex.caseInsensitiveCompare(expectedHex) == .orderedSame else {
                        throw OTAError.sha256VerificationFailed
                    }
                }

                // 使用系统 ditto 解压，完整保留开发者证书代码签名与辅助功能 TCC 信任链
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-xk", copiedZip.path, extractDir.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else {
                    throw OTAError.extractFailed
                }

                let extractedApps = (try? fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension == "app" } ?? []
                guard let newAppURL = extractedApps.first,
                      (fm.isExecutableFile(atPath: newAppURL.appendingPathComponent("Contents/MacOS/QingJian").path)
                       || fm.isExecutableFile(atPath: newAppURL.appendingPathComponent("Contents/MacOS/iClip").path)) else {
                    throw OTAError.invalidAppBundle
                }

                // 强制阻断包内含恶意符号链接路径穿越（Zip Slip / Symlink 防护）与伪造 Bundle Identifier
                guard !Self.containsExternalSymlink(in: newAppURL) else {
                    throw OTAError.invalidAppBundle
                }
                guard let newPlist = NSDictionary(contentsOf: newAppURL.appendingPathComponent("Contents/Info.plist")),
                      (newPlist["CFBundleIdentifier"] as? String) == "com.qingjian.clipboard" else {
                    throw OTAError.invalidAppBundle
                }

                // 执行系统级代码签名与 Bundle 密封完整性核验，拒绝任何损坏或被篡改的二进制覆盖 /Applications
                let verifyProc = Process()
                verifyProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                verifyProc.arguments = ["--verify", "--deep", "--strict", newAppURL.path]
                verifyProc.standardOutput = Pipe()
                verifyProc.standardError = Pipe()
                try verifyProc.run()
                verifyProc.waitUntilExit()
                guard verifyProc.terminationStatus == 0 else {
                    throw OTAError.signatureVerificationFailed
                }

                // 校验证书包内的角色标记是否与用户请求的目标角色一致（二次防呆校验）
                if info.isEditionSwitch,
                   let bundledEdition = newPlist["IClipEdition"] as? String,
                   bundledEdition != info.edition.rawValue {
                    throw OTAError.editionMismatch
                }

                let scriptURL = stageDir.appendingPathComponent("apply_ota.sh")
                let scriptContent = """
                #!/bin/zsh
                set -e
                OLD_PID=\(currentPID)
                TARGET_APP=\(Self.shellQuote(currentAppURL.path))
                NEW_APP=\(Self.shellQuote(newAppURL.path))
                STAGE_DIR=\(Self.shellQuote(stageDir.path))
                BACKUP_APP="${TARGET_APP}.ota-backup"

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
                  xattr -cr "$TARGET_APP" 2>/dev/null || true
                  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP" >/dev/null 2>&1 || true
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
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

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

    // MARK: - 语义化版本工具（兼容带后缀 tag，如 1.8.0-rc1）

    private static func normalizeVersion(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
    }

    private static func findLocalSiblingArchive(assetName: String, matchingVersion: String) -> URL? {
        let fm = FileManager.default

        // 1. 若当前运行在构建产物目录（如 dist/），同级存在同名版本构建出的兄弟包
        let bundleSiblingDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let siblingZip = bundleSiblingDir.appendingPathComponent(assetName)
        let siblingAppName = assetName == AppRoleEdition.developer.expectedAssetName ? "iClip-Dev.app" : "iClip-Flow.app"
        let siblingAppPlist = bundleSiblingDir.appendingPathComponent(siblingAppName).appendingPathComponent("Contents/Info.plist")
        if fm.fileExists(atPath: siblingZip.path),
           let plist = NSDictionary(contentsOf: siblingAppPlist),
           let siblingVer = plist["CFBundleShortVersionString"] as? String,
           normalizeVersion(siblingVer) == normalizeVersion(matchingVersion) {
            return siblingZip
        }

        // 2. 检查 Application Support/QingJian/LocalOTA/ 缓存的同版本双角色专属签名包
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let localOTADir = appSupport
                .appendingPathComponent("QingJian", isDirectory: true)
                .appendingPathComponent("LocalOTA", isDirectory: true)
            let versionMarker = localOTADir.appendingPathComponent("VERSION")
            let cachedZip = localOTADir.appendingPathComponent(assetName)
            if fm.fileExists(atPath: cachedZip.path),
               let cachedVer = try? String(contentsOf: versionMarker, encoding: .utf8),
               normalizeVersion(cachedVer) == normalizeVersion(matchingVersion) {
                return cachedZip
            }
        }

        return nil
    }

    /// 自动清理与当前运行版本不一致的过期 `LocalOTA` 安装包缓存，回收无用磁盘占用
    static func pruneStaleLocalOTACache(
        currentVersion: String,
        localOTADirectoryOverride: URL? = nil
    ) {
        let fm = FileManager.default
        let targetDir: URL? = localOTADirectoryOverride ?? fm
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("QingJian", isDirectory: true)
            .appendingPathComponent("LocalOTA", isDirectory: true)
        guard let dir = targetDir, fm.fileExists(atPath: dir.path) else { return }

        let versionMarker = dir.appendingPathComponent("VERSION")
        let cachedVer = (try? String(contentsOf: versionMarker, encoding: .utf8)) ?? ""
        guard normalizeVersion(cachedVer) != normalizeVersion(currentVersion) else { return }
        try? fm.removeItem(at: dir)
    }

    private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let parseNumericSegments: (String) -> [Int] = { ver in
            ver.split(separator: ".").map { seg in
                let digits = seg.prefix(while: \.isNumber)
                return Int(digits) ?? 0
            }
        }
        let a = parseNumericSegments(lhs)
        let b = parseNumericSegments(rhs)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    nonisolated static func isSafeAssetFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 128, !name.contains("..") else { return false }
        return name.utf8.allSatisfy { b in
            (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
                || b == 46 || b == 45 || b == 95
        }
    }

    /// 优先提取 GitHub REST API 原生 `asset.digest`（`sha256:<64-hex>`），无则回退解析 Release Notes 校验表
    nonisolated static func parseExpectedSHA256(
        assetDigest: String?,
        releaseBody: String?,
        assetName: String
    ) -> String? {
        if let rawDigest = assetDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
           rawDigest.lowercased().hasPrefix("sha256:") {
            let hex = String(rawDigest.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            if hex.utf8.count == 64, hex.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }) {
                return hex.lowercased()
            }
        }
        guard let body = releaseBody, !body.isEmpty,
              let hexRegex = try? NSRegularExpression(pattern: #"\b([0-9a-fA-F]{64})\b"#) else {
            return nil
        }
        for line in body.components(separatedBy: .newlines) where line.contains(assetName) {
            let r = NSRange(line.startIndex..<line.endIndex, in: line)
            if let m = hexRegex.firstMatch(in: line, range: r),
               let hr = Range(m.range(at: 1), in: line) {
                return line[hr].lowercased()
            }
        }
        return nil
    }

    nonisolated static func isTrustedRemoteDownloadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              url.user == nil, url.password == nil,
              (url.port == nil || url.port == 443),
              let host = url.host?.lowercased() else {
            return false
        }
        let trustedHosts: Set<String> = [
            "github.com",
            "api.github.com",
            "objects.githubusercontent.com",
            "release-assets.githubusercontent.com",
            "github-releases.githubusercontent.com",
            "codeload.github.com",
            "app.webfooo.com"
        ]
        return trustedHosts.contains(host)
    }

    /// 递归检查解压出的 `.app` 包是否包含逃逸至包目录外部的恶意符号链接（Zip Slip / Symlink 逃逸防护）
    nonisolated static func containsExternalSymlink(in bundleURL: URL) -> Bool {
        let fm = FileManager.default
        let rootPrefix = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        if let rootVals = try? bundleURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
           rootVals.isSymbolicLink == true {
            return true
        }
        guard let enumerator = fm.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return true
        }
        for case let fileURL as URL in enumerator {
            if let vals = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
               vals.isSymbolicLink == true {
                let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                if !resolved.hasPrefix(rootPrefix) {
                    return true
                }
            }
        }
        return false
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum OTAError: LocalizedError {
        case corruptedDownloadSize
        case sha256VerificationFailed
        case extractFailed
        case invalidAppBundle
        case signatureVerificationFailed
        case editionMismatch

        var errorDescription: String? {
            switch self {
            case .corruptedDownloadSize: return "下载包体积与官方清单不一致，已拦截安装"
            case .sha256VerificationFailed: return "下载包 SHA-256 校验未通过，已安全拦截替换"
            case .extractFailed: return "解压更新包失败"
            case .invalidAppBundle: return "更新包中未找到有效的应用文件"
            case .signatureVerificationFailed: return "更新包代码签名完整性校验未通过，已安全中止替换"
            case .editionMismatch: return "下载包的角色标识与所选角色不匹配，已安全中止替换"
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
        // 硬性体积上限熔断（40 MB），阻断异常大响应流耗尽临时磁盘
        if totalBytesWritten > 40 * 1024 * 1024 {
            downloadTask.cancel()
            Task { @MainActor in
                self.activeSession?.invalidateAndCancel()
                self.activeSession = nil
                self.activeDownloadTask = nil
                self.state = .failed("更新包超出安全体积上限，已中止下载")
            }
            return
        }
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

    /// 逐跳核验 HTTP 301/302/307/308 重定向目标域名，严禁跳出 HTTPS 可信白名单
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let nextURL = request.url, Self.isTrustedRemoteDownloadURL(nextURL) else {
            completionHandler(nil)
            Task { @MainActor in
                self.activeSession?.invalidateAndCancel()
                self.activeSession = nil
                self.activeDownloadTask = nil
                self.state = .failed("重定向目标域名不在安全白名单内，已拦截")
            }
            return
        }
        completionHandler(request)
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
    let digest: String?
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case digest
        case browserDownloadURL = "browser_download_url"
    }
}
