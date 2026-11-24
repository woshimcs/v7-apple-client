import Foundation

// V7 自有文件（不改上游）。CF-21 用量上报 / CF-23 计量，口径与桌面端相同：
// woshimcs/v7-win-pc docs/TRAFFIC_ACCOUNTING.md、src/traffic/account.ts、src/traffic/session.ts。
//
// 分工（iOS 的 Network Extension 内存很紧）：
//   扩展：libbox 连接事件 → V7TrafficAccumulator 按线路累加 → 每 60 秒并进 App Group 的 open.json；
//         open.json 满 10 分钟或 80 条样本就封成 sealed-*.json。扩展不联网上传。
//   主 App：V7TrafficUploader 读 sealed-*.json，POST /api/v1/me/traffic，成功或明确拒收后删文件。
// 两边只通过文件交接：扩展只写 open.json 并改名封批，主 App 只读 / 删 sealed-*.json，不需要锁。
//
// 纯 Foundation，不依赖 Libbox，可在 Linux 上单测（V7Tests/TrafficLedgerTests）。
// Related to collections#695 (CF-21) / collections#698 (CF-23)

public enum V7TrafficSecurity: String, Codable {
    case tls, reality, none
}

/// 一条线路的计量画像。tag 就是导出里的出站名（= /lines 的 name）。
public struct V7TrafficLineProfile: Equatable {
    public var tag: String
    public var proto: String
    public var transport: String
    public var security: V7TrafficSecurity

    public init(tag: String, proto: String, transport: String, security: V7TrafficSecurity) {
        self.tag = tag
        self.proto = proto
        self.transport = transport
        self.security = security
    }
}

// MARK: - 出站目录

public enum V7TrafficCatalog {
    /// 不计量的出站 tag / 类型。与桌面 SKIP 相同。
    static let skipTags: Set<String> = ["direct", "block", "dns", "reject", "dns-out", "dns-direct"]
    static let nonProxyTypes: Set<String> = ["direct", "block", "dns", "selector", "urltest", "fallback"]

    /// 从隧道正在跑的 sing-box 配置里取每个代理出站的协议 / 传输 / 安全层。
    public static func fromSingbox(_ config: String) -> [String: V7TrafficLineProfile] {
        guard let data = config.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]]
        else { return [:] }
        var out: [String: V7TrafficLineProfile] = [:]
        for o in outbounds {
            let type = ((o["type"] as? String) ?? "").lowercased()
            let tag = (o["tag"] as? String) ?? ""
            guard !tag.isEmpty, !type.isEmpty, !nonProxyTypes.contains(type) else { continue }
            let transport = ((o["transport"] as? [String: Any])?["type"] as? String) ?? ""
            out[tag] = V7TrafficLineProfile(
                tag: tag,
                proto: type,
                transport: transport.isEmpty ? "tcp" : transport.lowercased(),
                security: security(of: o["tls"])
            )
        }
        return out
    }

    static func security(of tls: Any?) -> V7TrafficSecurity {
        guard let obj = tls as? [String: Any] else { return .none }
        if obj["reality"] is [String: Any] { return .reality }
        return (obj["enabled"] as? Bool) == true ? .tls : .none
    }

    /// 自动换线时内核可能把同名成员改成 `名称#序号`，导出和服务端只认 `名称`（桌面复盘 B9）。
    static func resolve(_ tag: String, in catalog: [String: V7TrafficLineProfile]) -> String {
        if catalog[tag] != nil { return tag }
        if let hash = tag.lastIndex(of: "#"), Int(tag[tag.index(after: hash)...]) != nil {
            let base = String(tag[..<hash])
            if catalog[base] != nil { return base }
        }
        return tag
    }

    /// 一条连接记到哪条线路上。nil = 不计量（直连 / 拦截 / DNS）。
    ///
    /// libbox 的 chain 里既有分组（proxy）也有实际节点，顺序不作假设：取第一个在目录里的名字。
    /// 都不在目录里时（分组成员没下发画像、旧配置）按第一个名字记 unknown，和桌面一样不丢字节。
    public static func classify(
        chain: [String],
        outbound: String,
        outboundType: String,
        catalog: [String: V7TrafficLineProfile]
    ) -> V7TrafficLineProfile? {
        let type = outboundType.lowercased()
        if ["direct", "block", "dns"].contains(type) { return nil }
        var names = chain.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tail = outbound.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { names.append(tail) }
        guard let head = names.first, !skipTags.contains(head) else { return nil }
        for name in names {
            let tag = resolve(name, in: catalog)
            if let profile = catalog[tag] { return profile }
        }
        if names.contains(where: { skipTags.contains($0) }) { return nil }
        return V7TrafficLineProfile(tag: resolve(head, in: catalog), proto: "unknown", transport: "tcp", security: .none)
    }
}

