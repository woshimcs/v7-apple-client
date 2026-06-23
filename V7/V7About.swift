import Foundation
import SwiftUI

/// V7/Veylo 关于页 —— GPL-3.0 合规声明（衍生作品义务）。
///
/// 要求(见 docs/GPL_COMPLIANCE.md)：
///   - 声明基于开源项目、遵循 GPL-3.0；
///   - 给出**源码地址**（本 fork 仓库）；
///   - 展示客户端版本号；
///   - 不蹭 sing-box 名作为品牌（仅在致谢中如实注明）。
///
/// 落地(Mac)：此文件需在 Xcode 里加入 SFI target 的 Compile Sources，并在 MainView/设置页
/// 增加入口（如「关于 Veylo」），见 V7_PATCHES.md 与 docs/BACKEND_INTEGRATION.md §9。
struct V7AboutView: View {
    private let sourceURL = URL(string: "https://github.com/woshimcs/v7-apple-client")!

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Veylo").font(.title2).bold()
                    Text("版本 \(appVersion)").foregroundStyle(.secondary).font(.footnote)
                }
            }

            Section("开源与许可") {
                Text("本应用是开源软件，基于开源项目 sing-box / sing-box-for-apple 构建，"
                     + "整体以 GNU 通用公共许可证第 3 版（GPL-3.0）授权分发。")
                    .font(.footnote)
                Link("源码地址（GitHub）", destination: sourceURL)
                Link("GPL-3.0 许可证全文", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            }

            Section("隐私") {
                Text("本应用不采集流量负载内容，仅在连接异常时上报脱敏诊断信息用于排障。")
                    .font(.footnote)
            }

            Section {
                Text("致谢：sing-box（SagerNet / nekohasekai），GPL-3.0。"
                     + "Veylo 为独立品牌，与上游项目无隶属关系。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
    }
}
