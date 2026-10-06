import Foundation

/// 把后端 `/export/singbox` 包成 NE 可直接跑的完整 sing-box 配置。
///
/// 现网导出已是 sing-box 1.12+（typed DNS、`default_domain_resolver`、selector `proxy`）。
/// 1.12 起内核拒绝 `{ tag, address }` DNS 和 `type: dns` 出站。
/// 客户端补 TUN inbound，并在后端 route 上追加直连规则，不改写 DNS 形态。
///
/// 纯 Foundation，无上游依赖，可独立编译与单测。配置合法性校验交由调用方(V7ProfileBridge)用 LibboxCheckConfig。
public enum V7ConfigBuilder {
    public enum BuildError: LocalizedError {
        case notJSONObject
        case noOutbounds
        case serialize(String)
        public var errorDescription: String? {
            switch self {
            case .notJSONObject: return "导出内容不是 JSON 对象"
            case .noOutbounds: return "导出配置缺少 outbounds(可能是无效/过期订阅)"
            case let .serialize(m): return "配置序列化失败: \(m)"
            }
        }
    }

    /// proxy_config 的 bypass 输入（字段名容错：兼容后端 proxyRoutingService 的常见命名）。
    public struct BypassRules {
        public var directDomainSuffix: [String]
        public var directDomain: [String]
        public var directDomainKeyword: [String]
        public var directIPCIDR: [String]
        public init(directDomainSuffix: [String] = [], directDomain: [String] = [], directDomainKeyword: [String] = [], directIPCIDR: [String] = []) {
            self.directDomainSuffix = directDomainSuffix
            self.directDomain = directDomain
            self.directDomainKeyword = directDomainKeyword
            self.directIPCIDR = directIPCIDR
        }

        /// 从 /me/proxy-config 宽松解析。键名与安卓 ProxyConfigDto 一致。
        public static func from(_ proxy: [String: Any]?) -> BypassRules {
            guard let proxy else { return BypassRules() }
            func strs(_ keys: [String]) -> [String] {
                for k in keys {
                    if let arr = proxy[k] as? [String], !arr.isEmpty { return arr }
                }
                return []
            }
            return BypassRules(
                directDomainSuffix: strs(["domain_suffix", "direct_domains", "bypass_domains", "direct_domain_suffix"]),
                directDomain: strs(["domain"]),
                directDomainKeyword: strs(["domain_keyword"]),
                directIPCIDR: strs(["ip_cidr", "direct_ip_cidr", "bypass_ip_cidr", "direct_ips"])
            )
        }

        public func asProxyJSON() -> [String: Any] {
            [
                "domain_suffix": directDomainSuffix,
                "domain": directDomain,
                "domain_keyword": directDomainKeyword,
                "ip_cidr": directIPCIDR,
            ]
        }
    }

