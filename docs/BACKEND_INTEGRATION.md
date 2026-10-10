# 后端集成契约 + 接入点清单（iOS / Veylo）

> 对接 collections 后端（SSOT 在 `collections-gh-v7-release/server`）。本文件是 iOS 端接后端的
> **唯一参照**：契约字段、调用顺序、客户端职责、以及关键 Swift 代码草稿。
>
> 现状：**契约已核对**（2026-06-23，对照 `server/src/routes` + `server/src/services`）。
> 代码草稿用于 Mac/Xcode 落地时参考，**未在非 mac 环境编译验证**。

---

## 0. 调用链总览

```
POST /api/v1/auth/login         (device_name + client_platform=ios) → Bearer 存 Keychain
  → GET /api/v1/me/session?platform=ios&include=exports,proxy,notices   // 启动全量
  → GET /api/v1/me/session?platform=ios                                  // 轮询(minimal)
  → 取 subscriptions[].export_links.singbox（或 /me/subscriptions/:id）
  → GET .../collections/token/:token/export/singbox    // 返回 outbounds(无 inbounds/route)
  → V7ConfigBuilder：补 TUN inbound + route 规则(含 proxy_config) + DNS → 交给 NE/libbox
  → (可选) GET /api/v1/public/clients   // 检查更新
```

所有需登录接口带 `Authorization: Bearer v7t_...`。JSON 字段 **snake_case**。
统一响应包 `{ success: boolean, data?: T, error?: string }`（**导出端点例外**，见 §4）。

---

## 1. 登录 `POST /api/v1/auth/login`

请求体（snake_case）：

| 字段 | 必填 | 说明 |
|---|---|---|
| `username` | 是 | 用户名或邮箱（含 `@` 按邮箱匹配） |
| `password` | 是 | |
| `device_name` | 否 | **传此字段才签发 Bearer**；不传仅 cookie session |
| `client_platform` | 否 | 拼进 token 名称，iOS 传 `"ios"`（如 `"iPhone 15 (ios)"`） |

成功响应 `data`：`user{ id, username, role, email, tier_code, tier_name, vpn_enabled, ... }`、
`token`（`v7t_<22>.<32>`，仅 device_name 模式）、`token_id`、`token_expires_at`（默认 `null` 永不过期）。

**iOS 做法**：登录传 `device_name`（设备名）+ `client_platform:"ios"`，把 `token` 存 Keychain，
后续所有请求带 `Authorization: Bearer <token>`。

---

## 2. 会话闸门 `GET /api/v1/me/session`（entitlement SSOT，推荐）

Query：
- `platform=ios`（**后端待补**：当前仅 android/windows/macos；见 §6 缺口。一期可暂传占位或用 `/auth/me`）。
- `include=exports,proxy,notices`：省略 = minimal（不含 `export_links` 正文，省流量，用于轮询）。

Headers：`If-None-Match: "<revision>"` → 未变返回 `304`。

响应关键字段（`meEntitlementService.buildSession()`）：

| 字段 | 说明 |
|---|---|
| `revision` | ETag 用 |
| `account.vpn_enabled` / `vpn_enabled_at` | 账号 VPN 开关 |
| `account.min_supported_version` | 强制升级阈值（客户端比对本地版本，服务端不 403） |
| `account.force_logout_before` | 早于此签发的 token 失效 |
| `vpn_access.allowed` | 是否允许连 |
| `vpn_access.deny_reason` | `vpn_disabled` / `all_expired` / `all_revoked` / `no_subscriptions` |
| `vpn_access.next_poll_after_sec` | 轮询间隔（默认 1800s） |
| `subscriptions[]` | 见 §3，含 `export_links.singbox` |
| `client_actions[]` | 见下 |

`client_actions` 语义：
- allowed + 有可导出订阅：`['refresh_nodes']`
- denied：`['disconnect_vpn','purge_nodes','notify_user']`（若 `vpn_disabled` 再加 `'lock_vpn_ui'`）

**iOS 做法**：启动拉 full（含 exports/proxy/notices），之后按 `next_poll_after_sec` 轮询 minimal；
`vpn_access.allowed=false` 时按 `client_actions` 断连 + 清节点 + 提示，不允许用户连。

---

## 3. 订阅 `GET /api/v1/me/subscriptions`

