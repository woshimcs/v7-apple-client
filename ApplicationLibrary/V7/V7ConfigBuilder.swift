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
        public var directIPCIDR: [String]
        public init(directDomainSuffix: [String] = [], directIPCIDR: [String] = []) {
            self.directDomainSuffix = directDomainSuffix
            self.directIPCIDR = directIPCIDR
        }

        /// 从 /me/session 的 proxy_config(任意 JSON 字典)宽松解析。
        public static func from(_ proxy: [String: Any]?) -> BypassRules {
            guard let proxy else { return BypassRules() }
            func strs(_ keys: [String]) -> [String] {
                for k in keys {
                    if let arr = proxy[k] as? [String], !arr.isEmpty { return arr }
                }
                return []
            }
            return BypassRules(
                directDomainSuffix: strs(["direct_domains", "bypass_domains", "direct_domain_suffix"]),
                directIPCIDR: strs(["direct_ip_cidr", "bypass_ip_cidr", "direct_ips"])
            )
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
        public let tag: String
        public let type: String
        public var id: String { tag }
        public init(tag: String, type: String) {
            self.tag = tag
            self.type = type
        }
    }

    public static func lines(in export: [String: Any]) -> [Line] {
        let skip: Set<String> = ["direct", "block", "dns", "selector", "urltest"]
        guard let outbounds = export["outbounds"] as? [[String: Any]] else { return [] }
        return outbounds.compactMap { outbound in
            let type = (outbound["type"] as? String) ?? ""
            let tag = (outbound["tag"] as? String) ?? ""
            guard !tag.isEmpty, !skip.contains(type) else { return nil }
            return Line(tag: tag, type: type)
        }
    }

    /// 包成完整配置并返回 JSON 字符串（pretty）。
    /// `selectedTag` 写进 selector 的 `default`，连接时走用户选的那条，而不是导出里的第一条。
    public static func build(export: [String: Any], bypass: BypassRules, selectedTag: String? = nil) throws -> String {
        guard var outbounds = export["outbounds"] as? [[String: Any]], !outbounds.isEmpty else {
            throw BuildError.noOutbounds
        }
        if let selectedTag {
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
    public static func buildFrom(rawExport: String, proxyConfig: [String: Any]?, selectedTag: String? = nil) throws -> String {
        let export = try parseExport(rawExport)
        return try build(export: export, bypass: BypassRules.from(proxyConfig), selectedTag: selectedTag)
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
