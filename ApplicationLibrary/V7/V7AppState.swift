import Combine
import Foundation
import Library
import NetworkExtension
import SwiftUI

/// V7/Veylo 应用态协调：登录态、会话轮询、闸门（client_actions / 强制升级）与连接编排。
///
/// 作为上游 UI 之上的一层「登录闸门 + VPN 准入」。挂载方式见 docs/BACKEND_INTEGRATION.md §9：
/// 在 ApplicationLibrary 根视图按 `isLoggedIn` 决定显示 [V7LoginView] 还是上游主界面，
/// 并在 `vpnAccessAllowed=false` 时锁住连接 UI。
@MainActor
public final class V7AppState: ObservableObject {
    public static let shared = V7AppState()

    @Published public private(set) var isLoggedIn: Bool
    @Published public private(set) var session: V7Session?
    @Published public private(set) var lastError: String?
    /// 后端判定是否允许连 VPN（false 时应禁用/锁住连接按钮）。
    @Published public private(set) var vpnAccessAllowed: Bool = false
    @Published public private(set) var denyReason: String?
    /// 本地版本低于 min_supported_version 时为 true（引导更新）。
    @Published public private(set) var upgradeRequired: Bool = false
    @Published public private(set) var lines: [V7ConfigBuilder.Line] = []
    @Published public private(set) var selectedLineId: String?
    @Published public private(set) var connecting = false
    @Published public private(set) var vpnStatus: NEVPNStatus = .invalid
    @Published public private(set) var username: String?
    @Published public private(set) var profile: V7User?
    @Published public private(set) var notices: [V7Notice] = []
    @Published public var autoLineSwitch: Bool
    @Published public private(set) var bypass = V7ConfigBuilder.BypassRules()
    /// CF-23：本周期额度（最紧张的团队）。服务端不支持或还没拉到时为 nil。
    @Published public private(set) var quota: V7QuotaView?
    /// 待弹出的超额 / 接近超额提示（同一账户、团队、周期、状态只弹一次）。
    @Published public var quotaPrompt: V7QuotaView?
    @Published public private(set) var quotaPurchasePath: String?
    /// 线路 route_id，按订阅分。连接时写给扩展，用量样本带上（CF-23）。
    private var routeIds: [Int: [String: Int]] = [:]
    private var quotaSupported = true
    private var lastSummaryAt: Date?
    private var uploadTask: Task<Void, Never>?

    private var sessionEtag: String?
    private var pollTask: Task<Void, Never>?
    private var statusBag = Set<AnyCancellable>()
    private var tunnel: ExtensionProfile?
    private let lineKey = "v7.selectedLineId"
    private let userKey = "v7.username"
    private let autoKey = "v7.autoLineSwitch"

    private init() {
        isLoggedIn = V7Keychain.hasToken
        selectedLineId = UserDefaults.standard.string(forKey: lineKey)
        username = UserDefaults.standard.string(forKey: userKey)
        if UserDefaults.standard.object(forKey: autoKey) == nil {
            autoLineSwitch = true
        } else {
            autoLineSwitch = UserDefaults.standard.bool(forKey: autoKey)
        }
    }

    // MARK: - 登录 / 登出

    public func login(username: String, password: String) async {
        lastError = nil
        do {
            try await V7Api.login(username: username, password: password, deviceName: Self.deviceName())
            self.username = username
            UserDefaults.standard.set(username, forKey: userKey)
            isLoggedIn = true
            await refresh(full: true)
            startPolling()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoggedIn = false
        }
    }

    public func logout() async {
        pollTask?.cancel(); pollTask = nil
        uploadTask?.cancel(); uploadTask = nil
        try? await V7ProfileBridge.stop()
        // 不等上传（桌面 1.0.81 教训）。已封的批次留在 App Group，同一账户再登录时传。
        V7TrafficReporter.clearOwner()
        await V7Api.logout()
        session = nil
        sessionEtag = nil
        lines = []
        routeIds = [:]
        profile = nil
        notices = []
        quota = nil
        quotaPrompt = nil
        quotaSupported = true
        lastSummaryAt = nil
        vpnAccessAllowed = false
        username = nil
        UserDefaults.standard.removeObject(forKey: userKey)
        isLoggedIn = false
    }

    // MARK: - 会话

