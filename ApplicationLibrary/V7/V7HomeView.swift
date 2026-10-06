import NetworkExtension
import SwiftUI

/// 登录后的 Veylo 壳，对齐安卓简化首页：状态、当前线路、连接 / 断开、我的。
public struct V7HomeView: View {
    @EnvironmentObject private var state: V7AppState
    @State private var tab = 0

    public init() {}

    public var body: some View {
        TabView(selection: $tab) {
            V7ConnectPage()
                .tabItem { Label("首页", systemImage: "house") }
                .tag(0)
            V7MePage()
                .tabItem { Label("我的", systemImage: "person") }
                .tag(1)
        }
        .task {
            await state.bindTunnel()
            if state.lines.isEmpty {
                await state.loadLines()
            }
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
        .sheet(isPresented: $picking) {
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
                    } else if state.selectedTag == nil {
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
            .disabled(state.connecting && state.vpnStatus == .invalid)
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
    let onPick: (String) -> Void

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
                    List(state.lines) { line in
                        Button {
                            onPick(line.tag)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.tag).foregroundStyle(.primary)
                                    Text(line.type).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if line.tag == state.selectedTag {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择线路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { dismiss() }
                }
            }
            .refreshable { await state.loadLines() }
        }
        .navigationViewStyle(.stack)
    }
}

private struct V7MePage: View {
    @EnvironmentObject private var state: V7AppState

    var body: some View {
        NavigationView {
            List {
                Section("账户") {
                    HStack {
                        Text("账号")
                        Spacer()
                        Text(state.username ?? "—").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("加速")
                        Spacer()
                        Text(state.vpnAccessAllowed ? "已开通" : "未开通").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("退出登录", role: .destructive) {
                        Task { await state.logout() }
                    }
                }
                Section {
                    Text("版本 \(V7AppState.appVersion()) · 内核 sing-box（GPL-3.0）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
        }
        .navigationViewStyle(.stack)
    }
}
