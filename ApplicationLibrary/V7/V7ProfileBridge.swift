import Foundation
import Libbox
import Library

/// 把 V7 后端订阅落成上游可运行的 profile，并驱动 NE 启停。
///
/// 复用上游既有通路（不自研 NE）：
///   - `Profile`(type=.local, path=configs/config_<id>.json) + `ProfileManager`
///   - `SharedPreferences.selectedProfileID`
///   - `ExtensionProfile.install()/load()/start()/stop()`
///   - `LibboxCheckConfig` 校验
///
/// 依赖上游模块 `Library` 与 `Libbox`，需在 Xcode 把本文件加入对应 target（见 docs/PREREQUISITES.md）。
public enum V7ProfileBridge {
    public enum BridgeError: LocalizedError {
        case invalidExportURL
        case emptyExport
        case configInvalid(String)
        public var errorDescription: String? {
            switch self {
            case .invalidExportURL: return "订阅导出地址无效"
            case .emptyExport: return "导出内容为空"
            case let .configInvalid(m): return "生成的配置不合法: \(m)"
            }
        }
    }

    private static let profileName = "Veylo"

    /// 拉订阅导出原文（token 在 URL 里）。
    public static func downloadExport(_ singboxExportURL: String) async throws -> String {
        guard let url = URL(string: singboxExportURL) else { throw BridgeError.invalidExportURL }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else {
            throw BridgeError.emptyExport
        }
        return raw
    }

    /// 用某条订阅的 singbox 导出链接同步出一份本地 profile（不启动）。返回 profile id。
    @discardableResult
    public static func syncProfile(
        from singboxExportURL: String,
        proxyConfig: [String: Any]?,
        selectedTag: String? = nil
    ) async throws -> Int64 {
        // 1) 拉裸导出（token 即凭证，无需 Bearer）
        let raw = try await downloadExport(singboxExportURL)

        // 2) 包成完整配置。selectedTag 决定 selector 的 default。
        let content = try V7ConfigBuilder.buildFrom(rawExport: raw, proxyConfig: proxyConfig, selectedTag: selectedTag)

        // 3) 校验（off main thread）
        try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            LibboxCheckConfig(content, &error)
            if let error { throw BridgeError.configInvalid(error.localizedDescription) }
        }.value

        // 4) 落 profile：复用已有 Veylo profile 或新建 local
        if let existing = try await ProfileManager.get(by: profileName) {
            try await existing.writeAsync(content)
            await MainActor.run { existing.lastUpdated = Date() }
            try await ProfileManager.update(existing)
            await SharedPreferences.selectedProfileID.set(existing.mustID)
            try await reloadIfConnected(profileID: existing.mustID)
            return existing.mustID
        } else {
            let nextID = try await ProfileManager.nextID()
            let dir = FilePath.sharedDirectory.appendingPathComponent("configs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let relPath = "configs/config_\(nextID).json"
            let profile = Profile(name: profileName, type: .local, path: relPath, lastUpdated: Date())
            try await profile.writeAsync(content)
            try await ProfileManager.create(profile)
            await SharedPreferences.selectedProfileID.set(profile.mustID)
            return profile.mustID
        }
    }

    /// 同步 + 启动 NE。
    public static func syncAndStart(from singboxExportURL: String, proxyConfig: [String: Any]?, selectedTag: String? = nil) async throws {
        _ = try await syncProfile(from: singboxExportURL, proxyConfig: proxyConfig, selectedTag: selectedTag)
        try await ensureInstalledAndStart()
    }

    /// 停核（断连）。
    public static func stop() async throws {
        if let ext = try await ExtensionProfile.load() {
            try await ext.stop()
        }
    }

    /// 清空 V7 节点：停核 + 删除 Veylo profile（用于 deny: purge_nodes）。
    public static func purge() async throws {
        try? await stop()
        if let existing = try await ProfileManager.get(by: profileName) {
            try await ProfileManager.delete(existing)
        }
    }

    // MARK: - helpers

    private static func ensureInstalledAndStart() async throws {
        var ext = try await ExtensionProfile.load()
        if ext == nil {
            try await ExtensionProfile.install()
            ext = try await ExtensionProfile.load()
        }
        guard let ext else { return }
        await ext.register()
        try await ext.start()
    }

    private static func reloadIfConnected(profileID: Int64) async throws {
        if await SharedPreferences.selectedProfileID.get() == profileID,
           let ext = try await ExtensionProfile.load(),
           await ext.status == .connected
        {
            try await ext.reloadService()
        }
    }
}
