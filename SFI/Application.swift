import ApplicationLibrary
import Foundation
import Library
import SwiftUI

@main
struct Application: App {
    @UIApplicationDelegateAdaptor private var appDelegate: ApplicationDelegate
    @StateObject private var environments = ExtensionEnvironments()
    @StateObject private var peerStore = TailscaleSSHPeerStore()
    // MODIFIED-BY-V7: 未登录先走 Veylo 登录，已登录进对齐安卓的首页
    @ObservedObject private var v7 = V7AppState.shared

    init() {
        Task { @MainActor in
            ImportedFontStore.shared.bootstrap()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if v7.isLoggedIn {
                    V7HomeView()
                } else {
                    V7LoginView()
                }
            }
            .environmentObject(v7)
            .onAppear {
                // 保住上游环境对象，配置库和扩展状态仍会初始化。
                _ = environments
                _ = peerStore
            }
            .task {
                guard v7.isLoggedIn else { return }
                await v7.refresh(full: true)
                v7.startPolling()
            }
        }
    }
}
