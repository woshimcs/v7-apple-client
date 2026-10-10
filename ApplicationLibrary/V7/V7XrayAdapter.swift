import Foundation

/// 把 `/export/xray` 里的一条出站翻译成 sing-box-lx 出站。
/// Veylo 隧道核带 `with_xhttp`，所以 xhttp / REALITY 不用再开第二个 Go 进程。
public enum V7XrayAdapter {
    public enum AdapterError: LocalizedError {
        case missingLine(String)
        case unsupported(String)
        public var errorDescription: String? {
            switch self {
            case let .missingLine(tag): return "Xray 导出里没有线路 \(tag)"
            case let .unsupported(proto): return "Veylo 隧道核还不能翻译 \(proto)"
            }
        }
    }

    public static func singboxOutbound(exportJSON: String, tag: String) throws -> [String: Any] {
        let export = try V7ConfigBuilder.parseExport(exportJSON)
        guard let outbounds = export["outbounds"] as? [[String: Any]],
              let raw = outbounds.first(where: { ($0["tag"] as? String) == tag })
        else { throw AdapterError.missingLine(tag) }
        return try convert(raw, tag: tag)
    }

    private static func convert(_ raw: [String: Any], tag: String) throws -> [String: Any] {
        let proto = (raw["protocol"] as? String) ?? ""
        var outbound: [String: Any] = ["type": proto, "tag": tag]
        switch proto {
        case "vless", "vmess":
            guard let vnext = (raw["settings"] as? [String: Any])?["vnext"] as? [[String: Any]],
                  let node = vnext.first,
                  let users = node["users"] as? [[String: Any]],
                  let user = users.first,
                  let id = user["id"] as? String
            else { throw AdapterError.unsupported(proto) }
            outbound["server"] = node["address"] as? String ?? ""
            outbound["server_port"] = port(node["port"])
            outbound["uuid"] = id
            if proto == "vmess" {
                outbound["security"] = (user["security"] as? String) ?? "auto"
                outbound["alter_id"] = 0
            }
            let flow = (user["flow"] as? String) ?? ""
            if !flow.isEmpty, flow.hasPrefix("xtls-rprx-vision") {
                outbound["flow"] = "xtls-rprx-vision"
            }
        case "trojan":
            guard let servers = (raw["settings"] as? [String: Any])?["servers"] as? [[String: Any]],
                  let node = servers.first
            else { throw AdapterError.unsupported(proto) }
            outbound["server"] = node["address"] as? String ?? ""
            outbound["server_port"] = port(node["port"])
            outbound["password"] = node["password"] as? String ?? ""
        case "shadowsocks":
            outbound["type"] = "shadowsocks"
            guard let servers = (raw["settings"] as? [String: Any])?["servers"] as? [[String: Any]],
                  let node = servers.first
            else { throw AdapterError.unsupported(proto) }
            outbound["server"] = node["address"] as? String ?? ""
            outbound["server_port"] = port(node["port"])
            outbound["method"] = node["method"] as? String ?? ""
            outbound["password"] = node["password"] as? String ?? ""
        default:
            throw AdapterError.unsupported(proto.isEmpty ? "unknown" : proto)
        }
        if let stream = raw["streamSettings"] as? [String: Any] {
            apply(stream, to: &outbound)
        }
        if outbound["transport"] != nil {
            outbound.removeValue(forKey: "flow")
        }
        return outbound
    }

    private static func apply(_ stream: [String: Any], to outbound: inout [String: Any]) {
        let net = ((stream["network"] as? String) ?? "tcp").lowercased()
        switch net {
        case "ws":
            let ws = stream["wsSettings"] as? [String: Any]
            var transport: [String: Any] = ["type": "ws", "path": (ws?["path"] as? String) ?? "/"]
            if let headers = ws?["headers"] as? [String: Any], let host = headers["Host"] as? String, !host.isEmpty {
                transport["headers"] = ["Host": host]
            }
            outbound["transport"] = transport
        case "grpc":
            let grpc = stream["grpcSettings"] as? [String: Any]
            outbound["transport"] = ["type": "grpc", "service_name": (grpc?["serviceName"] as? String) ?? ""]
        case "http", "h2":
            let http = stream["httpSettings"] as? [String: Any]
            var transport: [String: Any] = ["type": "http", "path": (http?["path"] as? String) ?? "/"]
            if let host = http?["host"] as? [String], !host.isEmpty { transport["host"] = host }
            outbound["transport"] = transport
        case "xhttp", "splithttp":
            let xh = stream["xhttpSettings"] as? [String: Any]
            var transport: [String: Any] = [
                "type": "xhttp",
                "path": (xh?["path"] as? String) ?? "/",
                "mode": (xh?["mode"] as? String) ?? "auto",
            ]
            if let host = xh?["host"] as? String, !host.isEmpty { transport["host"] = host }
            outbound["transport"] = transport
        default:
            break
        }

        let security = (stream["security"] as? String) ?? ""
        if security == "tls", let tls = stream["tlsSettings"] as? [String: Any] {
            var block: [String: Any] = [
                "enabled": true,
                "server_name": (tls["serverName"] as? String) ?? "",
                "insecure": false,
            ]
            if let fp = tls["fingerprint"] as? String, !fp.isEmpty {
                block["utls"] = ["enabled": true, "fingerprint": fp]
            }
            if let alpn = tls["alpn"] as? [String], !alpn.isEmpty { block["alpn"] = alpn }
            outbound["tls"] = block
        } else if security == "reality", let reality = stream["realitySettings"] as? [String: Any] {
            // Veylo 核的 reality 只有 public_key / short_id。多写 spider_x 会让整份配置被拒绝。
            // 已接通的 REALITY 线路在官方 sing-box 上同样不带这个字段。
            outbound["tls"] = [
                "enabled": true,
                "server_name": (reality["serverName"] as? String) ?? "",
                "utls": ["enabled": true, "fingerprint": (reality["fingerprint"] as? String) ?? "chrome"],
                "reality": [
                    "enabled": true,
                    "public_key": (reality["publicKey"] as? String) ?? "",
                    "short_id": (reality["shortId"] as? String) ?? "",
                ],
            ]
        }
    }

    private static func port(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let s = value as? String, let n = Int(s) { return n }
        return 0
    }
}