// MARK: - 按连接累加

/// libbox CommandConnections 事件流的累加器。非线程安全，由调用方串行使用。
///
/// 事件语义（veylo-core experimental/libbox/command_types.go）：
///   New    带 Connection（含累计上下行）；订阅开头 Reset 时会把现存连接作为 New 再发一遍。
///   Update 只带本次增量 UplinkDelta / DownlinkDelta。
///   Closed 可能带 Connection（最终累计），也可能只有 ID。关闭的连接在服务端还会保留 5 分钟，
///          重新订阅时会再出现，所以计过的 ID 要记住一阵，避免重复计数。
public final class V7TrafficAccumulator {
    public struct Bucket: Equatable {
        public var line: V7TrafficLineProfile
        public var flow: String
        public var up: Int64
        public var down: Int64
    }

    private struct Tracked {
        var line: V7TrafficLineProfile?
        var flow: String
        var up: Int64
        var down: Int64
    }

    /// 关闭连接在服务端保留 5 分钟，这里多留一倍。
    static let closedMemory: TimeInterval = 10 * 60

    public private(set) var catalog: [String: V7TrafficLineProfile]
    private var tracked: [String: Tracked] = [:]
    private var closed: [String: Date] = [:]
    private var buckets: [String: Bucket] = [:]

    public init(catalog: [String: V7TrafficLineProfile] = [:]) {
        self.catalog = catalog
    }

    public func setCatalog(_ catalog: [String: V7TrafficLineProfile]) {
        self.catalog = catalog
    }

    public var trackedCount: Int { tracked.count }

    /// New / 带 Connection 的 Closed / Reset 快照里的一条连接。total 是累计值。
    public func observe(
        id: String,
        chain: [String],
        outbound: String,
        outboundType: String,
        network: String,
        upTotal: Int64,
        downTotal: Int64,
        isClosed: Bool,
        now: Date = Date()
    ) {
        guard !id.isEmpty, closed[id] == nil else { return }
        var row = tracked[id] ?? Tracked(
            line: V7TrafficCatalog.classify(chain: chain, outbound: outbound, outboundType: outboundType, catalog: catalog),
            flow: network.lowercased() == "udp" ? "udp" : "tcp",
            up: 0,
            down: 0
        )
        let up = max(0, upTotal - row.up)
        let down = max(0, downTotal - row.down)
        row.up = max(row.up, upTotal)
        row.down = max(row.down, downTotal)
        add(row.line, flow: row.flow, up: up, down: down)
        if isClosed {
            tracked[id] = nil
            closed[id] = now
        } else {
            tracked[id] = row
        }
    }

    /// Update 事件。没见过 New 的连接不知道走哪条线路，丢掉。
    public func addDelta(id: String, up: Int64, down: Int64) {
        guard var row = tracked[id] else { return }
        let u = max(0, up), d = max(0, down)
        row.up += u
        row.down += d
        tracked[id] = row
        add(row.line, flow: row.flow, up: u, down: d)
    }

