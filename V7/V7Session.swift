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
    public let id: String
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

    /// 退出登录：清 Keychain。
    public static func logout() {
        V7Keychain.clear()
    }
}
