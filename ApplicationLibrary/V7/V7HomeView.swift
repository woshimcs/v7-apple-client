import NetworkExtension
import SwiftUI

/// 登录后的 Veylo 壳，对齐安卓简化首页：状态、当前线路、连接 / 断开、我的。
public struct V7HomeView: View {
    @EnvironmentObject private var state: V7AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var tab = 0

    public init() {}

    public var body: some View {
        TabView(selection: $tab) {
            V7ConnectPage()
                .tabItem { Label("首页", systemImage: "house") }
                .tag(0)
            V7ToolsPage()
                .tabItem { Label("工具", systemImage: "wrench") }
                .tag(1)
            V7MePage()
                .tabItem { Label("我的", systemImage: "person") }
                .tag(2)
        }
        .task {
            await state.bindTunnel()
            if state.lines.isEmpty {
                await state.syncCatalog()
            }
        }
        // 回前台：刷新会话 / 额度，上传扩展在后台攒的用量（CF-21 / CF-23）。
        .onChangeCompat(of: scenePhase) { phase in
            if phase == .active {
                Task { await state.onForeground() }
            }
        }
        .alert(item: $state.quotaPrompt) { q in
            Alert(
                title: Text(q.state == .exceeded ? "本周期流量已用完" : "本周期流量快用完了"),
                message: Text(quotaPromptBody(q)),
                primaryButton: .default(Text("购买流量包")) {
                    if let url = state.quotaPurchaseURL { openURL(url) }
                },
                secondaryButton: .cancel(Text("知道了"))
            )
        }
    }

    private func quotaPromptBody(_ q: V7QuotaView) -> String {
        var parts = [q.usageText]
        if !q.orgName.isEmpty { parts.insert("团队：\(q.orgName)", at: 0) }
        parts.append(q.state == .exceeded ? "连接不会断开。买一个流量包可以继续按额度使用。" : "可以提前买一个流量包。")
        return parts.joined(separator: "\n")
    }
}

/// 首页 / 我的 共用的额度条：已用 / 总量、剩余、购买入口（CF-23）。
struct V7QuotaCard: View {
    @EnvironmentObject private var state: V7AppState
    @Environment(\.openURL) private var openURL
    let quota: V7QuotaView
    var compact = false

