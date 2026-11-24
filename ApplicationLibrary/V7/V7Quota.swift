import Foundation

/// 本计费周期的流量额度（CF-23）。额度按团队共享；超额只提示、引导购买流量包，不断开。
///
/// 与桌面 src/trafficQuota.ts 同一套规则：
///   - 数据：`GET /api/v1/me/traffic/summary`（回前台 / 全量同步时拉，节流 60 秒）
///           + `/me/session` 的 `traffic_quota`（会话轮询也带，及时刷新）。
///   - 多个团队时显示最紧张的一个：超额 > 接近 > 正常 > 不限量；同级取剩余最少（服务端 tightestQuota）。
///   - 同一账户、团队、周期、状态只提示一次。
///   - 「流量明细」「购买流量包」都打开网页（veylo.link）。
/// Related to collections#698

public enum V7QuotaState: String, Decodable {
    case unlimited, ok, near, exceeded

    var rank: Int {
        switch self {
        case .exceeded: return 3
        case .near: return 2
        case .ok: return 1
        case .unlimited: return 0
        }
    }
}

/// /me/traffic/summary 的一个团队。
public struct V7OrgQuota: Decodable {
    public let org_id: String
    public let org_name: String?
    public let period_end: String?
    public let state: V7QuotaState
    public let limit_bytes: Int64?
    public let used_bytes: Int64
    public let remaining_bytes: Int64?
}

public struct V7TrafficSummary: Decodable {
    public let orgs: [V7OrgQuota]?
    public let purchase_path: String?
}

/// /me/session 的 traffic_quota。
public struct V7SessionQuota: Decodable {
    public let org_id: String
    public let state: V7QuotaState
    public let used_bytes: Int64
    public let limit_bytes: Int64?
    public let remaining_bytes: Int64?
    public let period_end: String?
    public let purchase_path: String?
}

public struct V7QuotaView: Equatable, Identifiable {
    public var orgId: String
    public var orgName: String
    public var state: V7QuotaState
    public var usedBytes: Int64
    public var limitBytes: Int64?
    public var remainingBytes: Int64?
    public var periodEnd: String?

    public var id: String { [orgId, periodEnd ?? "", state.rawValue].joined(separator: "|") }

    init(_ q: V7OrgQuota) {
        orgId = q.org_id
        orgName = q.org_name ?? ""
        state = q.state
        usedBytes = q.used_bytes
        limitBytes = q.limit_bytes
        remainingBytes = q.remaining_bytes
        periodEnd = q.period_end
    }

    init(_ q: V7SessionQuota, orgName: String) {
        orgId = q.org_id
        self.orgName = orgName
        state = q.state
        usedBytes = q.used_bytes
        limitBytes = q.limit_bytes
        remainingBytes = q.remaining_bytes
        periodEnd = q.period_end
    }

    // MARK: 展示

    /// 「已用 1.2 GB / 100 GB」，不限量时「已用 1.2 GB · 不限量」。
    public var usageText: String {
        let used = Self.bytes(usedBytes)
        if state == .unlimited || limitBytes == nil { return "已用 \(used) · 不限量" }
        return "已用 \(used) / \(Self.bytes(limitBytes ?? 0))"
    }

    public var remainingText: String? {
        guard state != .unlimited, let remainingBytes else { return nil }
        return remainingBytes > 0 ? "剩余 \(Self.bytes(remainingBytes))" : "剩余 0"
    }

    public var stateText: String? {
        switch state {
        case .exceeded: return "本周期流量已用完"
        case .near: return "本周期流量快用完了"
        default: return nil
        }
    }

    /// 0…1；不限量为 nil。
    public var usedRatio: Double? {
        guard state != .unlimited, let limitBytes, limitBytes > 0 else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(limitBytes)))
    }

    /// 周期结束日（本地日期）。
    public var periodEndText: String? {
        guard let raw = periodEnd, let date = Self.parseDate(raw) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "\(f.string(from: date)) 重置"
    }

    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: max(0, n))
    }

    static func parseDate(_ raw: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: raw) { return d }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: String(raw.prefix(10)))
    }
}

public enum V7Quota {
    static let defaultPurchasePath = "/me/traffic?buy=1"
    static let detailPath = "/me/traffic"
    static let defaultWebOrigin = "https://veylo.link"
    static let promptedKey = "v7.trafficQuota.prompted"

    /// 与服务端 tightestQuota 同一规则。
    public static func tightest(_ rows: [V7QuotaView]) -> V7QuotaView? {
        var best: V7QuotaView?
        for q in rows {
            guard let b = best else {
                best = q
                continue
            }
            if q.state.rank > b.state.rank {
                best = q
            } else if q.state.rank == b.state.rank, (q.remainingBytes ?? .max) < (b.remainingBytes ?? .max) {
                best = q
            }
        }
        return best
    }

    /// 只接受站内相对路径。
    public static func safePath(_ path: String?) -> String {
        let p = (path ?? "").trimmingCharacters(in: .whitespaces)
        return p.hasPrefix("/") && !p.hasPrefix("//") ? p : defaultPurchasePath
    }

    /// 网页根：API 走 veylo.link 系时同源；IP 边缘（自签证书，Safari 打不开）一律用 veylo.link。
    public static func webOrigin(apiBase: URL? = V7Backend.baseURL) -> String {
        guard let apiBase, apiBase.scheme == "https", let host = apiBase.host?.lowercased(),
              host == "veylo.link" || host.hasSuffix(".veylo.link")
        else { return defaultWebOrigin }
        if let port = apiBase.port { return "https://\(host):\(port)" }
        return "https://\(host)"
    }

    public static func purchaseURL(path: String?) -> URL? {
        URL(string: webOrigin() + safePath(path))
    }

    public static func detailURL() -> URL? {
        URL(string: webOrigin() + detailPath)
    }

    // MARK: 只提示一次

    static func promptKey(userId: String, _ q: V7QuotaView) -> String {
        [userId, q.orgId, q.periodEnd ?? "", q.state.rawValue].joined(separator: "|")
    }

    /// 超额 / 接近且没提示过 → 记下并返回 true。
    static func shouldPrompt(userId: String, _ q: V7QuotaView, defaults: UserDefaults = .standard) -> Bool {
        guard q.state == .exceeded || q.state == .near else { return false }
        let key = promptKey(userId: userId, q)
        var rows = defaults.stringArray(forKey: promptedKey) ?? []
        if rows.contains(key) { return false }
        rows.append(key)
        defaults.set(Array(rows.suffix(20)), forKey: promptedKey)
        return true
    }
}