    /// 解析导出端点返回的裸 JSON 字符串为字典。
    public static func parseExport(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw BuildError.notJSONObject }
        return obj
    }

    /// 可点选的线路。跳过 direct / selector / urltest，名字用出站 tag（与后端节点名一致）。
    public struct Line: Identifiable, Hashable {
        public let subscriptionId: Int
        public let subscriptionName: String
        public let tag: String
        public let type: String
        public var region: String?
        public let exportURL: String
        /// Xray 导出地址。官方 sing-box 表达不了的线路用它翻译进 Veylo 隧道核。
        public var xrayExportURL: String
        /// 服务端验证通过的内核。空 = 还没验证。
        public var cores: [String]
        public var bestCore: String?
        public var singboxOK: Bool?
        /// 官方 sing-box 导出里就能跑。为 false 时改走 Xray 导出翻译进 Veylo 核。
        public var singboxRunnable: Bool
        public var veyloRunnable: Bool { singboxRunnable || !xrayExportURL.isEmpty }
        /// 这条线路实际该用的内核：singbox / xray / mihomo。
        public var core: String
        public var id: String { "\(subscriptionId)|\(tag)" }
        public var coreLabel: String {
            switch core {
            case "xray": return "Xray"
            case "mihomo": return "mihomo"
            default: return "sing-box"
            }
        }
        public init(subscriptionId: Int, subscriptionName: String, tag: String, type: String, region: String?, exportURL: String, xrayExportURL: String = "", cores: [String] = [], bestCore: String? = nil, singboxOK: Bool? = nil, singboxRunnable: Bool = true, core: String = "singbox") {
            self.subscriptionId = subscriptionId
            self.subscriptionName = subscriptionName
            self.tag = tag
            self.type = type
            self.region = region
            self.exportURL = exportURL
            self.xrayExportURL = xrayExportURL
            self.cores = cores
            self.bestCore = bestCore
            self.singboxOK = singboxOK
            self.singboxRunnable = singboxRunnable
            self.core = core
        }

        /// sing-box 能跑就用 sing-box。只有验证结果里没有 sing-box 时才标成 Xray / mihomo。
        public static func chooseCore(singboxOK: Bool?, cores: [String], bestCore: String?) -> (core: String, runnable: Bool) {
            let known: Set<String> = ["singbox", "xray", "mihomo"]
            let verified = cores.filter { known.contains($0) }
            if verified.isEmpty {
                return ("singbox", singboxOK != false)
            }
            if verified.contains("singbox"), singboxOK != false {
                return ("singbox", true)
            }
            let alt = bestCore.flatMap { verified.contains($0) ? $0 : nil } ?? verified.first { $0 != "singbox" } ?? verified[0]
            return (alt, false)
        }
    }

    public static func lines(in export: [String: Any], subscriptionId: Int, subscriptionName: String, exportURL: String, xrayExportURL: String = "") -> [Line] {
        let skip: Set<String> = ["direct", "block", "dns", "selector", "urltest"]
        guard let outbounds = export["outbounds"] as? [[String: Any]] else { return [] }
        return outbounds.compactMap { outbound in
            let type = (outbound["type"] as? String) ?? ""
            let tag = (outbound["tag"] as? String) ?? ""
            guard !tag.isEmpty, !skip.contains(type) else { return nil }
            return Line(subscriptionId: subscriptionId, subscriptionName: subscriptionName, tag: tag, type: type, region: nil, exportURL: exportURL, xrayExportURL: xrayExportURL)
        }
    }

    /// 包成完整配置。自动切换开时 selector 改成 urltest；关掉则把 default 钉在选中节点。
    public static func build(export: [String: Any], bypass: BypassRules, selectedTag: String? = nil, autoSwitch: Bool = true, runnableTags: Set<String>? = nil) throws -> String {
        guard var outbounds = export["outbounds"] as? [[String: Any]], !outbounds.isEmpty else {
            throw BuildError.noOutbounds
        }
        if autoSwitch {
            outbounds = enableAutoSwitch(outbounds, runnableTags: runnableTags)
        } else if let selectedTag {
            outbounds = pinSelector(outbounds, defaultTag: selectedTag)
        }

        var cfg = export
        cfg.removeValue(forKey: "version") // 1) 去顶层 version

        // 2) tun inbound（字段对齐 sing-box 1.13；NE 注入 fd 后 libbox 据此建栈）
        cfg["inbounds"] = [[
            "type": "tun",
            "tag": "tun-in",
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "auto_route": true,
            "strict_route": true,
            "stack": "system",
        ] as [String: Any]]

        // 3) route：保留后端的 default_domain_resolver，再追加直连规则
        var rules: [[String: Any]] = []
        if !bypass.directDomainSuffix.isEmpty {
            rules.append(["domain_suffix": bypass.directDomainSuffix, "outbound": "direct"])
        }
        if !bypass.directDomain.isEmpty {
            rules.append(["domain": bypass.directDomain, "outbound": "direct"])
        }
        if !bypass.directDomainKeyword.isEmpty {
            rules.append(["domain_keyword": bypass.directDomainKeyword, "outbound": "direct"])
        }
        if !bypass.directIPCIDR.isEmpty {
            rules.append(["ip_cidr": bypass.directIPCIDR, "outbound": "direct"])
        }
        rules.append(["ip_is_private": true, "outbound": "direct"])
        let finalTag = firstProxyTag(outbounds) ?? "direct"
        let existingRoute = export["route"] as? [String: Any]
        var route: [String: Any] = [
            "rules": rules,
            "final": finalTag,
            "auto_detect_interface": true,
        ]
        if let resolver = existingRoute?["default_domain_resolver"] {
            route["default_domain_resolver"] = resolver
        } else {
            route["default_domain_resolver"] = ["server": "dns-direct"]
        }
        cfg["route"] = route

        // 4) DNS：沿用后端 1.12+ 写法。缺省时也用 typed server，不用旧的 { tag, address }
        if cfg["dns"] == nil {
            cfg["dns"] = [
                "servers": [["type": "udp", "tag": "dns-direct", "server": "223.5.5.5"]],
                "final": "dns-direct",
            ] as [String: Any]
        }

        cfg["outbounds"] = ensureBaseOutbounds(outbounds)

        do {
            let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            throw BuildError.serialize(error.localizedDescription)
        }
    }

    /// 一步到位：原始导出字符串 + proxy_config → 完整配置字符串。
    public static func buildFrom(rawExport: String, proxyConfig: [String: Any]?, selectedTag: String? = nil, autoSwitch: Bool = true, runnableTags: Set<String>? = nil) throws -> String {
        let export = try parseExport(rawExport)
        return try build(export: export, bypass: BypassRules.from(proxyConfig), selectedTag: selectedTag, autoSwitch: autoSwitch, runnableTags: runnableTags)
    }

    // MARK: - helpers

    private static func firstProxyTag(_ outbounds: [[String: Any]]) -> String? {
        let skip: Set<String> = ["direct", "dns", "block", "selector", "urltest"]
        // 优先选 selector/urltest（分组），否则第一个真实节点
        if let group = outbounds.first(where: { ["selector", "urltest"].contains(($0["type"] as? String) ?? "") }) {
            return group["tag"] as? String
        }
        return outbounds.first { !skip.contains(($0["type"] as? String) ?? "") }?["tag"] as? String
    }

    /// 把 selector（后端 tag=`proxy`）的 default 改成用户选的节点。节点不在组里则不动。
    /// 对齐安卓 CF-15：自动切换开时，分组出站改成 urltest，节点挂了会自己换。
    private static func enableAutoSwitch(_ outbounds: [[String: Any]], runnableTags: Set<String>?) -> [[String: Any]] {
        outbounds.map { outbound in
            guard (outbound["type"] as? String) == "selector" else { return outbound }
            var copy = outbound
            if let runnableTags, var members = copy["outbounds"] as? [String] {
                let kept = members.filter { runnableTags.contains($0) }
                if !kept.isEmpty { members = kept }
                copy["outbounds"] = members
            }
            copy["type"] = "urltest"
            copy["url"] = "https://www.gstatic.com/generate_204"
            copy["interval"] = "3m"
            copy["tolerance"] = 50
            copy["interrupt_exist_connections"] = false
            copy.removeValue(forKey: "default")
            return copy
        }
    }

    private static func pinSelector(_ outbounds: [[String: Any]], defaultTag: String) -> [[String: Any]] {
        outbounds.map { outbound in
            guard (outbound["type"] as? String) == "selector",
                  let members = outbound["outbounds"] as? [String],
                  members.contains(defaultTag)
            else { return outbound }
            var copy = outbound
            copy["default"] = defaultTag
            return copy
        }
    }

    private static func ensureBaseOutbounds(_ outbounds: [[String: Any]]) -> [[String: Any]] {
        var result = outbounds
        let types = Set(outbounds.compactMap { $0["type"] as? String })
        if !types.contains("direct") {
            result.append(["type": "direct", "tag": "direct"])
        }
        return result
    }
}
