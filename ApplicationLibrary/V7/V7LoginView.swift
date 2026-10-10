import SwiftUI

/// V7/Veylo 登录页。挂在上游主界面之前作为登录闸门（见 docs/BACKEND_INTEGRATION.md §9）。
///
/// 用法（伪代码，ApplicationLibrary 根视图）：
/// ```swift
/// @StateObject private var v7 = V7AppState.shared
/// var body: some View {
///     if v7.isLoggedIn { MainView().environmentObject(v7) }
///     else { V7LoginView().environmentObject(v7) }
/// }
/// ```
public struct V7LoginView: View {
    @EnvironmentObject private var state: V7AppState
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var showRegister = false
    @State private var showReset = false

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Veylo").font(.largeTitle).bold()
            Text("登录以使用").font(.subheadline).foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("用户名或邮箱", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                SecureField("密码", text: $password)
                    .textContentType(.password)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal)

            if let err = state.lastError {
                Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }

            Button {
                Task {
                    busy = true
                    await state.login(username: username, password: password)
                    busy = false
                }
            } label: {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "登录中…" : "登录")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || username.isEmpty || password.isEmpty)
            .padding(.horizontal)

            HStack(spacing: 24) {
                Button("注册") { showRegister = true }
                Button("忘记密码") { showReset = true }
            }
            .font(.footnote)

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showRegister) { V7RegisterSheet() }
        .sheet(isPresented: $showReset) { V7ResetSheet() }
    }
}

private struct V7RegisterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var prompt = ""
    @State private var challengeId: String?
    @State private var answer = ""
    @State private var code = ""
    @State private var username = ""
    @State private var password = ""
    @State private var sent = false
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            Form {
                TextField("邮箱", text: $email)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled(true)
                if !prompt.isEmpty { Text(prompt).font(.footnote) }
                TextField("验证题答案", text: $answer)
                if sent {
                    TextField("邮箱验证码", text: $code)
                    TextField("用户名", text: $username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("密码", text: $password)
                }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Button(busy ? "请稍候…" : (sent ? "完成注册" : "发送验证码")) {
                    Task { await submit() }
                }
                .disabled(busy || email.isEmpty)
            }
            .navigationTitle("注册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await loadChallenge() }
        }
        .navigationViewStyle(.stack)
    }

    private func loadChallenge() async {
        if let ch = try? await V7Api.registerChallenge() {
            challengeId = ch.challenge_id
            prompt = ch.prompt ?? ""
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            if !sent {
                try await V7Api.registerStart(email: email, challengeId: challengeId, answer: answer)
                sent = true
                message = "验证码已发送，请填写邮箱里的验证码。"
            } else {
                try await V7Api.registerVerify(email: email, code: code, username: username, password: password)
                message = "注册成功，请返回登录。"
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct V7ResetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var sent = false
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            Form {
                TextField("邮箱", text: $email)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled(true)
                if sent {
                    TextField("验证码", text: $code)
                    SecureField("新密码", text: $password)
                }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Button(busy ? "请稍候…" : (sent ? "重置密码" : "发送验证码")) {
                    Task { await submit() }
                }
                .disabled(busy || email.isEmpty)
            }
            .navigationTitle("忘记密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            if !sent {
                try await V7Api.resetStart(email: email)
                sent = true
                message = "验证码已发送。"
            } else {
                try await V7Api.resetVerify(email: email, code: code, newPassword: password)
                message = "密码已更新，请返回登录。"
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
