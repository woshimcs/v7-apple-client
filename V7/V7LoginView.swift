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

            Spacer()
            Text("基于开源 sing-box，遵循 GPL-3.0")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
    }
}