- 列表 `GET /` → `{ success, data: MeSubscriptionDto[] }`
- 单条 `GET /:id`、线路 `GET /:id/lines`（`seq,name,region_code,region_name,region_emoji,tags[]`）

`MeSubscriptionDto` 关键字段：`id,name,slug,status(normal|expired|revoked),valid_from,valid_until,
route_count,export_allowed,export_links{ singbox, ... },visibility,org_id,org_name`。

`export_links.singbox` 形如：`{base}/api/v1/collections/token/{token}/export/singbox`。
expired/revoked → `export_allowed=false` 且 minimal 模式下 `export_links=null`。

---

## 4. 导出 sing-box 配置 `/export/singbox`

| 路径 | 鉴权 | 用途 |
|---|---|---|
| `GET /api/v1/collections/token/:token/export/singbox` | token 即凭证 | **客户端主路径** |
| `GET /api/v1/collections/slug/:slug/export/singbox` | 无（公开） | 调试 |

响应：`Content-Type: application/json`，body 是 **sing-box 配置 JSON 字符串本身**（非 `{success,data}` 包装），
`Cache-Control: no-store`。无效/过期 token 仍返回 200，内容是「无效订阅」占位配置。

**后端只产出 `outbounds`（节点）+ 顶层 `version`/`log`/`dns`**，**没有 `inbounds`、没有 `route`**。
后端已做的规范化（iOS 可直接消费）：`finger_print→fingerprint`、REALITY 补齐（`public_key/short_id`）、
SS plugin 规范化、VLESS raw_uri 字段合并、`ss→shadowsocks` 别名、transport 结构、anytls TLS 默认。

> 客户端务必用 `fingerprint`（非旧键 `finger_print`），sing-box 1.13 会忽略旧键。

---

## 5. 客户端版本/下载 `GET /api/v1/public/clients`、`/public/version`

- `/public/version` → `{ server, git_commit, build_time, display_version, db_schema_version }`
  （动手前核对 `git_commit` 判断线上真实代码，见 agent-charter）。
- `/public/clients?channel=stable|beta` → 每 platform 最新 `is_active` 一条；
  字段 `platform,version,version_code,download_url,sha256,release_notes,min_supported,published_at`。
  **iOS 的 `download_url` 填 TestFlight 链接**。

---

## 6. 后端 iOS 缺口（collections 侧需小改，已在本次一并处理）

| 缺口 | 现状 | 处理 |
|---|---|---|
| `/me/session?platform=ios` | 无映射（仅 android/windows/macos） | collections 加 `platform=ios` 分支 |
| `mobile_min_ios_version` | app_config 无此键 | collections 加 migration + 键 |
| `latestClientVersion()` 含 ios | 仅查 android/windows/macos | collections 纳入 ios |
| `POST /admin/releases` `platform=ios` | **已在白名单**（`appReleaseService`） | 无需改 |

落地见 collections 同批 PR（`Related to` 本端 planning issue）。

---

## 7. 客户端职责：config builder（最关键）

后端给的是 `outbounds`，iOS 必须本地拼出完整 sing-box 配置：

1. **strip / 忽略**后端配置顶层 `version`（libbox 由扩展给定，避免版本字段冲突）。
2. 加 **`inbounds`**：一个 `tun` inbound（NE 提供 utun fd，libbox 接管）。
3. 加 **`route`** 规则：
   - 默认走代理 outbound；
   - bypass 规则来自 `/me/session?include=proxy` 的 `proxy_config`（直连域名/IP 段）；
   - `final` 指向主代理 outbound。
4. **DNS**：按客户端策略改造（fakeip 或指定上游），避免污染。
5. 复用桌面 `v7-win-pc/src-tauri/src/vpn.rs` 已验证的规范化逻辑（同一套规则，避免跨端踩坑）。

---

## 8. Swift 代码草稿（落地参考，未编译验证）

> 放 `V7/` 目录或 `V7*` 前缀文件，不改 upstream（除非挂载点必须，记 PATCHES）。
> 网络层可用 `URLSession`；token 存 Keychain。以下为骨架，Mac 上按上游既有风格调整。

### 8.1 `V7/V7Backend.swift` — API 客户端骨架

