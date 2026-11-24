import Foundation
import Security

/// Bearer token 的 Keychain 存取（不落 UserDefaults/明文）。
///
/// service 用 App Group 关联的稳定标识；若主 app 与扩展需共享 token，可改用
/// `kSecAttrAccessGroup`（App Group keychain sharing），见 docs/PREREQUISITES.md。
public enum V7Keychain {
    private static let service = "link.veylo.ios"   // 对齐 BASE_PACKAGE_IDENTIFIER
    private static let account = "v7.bearer"

    public static func save(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func token() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    public static var hasToken: Bool { token() != nil }

    // MARK: - 设备标识（x-hwid）

    private static let hwidAccount = "v7.hwid"

    /// 本机稳定的设备标识。存 Keychain（登出不清，重装 App 通常也还在），流量上报的 x-hwid 用它。
    public static func hwid() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hwidAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data,
           let str = String(data: data, encoding: .utf8), str.count >= 8
        {
            return str
        }
        let fresh = "ios-" + UUID().uuidString.lowercased()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hwidAccount,
            kSecValueData as String: Data(fresh.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(add as CFDictionary, nil)
        return fresh
    }

    public static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
