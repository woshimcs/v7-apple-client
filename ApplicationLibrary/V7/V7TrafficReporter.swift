import Foundation
import Library

/// 主 App 侧的用量上报（CF-21）。采集在扩展里（Extension/V7TrafficSampler.swift），这里只做两件事：
///   1. 连接前 / 登录后把上下文写进 App Group 的 meta.json（账户、线路 route_id、订阅 id、版本）；
///   2. 把扩展封好的 sealed-*.json 传到 `POST /api/v1/me/traffic`。
///
/// 时序约束与桌面相同（docs/TRAFFIC_ACCOUNTING.md）：连接、断开、登出都**不等**上传；同一时刻只有一个上传。
/// Related to collections#695
@MainActor
public enum V7TrafficReporter {
    nonisolated static let store = V7TrafficQueue(directory: FilePath.sharedDirectory.appendingPathComponent("v7-traffic", isDirectory: true))
    private static var uploading: Task<Void, Never>?

    /// 连接前调用；只传 owner 时只更新账户和版本（登录后 / 拉到用户资料后）。
    public static func writeMeta(owner: String?, preferredTag: String?, collectionId: Int?, routeIds: [String: Int]?) {
        var meta = store.readMeta()
        meta.owner = owner ?? meta.owner
        meta.appVersion = V7AppState.appVersion()
        meta.os = osText()
        if let preferredTag { meta.preferredTag = preferredTag }
        if let collectionId { meta.collectionId = collectionId }
        if let routeIds { meta.routeIds = routeIds }
        // 几百字节的小文件，同步写，保证先后顺序（登出清账户后不会被旧的写覆盖）。
        store.writeMeta(meta)
    }

    /// 登出：清掉账户，避免下一个账户的流量记到上一个人头上。已封的批次留着，同一账户再登录时上传。
    public static func clearOwner() {
        var meta = store.readMeta()
        meta.owner = nil
        meta.preferredTag = nil
        meta.collectionId = nil
        meta.routeIds = [:]
        store.writeMeta(meta)
    }

    /// 后台上传，调用方不要等它。tunnelIdle=true 表示扩展不在跑，可以把遗留的 open.json 一起封掉上传。
    public static func uploadInBackground(ownerKeys: [String], tunnelIdle: Bool) {
        guard uploading == nil, V7Keychain.hasToken else { return }
        uploading = Task.detached(priority: .utility) {
            await uploadQueue(ownerKeys: ownerKeys, tunnelIdle: tunnelIdle)
            await MainActor.run { uploading = nil }
        }
    }

    nonisolated static func uploadQueue(ownerKeys: [String], tunnelIdle: Bool) async {
        let q = store
        if tunnelIdle { q.sealOpen() }
        loop: for url in q.sealedFiles() {
            guard V7Keychain.hasToken else { break }
            guard let batch = q.readSealed(url) else {
                q.remove(url) // 坏文件
                continue
            }
            guard V7TrafficOwner.belongs(batch.owner, to: ownerKeys) else { continue }
            if batch.samples.isEmpty {
                q.remove(url)
                continue
            }
            let status = await V7Api.uploadTraffic(batch.upload)
            switch V7TrafficUploadOutcome.from(status: status) {
            case .remove: q.remove(url)
            case .keep: continue
            case .stop: break loop
            }
        }
    }

    nonisolated static func osText() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