```swift
import Foundation

/// V7/Veylo 后端客户端。base 从 build setting 注入(V7_API_BASE)，禁止硬编码生产地址。
enum V7Backend {
    static var baseURL: URL {
        // Info.plist 注入 V7_API_BASE，如 https://veylo.link
        let s = Bundle.main.object(forInfoDictionaryKey: "V7_API_BASE") as? String ?? ""
        return URL(string: s)!
    }

    struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let data: T?
        let error: String?
    }

    static func request<T: Decodable>(
        _ path: String, method: String = "GET",
        body: Encodable? = nil, authed: Bool = true
    ) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authed, let token = V7Keychain.token() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = try JSONEncoder().encode(AnyEncodable(body)) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw V7Error.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard env.success, let d = env.data else { throw V7Error.api(env.error ?? "unknown") }
        return d
    }
}

enum V7Error: Error { case http(Int), api(String) }
```

### 8.2 `V7/V7Keychain.swift` — Bearer 存取（Keychain）

```swift
import Security
import Foundation

/// Bearer token 存 Keychain，不落明文/UserDefaults。
enum V7Keychain {
    private static let account = "v7.bearer"
    private static let service = "link.veylo.ios"   // 对齐最终 Bundle ID

    static func save(_ token: String) {
        let data = Data(token.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func token() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
```

### 8.3 `V7/V7Session.swift` — 登录 + 会话闸门 DTO

```swift
import Foundation

struct V7LoginReq: Encodable {
    let username, password: String
    let device_name: String
    let client_platform = "ios"
}
struct V7LoginData: Decodable { let token: String? }

struct V7Session: Decodable {
    struct Account: Decodable {
        let vpn_enabled: Bool
        let min_supported_version: String?
        let force_logout_before: String?
    }
    struct VpnAccess: Decodable {
        let allowed: Bool
        let deny_reason: String?
        let next_poll_after_sec: Int?
    }
    let revision: String
    let account: Account
    let vpn_access: VpnAccess
    let client_actions: [String]
    let subscriptions: [V7Subscription]
}

struct V7Subscription: Decodable {
    let id, name, status: String
    let valid_until: String?
    let export_allowed: Bool
    let export_links: ExportLinks?
    struct ExportLinks: Decodable { let singbox: String? }
}

enum V7Api {
    static func login(_ user: String, _ pass: String, device: String) async throws {
        let d: V7LoginData = try await V7Backend.request(
            "/api/v1/auth/login", method: "POST",
            body: V7LoginReq(username: user, password: pass, device_name: device),
            authed: false)
        if let t = d.token { V7Keychain.save(t) }
    }

    static func session(full: Bool) async throws -> V7Session {
        let inc = full ? "&include=exports,proxy,notices" : ""
        return try await V7Backend.request("/api/v1/me/session?platform=ios\(inc)")
    }
}
```

### 8.4 `V7/V7ConfigBuilder.swift` — 拉导出 + 包 inbound/route/DNS

```swift
import Foundation

/// 拉 /export/singbox(只有 outbounds)，本地补 TUN inbound + route + DNS，产出 NE 可用的完整配置。
enum V7ConfigBuilder {
    /// 注意：导出端点返回的是裸 JSON 字符串(非 envelope)，单独处理。
    static func fetchExport(tokenURL: URL) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: tokenURL)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// 把后端配置(outbounds-only)包成完整 sing-box 配置。
    /// - proxyConfig: 来自 /me/session?include=proxy 的 bypass 规则(直连域名/IP)。
    static func build(from export: [String: Any], proxyConfig: [String: Any]?) -> [String: Any] {
        var cfg = export
        cfg.removeValue(forKey: "version")          // 1) 去顶层 version

        // 2) TUN inbound(fd 由 NE 注入；具体键沿用上游 ApplicationLibrary 既有写法)
        cfg["inbounds"] = [[
            "type": "tun",
            "tag": "tun-in",
            "auto_route": true,
            "strict_route": true,
            "stack": "system",
        ]]

        // 3) route：bypass(直连) + final 走代理
        var rules: [[String: Any]] = []
        if let direct = proxyConfig?["direct_domains"] as? [String], !direct.isEmpty {
            rules.append(["domain_suffix": direct, "outbound": "direct"])
        }
        if let directIP = proxyConfig?["direct_ip_cidr"] as? [String], !directIP.isEmpty {
            rules.append(["ip_cidr": directIP, "outbound": "direct"])
        }
        cfg["route"] = ["rules": rules, "final": firstProxyTag(export) ?? "direct", "auto_detect_interface": true]

        // 4) DNS：保留后端 dns 或按策略改造(fakeip 等)，此处沿用后端给的 dns
        return cfg
    }

    private static func firstProxyTag(_ export: [String: Any]) -> String? {
        guard let obs = export["outbounds"] as? [[String: Any]] else { return nil }
        let skip: Set<String> = ["direct", "dns", "block"]
        return obs.first { !skip.contains(($0["type"] as? String) ?? "") }?["tag"] as? String
    }
}
```