    /// 不带 Connection 的 Closed 事件。
    public func markClosed(id: String, now: Date = Date()) {
        guard !id.isEmpty else { return }
        tracked[id] = nil
        closed[id] = now
    }

    /// 取出并清空已累加的桶，顺带忘掉早已关闭的连接。
    public func drain(now: Date = Date()) -> [Bucket] {
        closed = closed.filter { now.timeIntervalSince($0.value) < Self.closedMemory }
        let out = buckets.values.sorted { ($0.line.tag, $0.flow) < ($1.line.tag, $1.flow) }
        buckets.removeAll()
        return out
    }

    private func add(_ line: V7TrafficLineProfile?, flow: String, up: Int64, down: Int64) {
        guard let line, up > 0 || down > 0 else { return }
        let key = [line.tag, line.proto, line.transport, line.security.rawValue, flow].joined(separator: "\u{0}")
        var b = buckets[key] ?? Bucket(line: line, flow: flow, up: 0, down: 0)
        b.up += up
        b.down += down
        buckets[key] = b
    }
}

// MARK: - 上报格式

/// 主 App 写给扩展的上下文（App Group 里的 meta.json）。连接前、登录后写。
public struct V7TrafficMeta: Codable, Equatable {
    /// `id:<用户 id>`，取不到时 `name:<用户名>`。只在同一账户登录时上传（桌面复盘 B6）。
    public var owner: String?
    public var appVersion: String?
    public var os: String?
    public var preferredTag: String?
    /// 这次连接的订阅（清单）id。CF-23。
    public var collectionId: Int?
    /// 线路名 → route_id（/lines 的 route_id，含隐身分组 fallbacks）。对不上就不带，服务端按 line_tag 兜底。
    public var routeIds: [String: Int]

    public init(owner: String? = nil, appVersion: String? = nil, os: String? = nil, preferredTag: String? = nil, collectionId: Int? = nil, routeIds: [String: Int] = [:]) {
        self.owner = owner
        self.appVersion = appVersion
        self.os = os
        self.preferredTag = preferredTag
        self.collectionId = collectionId
        self.routeIds = routeIds
    }

    enum CodingKeys: String, CodingKey {
        case owner
        case appVersion = "app_version"
        case os
        case preferredTag = "preferred_tag"
        case collectionId = "collection_id"
        case routeIds = "route_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        os = try c.decodeIfPresent(String.self, forKey: .os)
        preferredTag = try c.decodeIfPresent(String.self, forKey: .preferredTag)
        collectionId = try c.decodeIfPresent(Int.self, forKey: .collectionId)
        routeIds = (try? c.decodeIfPresent([String: Int].self, forKey: .routeIds)) ?? [:]
    }
}

/// POST /api/v1/me/traffic 的一条样本。字段与桌面 storeOpenBuckets 相同；platform 固定 ios。
public struct V7TrafficSample: Codable, Equatable {
    public var platform: String
    public var app_version: String?
    public var os: String?
    public var arch: String?
    public var line_tag: String
    public var preferred_tag: String?
    public var line_protocol: String
    public var line_transport: String
    public var line_security: String
    public var vpn_mode: String
    public var core: String
    public var flow_network: String
    public var bytes_up: Int64
    public var bytes_down: Int64
    public var bucket_start: String
    public var route_id: Int?
    public var collection_id: Int?

    /// 与服务端 sampleKey 同一维度，同键样本合并。
    var mergeKey: String {
        [platform, bucket_start, core, vpn_mode, line_tag, line_protocol, line_transport, line_security, flow_network]
            .joined(separator: "\u{0}")
    }

