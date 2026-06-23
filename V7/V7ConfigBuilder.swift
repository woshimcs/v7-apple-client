import Foundation

/// 把后端 `/export/singbox`（仅 outbounds + 顶层 version/log/dns）包成 NE 可直接跑的完整 sing-box 配置。
///
/// 后端不下发 inbounds/route（见 docs/BACKEND_INTEGRATION.md §4/§7），客户端负责补：
///   1) 去顶层 `version`（libbox 版本由扩展决定）；
///   2) 加 `tun` inbound（NE 提供 utun，libbox 接管）；
///   3) 加 `route` 规则（bypass 直连来自 /me/session 的 proxy_config，final 走主代理）；
///   4) 保留/改造 DNS。
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

    /// 包成完整配置并返回 JSON 字符串（pretty）。
    public static func build(export: [String: Any], bypass: BypassRules) throws -> String {
        guard let outbounds = export["outbounds"] as? [[String: Any]], !outbounds.isEmpty else {
            throw BuildError.noOutbounds
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

        // 3) route：bypass 直连 + final 走主代理
        var rules: [[String: Any]] = []
        if !bypass.directDomainSuffix.isEmpty {
            rules.append(["domain_suffix": bypass.directDomainSuffix, "outbound": "direct"])
        }
        if !bypass.directIPCIDR.isEmpty {
            rules.append(["ip_cidr": bypass.directIPCIDR, "outbound": "direct"])
        }
        // 私网直连（避免把局域网流量也代理）
        rules.append(["ip_is_private": true, "outbound": "direct"])
        let finalTag = firstProxyTag(outbounds) ?? "direct"
        cfg["route"] = [
            "rules": rules,
            "final": finalTag,
            "auto_detect_interface": true,
        ] as [String: Any]

        // 4) DNS：保留后端给的；缺省给一个安全默认
        if cfg["dns"] == nil {
            cfg["dns"] = [
                "servers": [["tag": "google", "address": "tls://8.8.8.8"]],
                "strategy": "prefer_ipv4",
            ] as [String: Any]
        }

        // 确保存在 direct / dns 出站（导出已含，缺则补）
        cfg["outbounds"] = ensureBaseOutbounds(outbounds)

        do {
            let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            throw BuildError.serialize(error.localizedDescription)
        }
    }

    /// 一步到位：原始导出字符串 + proxy_config → 完整配置字符串。
    public static func buildFrom(rawExport: String, proxyConfig: [String: Any]?) throws -> String {
        let export = try parseExport(rawExport)
        return try build(export: export, bypass: BypassRules.from(proxyConfig))
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

    private static func ensureBaseOutbounds(_ outbounds: [[String: Any]]) -> [[String: Any]] {
        var result = outbounds
        let types = Set(outbounds.compactMap { $0["type"] as? String })
        if !types.contains("direct") {
            result.append(["type": "direct", "tag": "direct"])
        }
        if !types.contains("dns") {
            result.append(["type": "dns", "tag": "dns-out"])
        }
        return result
    }
}