    /// 拉一次会话并应用闸门。full=启动全量，否则 minimal（轮询）。
    public func refresh(full: Bool) async {
        guard isLoggedIn else { return }
        do {
            let (s, etag) = try await V7Api.session(full: full, etag: full ? nil : sessionEtag)
            sessionEtag = etag ?? sessionEtag
            let resync = await apply(session: s)
            applySessionQuota(s.traffic_quota)
            if full || resync {
                await syncCatalog()
            }
            if full {
                await loadAccount()
                await V7Api.heartbeat()
                await refreshQuota(force: true)
            }
            uploadTraffic()
        } catch is V7NotModified {
            // 未变化，保留旧 session
        } catch let V7Backend.V7Error.http(code, _) where code == 401 {
            // token 失效 / force_logout
            await logout()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 应用闸门。返回 true 表示这次要重拉全部线路（refresh_nodes）。
    private func apply(session s: V7Session) async -> Bool {
        session = s
        vpnAccessAllowed = s.vpn_access.allowed
        denyReason = s.vpn_access.deny_reason
        upgradeRequired = Self.isOutdated(local: Self.appVersion(), min: s.account.min_supported_version)
        if upgradeRequired {
            // CF-05：过旧版本不能用。断开并锁住连接，界面引导去 TestFlight / App Store 更新。
            try? await V7ProfileBridge.stop()
        }

        let actions = Set(s.client_actions.compactMap { V7ClientAction(rawValue: $0) })
        if actions.contains(.lockVpnUi) {
            vpnAccessAllowed = false
        }
        if actions.contains(.notifyUser), let reason = s.vpn_access.deny_reason, !reason.isEmpty {
            lastError = reason
        }
        if actions.contains(.disconnectVpn) || !s.vpn_access.allowed {
            try? await V7ProfileBridge.stop()
        }
        if actions.contains(.purgeNodes) {
            try? await V7ProfileBridge.purge()
            lines = []
            setSelected(nil)
        }
        return actions.contains(.refreshNodes)
    }

    /// 后台轮询：按 next_poll_after_sec（缺省 1800s）拉 minimal。另起一个 2 分钟的上传循环（App 在前台时才会跑）。
    public func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, await self.isLoggedIn {
                let secs = await self.session?.vpn_access.next_poll_after_sec ?? 1800
                try? await Task.sleep(nanoseconds: UInt64(max(60, secs)) * NSEC_PER_SEC)
                if Task.isCancelled { break }
                await self.refresh(full: false)
            }
        }
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            while let self, !Task.isCancelled, await self.isLoggedIn {
                try? await Task.sleep(nanoseconds: 120 * NSEC_PER_SEC)
                if Task.isCancelled { break }
                await self.uploadTraffic()
            }
        }
    }

    /// 回到前台：轻量刷新会话、额度，上传扩展在后台攒下的用量。
    public func onForeground() async {
        guard isLoggedIn else { return }
        await bindTunnel()
        uploadTraffic()
        await refresh(full: false)
        await refreshQuota(force: false)
    }

    // MARK: - 用量上报（CF-21）

    private var ownerKey: String? {
        if let id = profile?.id, !id.isEmpty { return "id:\(id)" }
        if let name = profile?.username ?? username, !name.isEmpty { return "name:\(name)" }
        return nil
    }

    private var ownerKeys: [String] {
        V7TrafficOwner.keys(userId: profile?.id, username: profile?.username ?? username)
    }

    /// 不等结果。隧道没在跑时顺带封掉扩展遗留的 open.json。
    public func uploadTraffic() {
        guard isLoggedIn else { return }
        let idle = vpnStatus == .disconnected || vpnStatus == .invalid
        V7TrafficReporter.uploadInBackground(ownerKeys: ownerKeys, tunnelIdle: idle)
    }

    // MARK: - 额度（CF-23）

    /// GET /me/traffic/summary，节流 60 秒。失败不抛；404 表示服务端还没有额度功能，不再显示。
    public func refreshQuota(force: Bool) async {
        guard isLoggedIn, quotaSupported else { return }
        if !force, let last = lastSummaryAt, Date().timeIntervalSince(last) < 60 { return }
        lastSummaryAt = Date()
        do {
            let summary = try await V7Api.trafficSummary()
            quotaPurchasePath = V7Quota.safePath(summary.purchase_path)
            let rows = (summary.orgs ?? []).map { V7QuotaView($0) }
            setQuota(V7Quota.tightest(rows))
        } catch let V7Backend.V7Error.http(code, _) where code == 404 {
            quotaSupported = false
            quota = nil
        } catch {
            // 网络问题：保留上次的数字
        }
    }

    private func applySessionQuota(_ q: V7SessionQuota?) {
        guard let q, quotaSupported else { return }
        quotaPurchasePath = V7Quota.safePath(q.purchase_path)
        let name = quota?.orgId == q.org_id ? (quota?.orgName ?? "") : ""
        setQuota(V7QuotaView(q, orgName: name))
    }

    private func setQuota(_ q: V7QuotaView?) {
        quota = q
        guard let q else { return }
        let uid = profile?.id ?? username ?? ""
        if V7Quota.shouldPrompt(userId: uid, q) {
            quotaPrompt = q
        }
    }

    public var quotaPurchaseURL: URL? { V7Quota.purchaseURL(path: quotaPurchasePath) }
    public var quotaDetailURL: URL? { V7Quota.detailURL() }

    // MARK: - 连接编排

    /// 全部有效订阅 + /lines 元数据。已选线路消失且正在连接时先断开。
    public func syncCatalog() async {
        do {
            let result = try await V7Catalog.sync(fallback: session?.subscriptions ?? [])
            let wasConnected = vpnStatus == .connected || vpnStatus == .connecting
            let previous = selectedLineId
            lines = result.lines
            routeIds = result.routeIds
            bypass = V7ConfigBuilder.BypassRules.from(result.proxy)
            if let previous, lines.contains(where: { $0.id == previous }) {
                setSelected(previous)
            } else {
                if wasConnected, previous != nil {
                    try? await V7ProfileBridge.stop()
                }
                setSelected(lines.first(where: { $0.veyloRunnable })?.id ?? lines.first?.id)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func loadLines() async { await syncCatalog() }

    public func loadAccount() async {
        guard isLoggedIn else { return }
        if let user = try? await V7Api.me() {
            profile = user
            if let name = user.username, !name.isEmpty {
                username = name
                UserDefaults.standard.set(name, forKey: userKey)
            }
            V7TrafficReporter.writeMeta(owner: ownerKey, preferredTag: nil, collectionId: nil, routeIds: nil)
        }
        notices = (try? await V7Api.notices()) ?? notices
    }

    public func selectLine(_ id: String) async {
        setSelected(id)
        if vpnStatus == .connected || vpnStatus == .connecting {
            await connect()
        }
    }

    public func setAutoLineSwitch(_ on: Bool) async {
        autoLineSwitch = on
        UserDefaults.standard.set(on, forKey: autoKey)
        if vpnStatus == .connected || vpnStatus == .connecting {
            await connect()
        }
    }

    /// 用选中线路所属订阅的 sing-box 导出连接。自动切换开则 urltest，关则钉住该节点。
    public func connect() async {
        lastError = nil
        guard vpnAccessAllowed else {
            lastError = denyReason ?? "当前不可连接"
            return
        }
        guard !upgradeRequired else {
            lastError = "当前版本过旧，请先更新 Veylo。"
            return
        }
        if lines.isEmpty {
            await syncCatalog()
        }
        guard let line = selectedLine else {
            lastError = lines.isEmpty ? "没有可用的订阅线路" : "请先选择一条线路"
            return
        }
        connecting = true
        defer { connecting = false }
        // 扩展按这份上下文给用量样本打标签（账户、route_id、订阅 id）。写一个小文件，不联网。
        V7TrafficReporter.writeMeta(
            owner: ownerKey,
            preferredTag: line.tag,
            collectionId: line.subscriptionId,
            routeIds: routeIds[line.subscriptionId] ?? [:]
        )
        do {
            if line.singboxRunnable, !line.exportURL.isEmpty {
                let runnableTags = Set(lines.filter { $0.subscriptionId == line.subscriptionId && $0.singboxRunnable }.map(\.tag))
                try await V7ProfileBridge.syncAndStart(
                    from: line.exportURL,
                    proxyConfig: bypass.asProxyJSON(),
                    selectedTag: line.tag,
                    autoSwitch: autoLineSwitch,
                    runnableTags: runnableTags
                )
            } else if !line.xrayExportURL.isEmpty {
                try await V7ProfileBridge.syncAndStartVeylo(
                    xrayExportURL: line.xrayExportURL,
                    tag: line.tag,
                    proxyConfig: bypass.asProxyJSON()
                )
            } else {
                lastError = "这条线路要走 \(line.coreLabel)，Veylo 核还翻译不了。"
                return
            }
            await bindTunnel()
            uploadTraffic()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 断开不等上传；扩展停止时自己封最后一批，下次上传带走。
    public func disconnect() async {
        connecting = false
        try? await V7ProfileBridge.stop()
        await bindTunnel()
        uploadTraffic()
    }

    public func bindTunnel() async {
        guard let profile = try? await ExtensionProfile.load() else {
            tunnel = nil
            vpnStatus = .invalid
            return
        }
        tunnel = profile
        profile.register()
        vpnStatus = profile.status
        statusBag.removeAll()
        profile.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.vpnStatus = status
            }
            .store(in: &statusBag)
    }

    public var selectedLine: V7ConfigBuilder.Line? {
        guard let selectedLineId else { return nil }
        return lines.first { $0.id == selectedLineId }
    }

    public var selectedLineName: String {
        selectedLine?.tag ?? "点击选择线路"
    }

    public func probeLatency() async -> String {
        let start = Date()
        var req = URLRequest(url: URL(string: "https://www.gstatic.com/generate_204")!)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return "\(ms) ms · HTTP \(code)"
        } catch {
            return "失败：\(error.localizedDescription)"
        }
    }

    private func setSelected(_ id: String?) {
        selectedLineId = id
        if let id {
            UserDefaults.standard.set(id, forKey: lineKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lineKey)
        }
    }

    // MARK: - helpers

    static func deviceName() -> String {
        #if os(iOS)
            return "iOS Device"
        #else
            return "Apple Device"
        #endif
    }

    static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// 语义版本比较：local < min ⇒ true（需升级）。空 min = 不设闸门。
    static func isOutdated(local: String, min: String?) -> Bool {
        guard let min, !min.isEmpty else { return false }
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        let l = parts(local), m = parts(min)
        for i in 0 ..< max(l.count, m.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < m.count ? m[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}