    public static func make(_ buckets: [V7TrafficAccumulator.Bucket], meta: V7TrafficMeta, now: Date = Date()) -> [V7TrafficSample] {
        let hour = V7TrafficSample.hourBucket(now)
        return buckets.map { b in
            let routeId = meta.routeIds[b.line.tag]
            return V7TrafficSample(
                platform: "ios",
                app_version: meta.appVersion,
                os: meta.os,
                arch: "arm64",
                line_tag: b.line.tag,
                preferred_tag: meta.preferredTag,
                line_protocol: b.line.proto,
                line_transport: b.line.transport,
                line_security: b.line.security.rawValue,
                // NE 就是 TUN；sing-box 导出和 Xray 翻译的线路都跑在 Veylo 核上（服务端枚举 veylo | xray | mihomo）。
                vpn_mode: "tun",
                core: "veylo",
                flow_network: b.flow,
                bytes_up: b.up,
                bytes_down: b.down,
                bucket_start: hour,
                route_id: (routeId ?? 0) > 0 ? routeId : nil,
                collection_id: (meta.collectionId ?? 0) > 0 ? meta.collectionId : nil
            )
        }
    }

    public static func hourBucket(_ date: Date) -> String {
        let secs = floor(date.timeIntervalSince1970 / 3600) * 3600
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: secs))
    }
}

public struct V7TrafficBatch: Codable, Equatable {
    public var batch_id: String
    public var owner: String?
    /// 毫秒时间戳。open.json 用它判断该不该封批。
    public var created_at: Int64
    public var samples: [V7TrafficSample]

    /// 上传体只要 batch_id + samples。
    public struct Upload: Encodable {
        public let batch_id: String
        public let samples: [V7TrafficSample]
    }

    public var upload: Upload { Upload(batch_id: batch_id.lowercased(), samples: samples) }
}

// MARK: - App Group 队列

/// 目录：`<App Group>/v7-traffic/`。
///   meta.json          主 App 写，扩展读
///   open.json          扩展写（并批）
///   sealed-*.json      扩展封好的批次，主 App 上传后删除
public struct V7TrafficQueue: Sendable {
    public static let sealAfter: TimeInterval = 10 * 60
    public static let sealAtSamples = 80          // 服务端单批上限 100
    public static let maxSealed = 500             // 约 3.5 天的 10 分钟批；更老的服务端也收不了（7 天）

    public let directory: URL
    private var fm: FileManager { FileManager.default }

    public init(directory: URL) {
        self.directory = directory
    }

    var metaURL: URL { directory.appendingPathComponent("meta.json") }
    var openURL: URL { directory.appendingPathComponent("open.json") }

