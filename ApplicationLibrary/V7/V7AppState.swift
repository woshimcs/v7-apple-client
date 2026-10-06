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
    @Published public private(set) var selectedTag: String?
    @Published public private(set) var connecting = false
    @Published public private(set) var vpnStatus: NEVPNStatus = .invalid
    @Published public private(set) var username: String?

    private var sessionEtag: String?
    private var pollTask: Task<Void, Never>?
    private var statusBag = Set<AnyCancellable>()
    private var tunnel: ExtensionProfile?
    private let tagKey = "v7.selectedLineTag"
    private let userKey = "v7.username"

    private init() {
        isLoggedIn = V7Keychain.hasToken
        selectedTag = UserDefaults.standard.string(forKey: tagKey)
        username = UserDefaults.standard.string(forKey: userKey)
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
        try? await V7ProfileBridge.stop()
        V7Api.logout()
        session = nil
        sessionEtag = nil
        lines = []
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
            apply(session: s)
            if full {
                await syncExportIfAllowed(s)
                await loadLines(from: s)
            }
        } catch is V7NotModified {
            // 未变化，保留旧 session
        } catch let V7Backend.V7Error.http(code, _) where code == 401 {
            // token 失效 / force_logout
            await logout()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func apply(session s: V7Session) {
        session = s
        vpnAccessAllowed = s.vpn_access.allowed
        denyReason = s.vpn_access.deny_reason
        upgradeRequired = Self.isOutdated(local: Self.appVersion(), min: s.account.min_supported_version)

        let actions = Set(s.client_actions.compactMap { V7ClientAction(rawValue: $0) })
        if !s.vpn_access.allowed {
            // 准入被拒：按 actions 断连 / 清节点
            Task {
                if actions.contains(.disconnectVpn) { try? await V7ProfileBridge.stop() }
                if actions.contains(.purgeNodes) { try? await V7ProfileBridge.purge() }
            }
        }
    }

    /// 登录后把第一条可导出订阅写成本地 profile，连接仍走上游按钮（系统 VPN 授权框）。
    private func syncExportIfAllowed(_ s: V7Session) async {
        guard s.vpn_access.allowed,
              let link = s.subscriptions.first(where: { $0.export_allowed && ($0.export_links?.singbox?.isEmpty == false) })?.export_links?.singbox
        else { return }
        do {
            try await V7ProfileBridge.syncProfile(from: link, proxyConfig: nil, selectedTag: selectedTag)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 后台轮询：按 next_poll_after_sec（缺省 1800s）拉 minimal。
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
    }

    // MARK: - 连接编排

    /// 首页线路列表。没有已选、或已选不在新列表里时，落到第一条。
    public func loadLines(from s: V7Session? = nil) async {
        let source = s ?? session
        guard let source, let link = exportLink(in: source) else {
            lines = []
            return
        }
        do {
            let raw = try await V7ProfileBridge.downloadExport(link)
            let export = try V7ConfigBuilder.parseExport(raw)
            let parsed = V7ConfigBuilder.lines(in: export)
            lines = parsed
            if selectedTag == nil || !parsed.contains(where: { $0.tag == selectedTag }) {
                setSelected(parsed.first?.tag)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func selectLine(_ tag: String) async {
        setSelected(tag)
        if vpnStatus == .connected || vpnStatus == .connecting {
            await connect()
        }
    }

    /// 连接：选中线路写入 selector.default，再拉起系统 VPN。
    public func connect() async {
        lastError = nil
        guard vpnAccessAllowed, let s = session else {
            lastError = denyReason ?? "当前不可连接"
            return
        }
        guard let link = exportLink(in: s) else {
            lastError = "没有可用的订阅线路"
            return
        }
        if selectedTag == nil {
            await loadLines(from: s)
        }
        guard selectedTag != nil else {
            lastError = "请先选择一条线路"
            return
        }
        connecting = true
        defer { connecting = false }
        do {
            try await V7ProfileBridge.syncAndStart(from: link, proxyConfig: nil, selectedTag: selectedTag)
            await bindTunnel()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func disconnect() async {
        connecting = false
        try? await V7ProfileBridge.stop()
        await bindTunnel()
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

    public var selectedLineName: String {
        if let selectedTag, let line = lines.first(where: { $0.tag == selectedTag }) {
            return line.tag
        }
        return "点击选择线路"
    }

    private func exportLink(in s: V7Session) -> String? {
        s.subscriptions.first(where: { $0.export_allowed && ($0.export_links?.singbox?.isEmpty == false) })?.export_links?.singbox
    }

    private func setSelected(_ tag: String?) {
        selectedTag = tag
        if let tag {
            UserDefaults.standard.set(tag, forKey: tagKey)
        } else {
            UserDefaults.standard.removeObject(forKey: tagKey)
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