> 上面是**对接点骨架**，真正 TUN inbound 字段 / NE fd 注入 / libbox 调用方式以上游
> `ApplicationLibrary` + `Extension` 既有实现为准（Mac 上对照调整）。重点是 V7 只**替换配置来源**
> （从本地导入文件 → 改为 V7 后端订阅拉取 + builder 包裹），不重写 NE/libbox 通路。

---

## 9. 接入点清单（Mac 落地 checklist）

> §8 的草稿已**提升为真实源文件**（见下「已落代码」）。§8 仅保留作为契约/思路注释；
> 以仓库 `V7/` 下实际文件为准。剩余项需 **Mac + Xcode + NE entitlement** 落地，见 `docs/PREREQUISITES.md`。

### A. 已落代码（PR `feat/backend-integration`，纯新增不动上游）

- [x] `V7/V7Backend.swift`：envelope HTTP 客户端（`V7_API_BASE` from Info.plist、Bearer、ETag/304）。
- [x] `V7/V7Keychain.swift`：Bearer 存取 Keychain。
- [x] `V7/V7Session.swift`：login / session DTO + `V7Api.login/session/logout`。
- [x] `V7/V7ConfigBuilder.swift`：导出(outbounds) → 补 TUN inbound + route(含 bypass) + DNS（纯函数，可单测）。
- [x] `V7/V7ProfileBridge.swift`：拉导出 → `LibboxCheckConfig` 校验 → 写 `configs/config_<id>.json` local profile →
      `SharedPreferences.selectedProfileID` → `ExtensionProfile.install/load/start/stop`。**复用上游 NE 通路，不自研。**
- [x] `V7/V7AppState.swift`：登录态 + session 轮询(`next_poll_after_sec`) + `client_actions` 执行 + 强升级判定 + 连接编排。
- [x] `V7/V7LoginView.swift`：SwiftUI 登录页。
- [x] `.github/workflows/release-ios.yml`：archive(SFI) → export(app-store) → TestFlight → 回填 `/admin/releases`。

### B. Mac 落地剩余（需 Xcode 工程操作 / 真机）

- [ ] **加 target membership**：把 `V7/*.swift` 加入 SFI（及共享逻辑所在的 ApplicationLibrary）target 的 Compile Sources。
      `V7ProfileBridge` 需链接 `Library` + `Libbox` 模块。
- [ ] **Info.plist 注入 `V7_API_BASE`**：加 `<key>V7_API_BASE</key><string>$(V7_API_BASE)</string>`，
      build setting / CI（workflow 已传 `V7_API_BASE=...`）注入值。**这步改 Info.plist → 落地时记 `V7_PATCHES.md`。**
- [ ] **挂登录闸门**：`ApplicationLibrary` 根视图按 `V7AppState.shared.isLoggedIn` 切换 `V7LoginView` / 上游主界面。
- [ ] **锁连接 UI**：`vpnAccessAllowed=false` 时禁用上游连接按钮，并展示 `denyReason` / 升级引导。
- [ ] **连接改走 V7**：上游「连接」动作改调用 `V7AppState.connectFirstAvailable()`（内部 `V7ProfileBridge.syncAndStart`）。
- [ ] **校验 sing-box 字段**：在真机上确认 `V7ConfigBuilder` 产出的 TUN inbound/route/DNS 与上游 NE 期望一致
      （上游 `prepareStartOptions` 还会注入 `autoRouteUseSubRangesByDefault` 等，注意不要与配置内 route 冲突）。
- [ ] **CI Secrets**：按 `docs/PREREQUISITES.md §5` 配齐 `APPLE_API_*` / `IOS_DIST_CERT_*` / `IOS_*PROVISION*` / `V7_ADMIN_*`。