    private var tint: Color {
        switch quota.state {
        case .exceeded: return .red
        case .near: return .orange
        default: return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本周期流量").font(.caption).foregroundStyle(.secondary)
                if !quota.orgName.isEmpty {
                    Text(quota.orgName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let end = quota.periodEndText {
                    Text(end).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(quota.usageText).font(.subheadline.bold())
            if let ratio = quota.usedRatio {
                ProgressView(value: ratio).tint(tint)
            }
            HStack {
                if let warning = quota.stateText {
                    Text(warning).font(.caption).foregroundStyle(tint)
                } else if let remaining = quota.remainingText {
                    Text(remaining).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !compact {
                    Button("流量明细") {
                        if let url = state.quotaDetailURL { openURL(url) }
                    }
                    .font(.caption)
                }
                if quota.state != .unlimited {
                    Button("购买流量包") {
                        if let url = state.quotaPurchaseURL { openURL(url) }
                    }
                    .font(.caption.bold())
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct V7ConnectPage: View {
    @EnvironmentObject private var state: V7AppState
    @State private var picking = false

    private var connected: Bool { state.vpnStatus == .connected }
    private var connecting: Bool {
        state.connecting || state.vpnStatus == .connecting || state.vpnStatus == .reasserting
    }

    var body: some View {
        Group {
            if state.vpnAccessAllowed {
                connectBody
            } else {
                lockedBody
            }
        }
        .fullScreenCover(isPresented: $picking) {
            V7LinePicker(onPick: { tag in
                picking = false
                Task { await state.selectLine(tag) }
            })
        }
    }

    private var connectBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Veylo").font(.title3.bold())
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Text(statusTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(connected ? Color.green : Color.primary)
                .padding(.top, 36)

            Text(statusHint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Button {
                picking = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前线路").font(.caption).foregroundStyle(.secondary)
                        Text(state.selectedLineName).font(.body.bold()).foregroundStyle(.primary)
                    }
                    Spacer()
                    Text("更换").foregroundStyle(Color.accentColor)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.top, 32)

            if state.upgradeRequired {
                Text("当前版本过旧，暂时不能连接。请到 TestFlight 或 App Store 更新 Veylo。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            if let quota = state.quota {
                V7QuotaCard(quota: quota, compact: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            if let err = state.lastError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            Spacer()

            Button {
                Task {
                    if connected || connecting {
                        await state.disconnect()
                    } else if state.selectedLineId == nil {
                        picking = true
                    } else {
                        await state.connect()
                    }
                }
            } label: {
                Text(buttonTitle)
                    .font(.body.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(connected ? .green : .accentColor)
            .disabled((state.connecting && state.vpnStatus == .invalid) || (state.upgradeRequired && !connected && !connecting))
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private var lockedBody: some View {
        VStack(spacing: 8) {
            Text("VPN 未开通").font(.title3.bold())
            Text(state.denyReason ?? "账号尚未开通加速。开通后即可连接。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var statusTitle: String {
        if connected { return "已保护" }
        if connecting { return "连接中…" }
        return "未保护"
    }

    private var statusHint: String {
        if connected { return "当前连接已加密" }
        if connecting { return "正在建立保护" }
        return "连接后流量将加密转发"
    }

    private var buttonTitle: String {
        if connected { return "断开" }
        if connecting { return "连接中…" }
        return "连接"
    }
}

private struct V7LinePicker: View {
    @EnvironmentObject private var state: V7AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSubId: Int?
    let onPick: (String) -> Void

    private struct SubGroup: Identifiable {
        let id: Int
        let name: String
        let lines: [V7ConfigBuilder.Line]
    }

    private struct RegionGroup: Identifiable {
        let title: String
        let lines: [V7ConfigBuilder.Line]
        var id: String { title }
    }

    /// 订阅顺序跟下发顺序，不按名字排序。
    private var subscriptions: [SubGroup] {
        var order: [Int] = []
        var buckets: [Int: [V7ConfigBuilder.Line]] = [:]
        for line in state.lines {
            if buckets[line.subscriptionId] == nil { order.append(line.subscriptionId) }
            buckets[line.subscriptionId, default: []].append(line)
        }
        return order.map { id in
            let lines = buckets[id] ?? []
            let name = lines.first?.subscriptionName ?? "订阅"
            return SubGroup(id: id, name: name.isEmpty ? "订阅" : name, lines: lines)
        }
    }

    private var activeSub: SubGroup? {
        if let selectedSubId, let found = subscriptions.first(where: { $0.id == selectedSubId }) {
            return found
        }
        if let current = state.selectedLine?.subscriptionId,
           let found = subscriptions.first(where: { $0.id == current }) {
            return found
        }
        return subscriptions.first
    }

    /// 地区组跟线路出现顺序。没有地区的放在最后。
    private var regions: [RegionGroup] {
        guard let lines = activeSub?.lines else { return [] }
        var order: [String] = []
        var buckets: [String: [V7ConfigBuilder.Line]] = [:]
        var other: [V7ConfigBuilder.Line] = []
        for line in lines {
            let region = line.region?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if region.isEmpty {
                other.append(line)
                continue
            }
            if buckets[region] == nil { order.append(region) }
            buckets[region, default: []].append(line)
        }
        var groups = order.map { RegionGroup(title: $0, lines: buckets[$0] ?? []) }
        if !other.isEmpty { groups.append(RegionGroup(title: "其他", lines: other)) }
        return groups
    }

    var body: some View {
        NavigationView {
            Group {
                if state.lines.isEmpty {
                    VStack(spacing: 8) {
                        Text("暂无节点").font(.headline)
                        Text("下拉刷新，或确认账号已分配线路")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 0) {
                        if subscriptions.count > 1 {
                            subscriptionTabs
                        }
                        List {
                            ForEach(regions) { group in
                                Section {
                                    ForEach(group.lines) { line in
                                        lineRow(line)
                                    }
                                } header: {
                                    Text(group.title)
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle(subscriptions.count > 1 ? "订阅" : (activeSub?.name ?? "订阅"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { dismiss() }
                }
            }
            .refreshable { await state.syncCatalog() }
        }
        .navigationViewStyle(.stack)
    }

    private var subscriptionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(subscriptions) { sub in
                    let selected = sub.id == activeSub?.id
                    Button {
                        selectedSubId = sub.id
                    } label: {
                        VStack(spacing: 8) {
                            Text(sub.name)
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                                .lineLimit(1)
                            Rectangle()
                                .fill(selected ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                        .padding(.top, 12)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func lineRow(_ line: V7ConfigBuilder.Line) -> some View {
        let selected = line.id == state.selectedLineId
        return Button {
            onPick(line.id)
        } label: {
            HStack(spacing: 12) {
                Text(line.tag)
                    .font(.body)
                    .foregroundStyle(line.veyloRunnable ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                if let uptime = line.uptime?.displayText {
                    // CF-20：近 24 小时可用率，样本不足不显示。
                    Text(uptime)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .accessibilityLabel("近 24 小时可用率 \(uptime)")
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground))
    }
}
