import Foundation

// MARK: - DTOs（对齐 collections 后端 snake_case；见 docs/BACKEND_INTEGRATION.md）

public struct V7LoginRequest: Encodable {
    public let username: String
    public let password: String
    public let device_name: String
    public let client_platform: String

    public init(username: String, password: String, deviceName: String) {
        self.username = username
        self.password = password
        device_name = deviceName
        client_platform = "ios"
    }
}

public struct V7LoginData: Decodable {
    public let token: String?
    public let token_id: String?
    public let token_expires_at: String?
}

public struct V7Account: Decodable {
    public let vpn_enabled: Bool
    public let vpn_enabled_at: String?
    public let min_supported_version: String?
    public let force_logout_before: String?
}

public struct V7VpnAccess: Decodable {
    public let allowed: Bool
    public let deny_reason: String?
    public let hard_deadline_at: String?
    public let next_poll_after_sec: Int?
}

public struct V7ExportLinks: Decodable {
    public let singbox: String?
}

public struct V7Subscription: Decodable, Identifiable {
    public let id: Int
    public let name: String
    public let slug: String?
    public let status: String          // normal | expired | revoked
    public let valid_from: String?
    public let valid_until: String?
    public let route_count: Int?
    public let export_allowed: Bool
    public let export_links: V7ExportLinks?
}

public struct V7Session: Decodable {
    public let revision: String
    public let server_time: String?
    public let account: V7Account
    public let vpn_access: V7VpnAccess
    public let subscriptions: [V7Subscription]
    public let client_actions: [String]
}

/// client_actions 枚举（与 meEntitlementService.computeClientActions 对齐）。
public enum V7ClientAction: String {
    case none
    case refreshNodes = "refresh_nodes"
    case disconnectVpn = "disconnect_vpn"
    case purgeNodes = "purge_nodes"
    case notifyUser = "notify_user"
    case lockVpnUi = "lock_vpn_ui"
}

// MARK: - API

public enum V7Api {
    /// 登录：传 device_name 才签发 Bearer；成功后存 Keychain。
    public static func login(username: String, password: String, deviceName: String) async throws {
        let body = V7LoginRequest(username: username, password: password, deviceName: deviceName)
        let (data, _, _): (V7LoginData, String?, Bool) =
            try await V7Backend.request("/api/v1/auth/login", method: "POST", body: body, authed: false)
        guard let token = data.token, !token.isEmpty else {
            throw V7Backend.V7Error.api("登录成功但未签发 token(需传 device_name)")
        }
        V7Keychain.save(token)
    }

    /// 拉会话。full=启动全量(含 exports/proxy/notices)，否则 minimal(轮询)。
    /// 支持 ETag：传入上次 etag，若 304 抛 V7NotModified(调用方保留旧 session)。
    public static func session(full: Bool, etag: String? = nil) async throws -> (V7Session, String?) {
        let include = full ? "&include=exports,proxy,notices" : ""
        let path = "/api/v1/me/session?platform=ios\(include)"
        let (value, newEtag, _): (V7Session, String?, Bool) = try await V7Backend.get(path, etag: etag)
        return (value, newEtag)
    }

    /// 退出登录：先吊销服务端 token，再清 Keychain。
    public static func logout() async {
        try? await V7Backend.postVoid("/api/v1/auth/logout")
        V7Keychain.clear()
    }

    public static func heartbeat() async {
        try? await V7Backend.postVoid("/api/v1/me/devices/heartbeat")
    }

    public static func subscriptions() async throws -> [V7MySubscription] {
        let (rows, _, _): ([V7MySubscription], String?, Bool) = try await V7Backend.get("/api/v1/me/subscriptions")
        return rows
    }

    public static func subscriptionLines(_ id: Int) async throws -> [V7LineMeta] {
        let (rows, _, _): ([V7LineMeta], String?, Bool) = try await V7Backend.get("/api/v1/me/subscriptions/\(id)/lines")
        return rows
    }

    public static func proxyConfig() async throws -> [String: Any] {
        try await V7Backend.getObject("/api/v1/me/proxy-config")
    }

    public static func me() async throws -> V7User {
        let (payload, _, _): (V7MePayload, String?, Bool) = try await V7Backend.get("/api/v1/auth/me")
        guard let user = payload.user else { throw V7Backend.V7Error.api("服务端响应缺 user") }
        return user
    }

    public static func notices() async throws -> [V7Notice] {
        let (rows, _, _): ([V7Notice], String?, Bool) = try await V7Backend.get("/api/v1/me/notices?platform=ios")
        return rows
    }

    public static func latestIOSRelease() async throws -> V7ClientRelease? {
        let (payload, _, _): (V7PublicClients, String?, Bool) = try await V7Backend.get("/api/v1/public/clients", authed: false)
        return payload.clients?.first { $0.platform == "ios" }
    }

    public static func plans() async throws -> [V7Plan] {
        let (rows, _, _): ([V7Plan], String?, Bool) = try await V7Backend.get("/api/v1/billing/me/visible-plans")
        return rows
    }

    public static func tickets() async throws -> [V7Ticket] {
        let (rows, _, _): ([V7Ticket], String?, Bool) = try await V7Backend.get("/api/v1/support/tickets")
        return rows
    }

