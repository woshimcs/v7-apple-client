import SwiftUI

public struct V7ToolsPage: View {
    @EnvironmentObject private var state: V7AppState
    @State private var ping = "尚未测试"
    @State private var busy = false

    public init() {}

    public var body: some View {
        NavigationView {
            List {
                Section("线路") {
                    Button("同步下发的订阅和线路") {
                        Task { await state.syncCatalog() }
                    }
                    Text(state.lines.isEmpty ? "当前没有线路" : "已同步 \(state.lines.count) 条")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("连通性") {
                    Text(ping).font(.body)
                    Button(busy ? "测试中…" : "测试到 204") {
                        Task {
                            busy = true
                            ping = await state.probeLatency()
                            busy = false
                        }
                    }
                    .disabled(busy)
                    Text("已连接时走当前隧道，未连接时走本机网络。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("工具")
        }
        .navigationViewStyle(.stack)
    }
}

public struct V7MePage: View {
    @EnvironmentObject private var state: V7AppState
    @Environment(\.openURL) private var openURL
    @State private var updateText = ""

    public init() {}

    public var body: some View {
        NavigationView {
            List {
                Section("账户") {
                    row("账号", state.profile?.username ?? state.username ?? "—")
                    row("邮箱", state.profile?.email ?? "—")
                    row("角色", state.profile?.role ?? "—")
                    row("套餐", state.profile?.tier_name ?? state.profile?.tier_code ?? "—")
                    row("注册", state.profile?.created_at ?? "—")
                    row("加速", state.vpnAccessAllowed ? "已开通" : "未开通")
                }
                Section("连接") {
                    Toggle("自动切换线路", isOn: Binding(
                        get: { state.autoLineSwitch },
                        set: { on in Task { await state.setAutoLineSwitch(on) } }
                    ))
                    Text("打开后节点不可用会自动换同组线路。关掉则只用当前选中的线路。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("服务") {
                    NavigationLink("套餐", destination: V7PlansPage())
                    NavigationLink("公告", destination: V7NoticesPage())
                    NavigationLink("工单", destination: V7TicketsPage())
                    Button("帮助") { openURL(URL(string: "https://veylo.link")!) }
                    Button("检查更新") { Task { await checkUpdate() } }
                    if !updateText.isEmpty {
                        Text(updateText).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("退出登录", role: .destructive) {
                        Task { await state.logout() }
                    }
                }
                Section {
                    Text("版本 \(V7Version.marketing) · 内核 sing-box（GPL-3.0）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
            .task { await state.loadAccount() }
        }
        .navigationViewStyle(.stack)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func checkUpdate() async {
        updateText = "正在检查…"
        do {
            guard let rel = try await V7Api.latestIOSRelease(), let latest = rel.version, !latest.isEmpty else {
                updateText = "暂时没有 iOS 安装包记录"
                return
            }
            let current = V7AppState.appVersion()
            if V7AppState.isOutdated(local: current, min: latest) {
                updateText = "有新版本 \(latest)，当前 \(current)"
                if let raw = rel.download_url, let url = URL(string: raw) { openURL(url) }
            } else {
                updateText = "已是最新 \(current)"
            }
        } catch {
            updateText = "检查失败"
        }
    }
}

struct V7PlansPage: View {
    @State private var plans: [V7Plan] = []
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if plans.isEmpty && error == nil {
                Text("暂无可见套餐").foregroundStyle(.secondary)
            }
            ForEach(plans) { plan in
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.name ?? "套餐").font(.body.bold())
                    if let tagline = plan.tagline, !tagline.isEmpty {
                        Text(tagline).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(price(plan)).font(.caption).foregroundStyle(.secondary)
                    if plan.already_owned == true {
                        Text("已拥有").font(.caption).foregroundStyle(.green)
                    }
                }
            }
            Button("在网页查看和支付") { openURL(URL(string: "https://veylo.link")!) }
        }
        .navigationTitle("套餐")
        .task { await load() }
    }

    private func load() async {
        do { plans = try await V7Api.plans() } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func price(_ plan: V7Plan) -> String {
        guard let raw = plan.list_price_cents, let cents = Int(raw) else { return plan.interval ?? "" }
        let amount = Double(cents) / 100
        let currency = plan.currency ?? ""
        return String(format: "%@ %.2f / %@", currency, amount, plan.interval ?? "")
    }
}

struct V7NoticesPage: View {
    @EnvironmentObject private var state: V7AppState

    var body: some View {
        List {
            if state.notices.isEmpty {
                Text("暂无公告").foregroundStyle(.secondary)
            }
            ForEach(state.notices) { notice in
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title ?? "公告").font(.body.bold())
                    if let body = notice.body, !body.isEmpty {
                        Text(body).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("公告")
        .task { await state.loadAccount() }
    }
}

struct V7TicketsPage: View {
    @State private var tickets: [V7Ticket] = []
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        List {
            Section("新建") {
                TextField("标题", text: $subject)
                TextField("内容", text: $bodyText)
                Button(busy ? "提交中…" : "提交工单") {
                    Task { await submit() }
                }
                .disabled(busy || subject.trimmingCharacters(in: .whitespaces).isEmpty || bodyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).foregroundStyle(.red) }
            Section("我的工单") {
                if tickets.isEmpty { Text("暂无工单").foregroundStyle(.secondary) }
                ForEach(tickets) { ticket in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ticket.subject ?? "工单").font(.body)
                        Text(ticket.status ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("工单")
        .task { await reload() }
    }

    private func reload() async {
        tickets = (try? await V7Api.tickets()) ?? tickets
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            try await V7Api.createTicket(subject: subject, body: bodyText)
            subject = ""
            bodyText = ""
            error = nil
            await reload()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
