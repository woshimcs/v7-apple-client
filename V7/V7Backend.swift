import Foundation

/// V7/Veylo 后端 HTTP 客户端。
///
/// - base 从 Info.plist 的 `V7_API_BASE`（由 build setting / CI 注入）读取，**禁止硬编码生产地址**。
/// - 统一响应包 `{ success, data?, error? }`（导出端点例外，见 V7ConfigBuilder）。
/// - Bearer 取自 Keychain（[V7Keychain]）。
///
/// 说明：纯 Foundation，不依赖上游模块，可独立编译。需在 Xcode 加入 app/ApplicationLibrary target。
public enum V7Backend {
    /// 后端根地址（host 根，自己拼 /api/v1/...）。缺省回退空，调用会抛错以便尽早暴露配置缺失。
    public static var baseURL: URL? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "V7_API_BASE") as? String) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    public struct Envelope<T: Decodable>: Decodable {
        public let success: Bool
        public let data: T?
        public let error: String?
    }

    public enum V7Error: LocalizedError {
        case notConfigured
        case http(Int, String?)
        case api(String)
        case decoding(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "后端地址未配置(V7_API_BASE)"
            case let .http(code, msg): return "HTTP \(code)\(msg.map { ": \($0)" } ?? "")"
            case let .api(msg): return msg
            case let .decoding(msg): return "解析失败: \(msg)"
            }
        }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /// 发起一个带 envelope 的 JSON 请求。`authed=true` 时附带 Keychain 的 Bearer。
    public static func request<T: Decodable, B: Encodable>(
        _ path: String,
        method: String = "GET",
        body: B? = nil,
        authed: Bool = true,
        etag: String? = nil
    ) async throws -> (value: T, etag: String?, notModified: Bool) {
        guard let base = baseURL else { throw V7Error.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { req.setValue("\"\(etag)\"", forHTTPHeaderField: "If-None-Match") }
        if authed, let token = V7Keychain.token() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw V7Error.http(-1, nil) }
        let respEtag = (http.value(forHTTPHeaderField: "ETag") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if http.statusCode == 304 {
            // 调用方应保留旧值；这里用 notModified 标记。
            throw V7NotModified(etag: respEtag.isEmpty ? etag : respEtag)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8)
            throw V7Error.http(http.statusCode, msg)
        }
        do {
            let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
            guard env.success, let value = env.data else { throw V7Error.api(env.error ?? "unknown") }
            return (value, respEtag.isEmpty ? nil : respEtag, false)
        } catch let e as V7Error {
            throw e
        } catch {
            throw V7Error.decoding(error.localizedDescription)
        }
    }

    /// 便捷重载：无 body 的 GET。
    public static func get<T: Decodable>(_ path: String, authed: Bool = true, etag: String? = nil) async throws -> (value: T, etag: String?, notModified: Bool) {
        try await request(path, method: "GET", body: Optional<EmptyBody>.none, authed: authed, etag: etag)
    }

    struct EmptyBody: Encodable {}
}

/// 304 信号：调用方据此保留缓存值。
public struct V7NotModified: Error { public let etag: String? }