    public static func createTicket(subject: String, body: String) async throws {
        let payload = V7NewTicket(subject: subject, body: body)
        let (_, _, _): (V7Ticket, String?, Bool) = try await V7Backend.request("/api/v1/support/tickets", method: "POST", body: payload)
    }

    public static func registerChallenge() async throws -> V7RegisterChallenge {
        let (value, _, _): (V7RegisterChallenge, String?, Bool) = try await V7Backend.get("/api/v1/auth/register/challenge", authed: false)
        return value
    }

    public static func registerStart(email: String, challengeId: String?, answer: String?) async throws {
        let body = V7RegisterStart(email: email, challenge_id: challengeId, challenge_answer: answer, website: "")
        try await V7Backend.postVoid("/api/v1/auth/register/start", body: body, authed: false)
    }

    public static func registerVerify(email: String, code: String, username: String, password: String) async throws {
        let body = V7RegisterVerify(email: email, code: code, username: username, password: password)
        try await V7Backend.postVoid("/api/v1/auth/register/verify", body: body, authed: false)
    }

    public static func resetStart(email: String) async throws {
        try await V7Backend.postVoid("/api/v1/auth/password-reset/start", body: V7ResetStartBody(email: email), authed: false)
    }

    public static func resetVerify(email: String, code: String, newPassword: String) async throws {
        try await V7Backend.postVoid("/api/v1/auth/password-reset/verify", body: V7ResetVerify(email: email, code: code, new_password: newPassword), authed: false)
    }
}

public struct V7MySubscription: Decodable {
    public let id: Int
    public let name: String?
    public let status: String?
    public let export_allowed: Bool?
    public let export_links: V7ExportLinks?
    public init(id: Int, name: String?, status: String?, export_allowed: Bool?, export_links: V7ExportLinks?) {
        self.id = id
        self.name = name
        self.status = status
        self.export_allowed = export_allowed
        self.export_links = export_links
    }
}

public struct V7LineMeta: Decodable {
    public let name: String?
    public let region_name: String?
    public let region_emoji: String?
    public let singbox_ok: Bool?
    public let cores: [String]?
    public let best_core: String?
    public let stealth_primary: Bool?
}

public struct V7MePayload: Decodable { public let user: V7User? }
public struct V7User: Decodable {
    public let username: String?
    public let role: String?
    public let email: String?
    public let created_at: String?
    public let vpn_enabled: Bool?
    public let tier_name: String?
    public let tier_code: String?
}

public struct V7Notice: Decodable, Identifiable {
    public let id: String
    public let title: String?
    public let body: String?
    public let level: String?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.flexID(c, key: .id) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        level = try c.decodeIfPresent(String.self, forKey: .level)
    }
    private enum CodingKeys: String, CodingKey { case id, title, body, level }
    static func flexID<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty { return s }
        if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return String(n) }
        return nil
    }
}

public struct V7PublicClients: Decodable { public let clients: [V7ClientRelease]? }
public struct V7ClientRelease: Decodable {
    public let platform: String?
    public let version: String?
    public let download_url: String?
    public let release_notes: String?
}

public struct V7Plan: Decodable, Identifiable {
    public let id: String
    public let name: String?
    public let tagline: String?
    public let interval: String?
    public let currency: String?
    public let list_price_cents: String?
    public let already_owned: Bool?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = V7Notice.flexID(c, key: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name)
        tagline = try c.decodeIfPresent(String.self, forKey: .tagline)
        interval = try c.decodeIfPresent(String.self, forKey: .interval)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        if let s = try c.decodeIfPresent(String.self, forKey: .list_price_cents) { list_price_cents = s }
        else if let n = try c.decodeIfPresent(Int.self, forKey: .list_price_cents) { list_price_cents = String(n) }
        else { list_price_cents = nil }
        already_owned = try c.decodeIfPresent(Bool.self, forKey: .already_owned)
    }
    private enum CodingKeys: String, CodingKey { case id, name, tagline, interval, currency, list_price_cents, already_owned }
}

public struct V7Ticket: Decodable, Identifiable {
    public let id: String
    public let ticket_no: Int?
    public let subject: String?
    public let status: String?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = V7Notice.flexID(c, key: .id) ?? UUID().uuidString
        ticket_no = try c.decodeIfPresent(Int.self, forKey: .ticket_no)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }
    private enum CodingKeys: String, CodingKey { case id, ticket_no, subject, status }
}

public struct V7NewTicket: Encodable {
    public let subject: String
    public let body: String
    public let source_client: String
    public init(subject: String, body: String) {
        self.subject = subject
        self.body = body
        source_client = "ios"
    }
}

public struct V7RegisterChallenge: Decodable {
    public let challenge_id: String?
    public let prompt: String?
}

public struct V7RegisterStart: Encodable {
    public let email: String
    public let challenge_id: String?
    public let challenge_answer: String?
    public let website: String
}

public struct V7RegisterVerify: Encodable {
    public let email: String
    public let code: String
    public let username: String
    public let password: String
}

public struct V7ResetStartBody: Encodable { public let email: String }
public struct V7ResetStart: Decodable { public let delivered: Bool? }
public struct V7ResetVerify: Encodable {
    public let email: String
    public let code: String
    public let new_password: String
}
public struct V7ResetDone: Decodable { public let username: String? }