    private func ensureDirectory() {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    // meta

    public func readMeta() -> V7TrafficMeta {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(V7TrafficMeta.self, from: data)
        else { return V7TrafficMeta() }
        return meta
    }

    public func writeMeta(_ meta: V7TrafficMeta) {
        ensureDirectory()
        guard let data = try? Self.encoder.encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }

    // open batch（只有扩展调用；扩展不在跑时主 App 可以调 sealOpen 收尾）

    public func readOpen() -> V7TrafficBatch? {
        guard let data = try? Data(contentsOf: openURL) else { return nil }
        return try? JSONDecoder().decode(V7TrafficBatch.self, from: data)
    }

    /// 把新样本并进 open.json，到期 / 满了就封批。返回这次是否封了批。
    @discardableResult
    public func append(_ samples: [V7TrafficSample], owner: String?, now: Date = Date()) -> Bool {
        ensureDirectory()
        var sealed = false
        var open = readOpen()
        if let current = open, current.owner != owner {
            seal(current, now: now)
            sealed = true
            open = nil
        }
        if samples.isEmpty {
            if let open, isDue(open, now: now) {
                seal(open, now: now)
                return true
            }
            return sealed
        }
        var batch = open ?? V7TrafficBatch(batch_id: UUID().uuidString.lowercased(), owner: owner, created_at: Self.millis(now), samples: [])
        batch.samples = Self.merge(batch.samples, samples)
        if isDue(batch, now: now) {
            seal(batch, now: now)
            return true
        }
        if let data = try? Self.encoder.encode(batch) {
            try? data.write(to: openURL, options: .atomic)
        }
        return sealed
    }

    /// 无条件封掉 open.json（隧道停止时、扩展重启时发现上次遗留时）。
    @discardableResult
    public func sealOpen(now: Date = Date()) -> Bool {
        guard let open = readOpen() else {
            try? fm.removeItem(at: openURL)
            return false
        }
        seal(open, now: now)
        return true
    }

    func isDue(_ batch: V7TrafficBatch, now: Date) -> Bool {
        if batch.samples.count >= Self.sealAtSamples { return true }
        return Double(Self.millis(now) - batch.created_at) / 1000 >= Self.sealAfter
    }

    private func seal(_ batch: V7TrafficBatch, now: Date) {
        defer { try? fm.removeItem(at: openURL) }
        guard !batch.samples.isEmpty, let data = try? Self.encoder.encode(batch) else { return }
        let stamp = String(batch.created_at)
        let padded = String(repeating: "0", count: max(0, 13 - stamp.count)) + stamp
        let name = "sealed-\(padded)-\(batch.batch_id).json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        trimSealed()
    }

    private func trimSealed() {
        let files = sealedFiles()
        guard files.count > Self.maxSealed else { return }
        for url in files.prefix(files.count - Self.maxSealed) {
            try? fm.removeItem(at: url)
        }
    }

    // sealed（主 App）

    /// 旧的在前。
    public func sealedFiles() -> [URL] {
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("sealed-") && $0.hasSuffix(".json") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    public func readSealed(_ url: URL) -> V7TrafficBatch? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(V7TrafficBatch.self, from: data)
    }

    public func remove(_ url: URL) {
        try? fm.removeItem(at: url)
    }

    // helpers

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func merge(_ base: [V7TrafficSample], _ more: [V7TrafficSample]) -> [V7TrafficSample] {
        var order: [String] = []
        var rows: [String: V7TrafficSample] = [:]
        for s in base + more {
            let key = s.mergeKey
            if var prev = rows[key] {
                prev.bytes_up += s.bytes_up
                prev.bytes_down += s.bytes_down
                prev.app_version = s.app_version ?? prev.app_version
                prev.os = s.os ?? prev.os
                prev.preferred_tag = s.preferred_tag ?? prev.preferred_tag
                prev.route_id = s.route_id ?? prev.route_id
                prev.collection_id = s.collection_id ?? prev.collection_id
                rows[key] = prev
            } else {
                order.append(key)
                rows[key] = s
            }
        }
        return order.compactMap { rows[$0] }
    }
}

// MARK: - 上传结果

public enum V7TrafficUploadOutcome: Equatable {
    /// 成功或服务端明确拒收（重试也不会成功）：删掉这一批。
    case remove
    /// 留着下次再传，继续传下一批。
    case keep
    /// 留着，这一轮不再往下传（401 / 网络不通）。
    case stop

    /// 与桌面 uploadQueue 相同：400/403/404/409/413/422 丢弃；401 和网络失败（0）停；其余重试。
    public static func from(status: Int) -> V7TrafficUploadOutcome {
        if (200 ..< 300).contains(status) { return .remove }
        if [400, 403, 404, 409, 413, 422].contains(status) { return .remove }
        if status == 0 || status == 401 { return .stop }
        return .keep
    }
}

public enum V7TrafficOwner {
    /// 批次是否属于当前账户。没有 owner 的批次交给当前账户。
    public static func belongs(_ batchOwner: String?, to keys: [String]) -> Bool {
        guard let batchOwner, !batchOwner.isEmpty else { return true }
        return keys.contains(batchOwner)
    }

    public static func keys(userId: String?, username: String?) -> [String] {
        var out: [String] = []
        if let userId, !userId.isEmpty { out.append("id:\(userId)") }
        if let username, !username.isEmpty { out.append("name:\(username)") }
        return out
    }
}
