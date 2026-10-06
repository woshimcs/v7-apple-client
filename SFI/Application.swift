import ApplicationLibrary
import Foundation
import Library
import SwiftUI

@main
struct Application: App {
    @UIApplicationDelegateAdaptor private var appDelegate: ApplicationDelegate
    @StateObject private var environments = ExtensionEnvironments()
    @StateObject private var peerStore = TailscaleSSHPeerStore()
    // MODIFIED-BY-V7: 未登录先走 Veylo 登录，已登录再进上游主界面
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
                    MainView()
                        .environmentObject(environments)
                        .environmentObject(peerStore)
                } else {
                    V7LoginView()
                }
            }
            .environmentObject(v7)
            .task {
                guard v7.isLoggedIn else { return }
                await v7.refresh(full: true)
                v7.startPolling()
            }
        }
    }
}
