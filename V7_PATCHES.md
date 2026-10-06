# V7_PATCHES — 侵入式改动登记

> 规则：**能新建文件就不改 upstream 文件**。确需改动上游文件时：
> 1) 改动行上方加 `// MODIFIED-BY-V7: 原因`；2) 在此表登记一行。
> 这样每次同步 upstream 都能逐条核对冲突点。详见 `V7_README.md` §3。

## 改动台账

| # | upstream 文件 | 位置 / 符号 | 改动原因 | 日期 | PR |
|---|---|---|---|---|----|
| 1 | `sing-box.xcodeproj/project.pbxproj` | `BASE_PACKAGE_IDENTIFIER`（Debug+Release，2 处） | `io.nekohasekai.sfavt` → `link.veylo.ios`，品牌化 Bundle ID 基址（级联 app/extension/app group/iCloud）。**注**：pbxproj 格式无法安全携带 `// MODIFIED-BY-V7` 注释，故仅在此登记。 | 2026-06-23 | feat/branding-veylo |
| 2 | `SFI/Info.plist` | 顶层 `CFBundleDisplayName` | 新增 = `Veylo`，主屏显示名（XML 注释已标 MODIFIED-BY-V7）。 | 2026-06-23 | feat/branding-veylo |
| 3 | `SFI/Info.plist` | `CFBundleURLTypes[0].CFBundleURLSchemes` | 追加品牌 deep-link scheme `veylo://`，保留 `sing-box://` 不破坏上游导入（XML 注释已标）。 | 2026-06-23 | feat/branding-veylo |
| 4 | `SFI/Assets.xcassets/AppIcon.appiconset/*.png`（19 个尺寸） | 全部 PNG | 替换为 **Veylo 品牌图标**（蓝色 V + swoosh，白底，不透明无 alpha）。源自桌面端 `v7-win-pc/src-tauri/icons/ios/AppIcon-512@2x.png`（1024 官方图标）按各尺寸重采样。`Contents.json` 结构不变，仅替换位图，故无需改 JSON。**注**：二进制无法携带注释，仅此登记。 | 2026-06-23 | feat/branding-veylo |
| 5 | `MacLibrary/Assets.xcassets/AppIcon.appiconset/*.png`（10 个尺寸） | 全部 PNG | 同 #4 来源，铺到 macOS（SFM）图标集，三端图标统一。`Contents.json` 不变。 | 2026-06-23 | feat/branding-veylo |
| 6 | `WidgetExtension/Assets.xcassets/AppIcon.appiconset/`（`Contents.json` + 新增 `AppIcon-1024.png`） | universal/ios 1024 槽 | 单尺寸图标集补 1024 位图并在 `Contents.json` 的默认槽填 `filename`（dark/tinted 槽留空由 Xcode 派生）。源同 #4。 | 2026-06-23 | feat/branding-veylo |
| 7 | `SFI/Application.swift` | `Application.body` | 未登录显示 `V7LoginView`，已登录进 `V7HomeView`（对齐安卓首页），并拉 session。 | 2026-10-06 | feat/ios-testflight |
| 8 | `SFI/Info.plist` | `V7_API_BASE` | 注入 `$(V7_API_BASE)`，工程默认 `https://veylo.link`。 | 2026-10-06 | feat/ios-testflight |
| 9 | `SFI/SFI.entitlements`、`Extension/Extension.entitlements` | NE + App Group | 只留 `packet-tunnel-provider` 与 `$(APP_GROUP_IDENTIFIER)`（`group.link.veylo.ios`）。去掉 iCloud / multicast，否则描述文件签不过。 | 2026-10-06 | feat/ios-testflight |
| 10 | `Library/Shared/AppConfiguration.swift` | `extensionBundleID` | iOS 用 `link.veylo.ios.tunnel`，与门户 App ID 一致。 | 2026-10-06 | feat/ios-testflight |
| 11 | `Library/Shared/Variant.swift` | `applicationName`（iOS） | VPN 配置显示名改为 Veylo。 | 2026-10-06 | feat/ios-testflight |
| 12 | `Library/Database/Profile+RW.swift` | `writeAsync` | 改为 `public`，让 ApplicationLibrary 写入订阅配置。 | 2026-10-06 | feat/ios-testflight |
| 13 | `sing-box.xcodeproj/project.pbxproj` | Team、SFI 显示名、Extension bundle、嵌入扩展 | Team `4534A24396`；SFI 显示名 Veylo；Extension 为 `.tunnel`；SFI 不再嵌入 Widget / File Provider / Intents（门户没有这几个 App ID）。 | 2026-10-06 | feat/ios-testflight |
| 14 | `Library/Network/ExtensionPlatformInterface.swift` | `cancelNotification` / `usePlatformBridge` / `createBridge` | 补上 sing-box v1.14.0 的平台接口。iOS 上 bridge 直接拒绝，通知取消走系统通知中心。 | 2026-10-06 | feat/ios-testflight |
| 15 | `ApplicationLibrary/Views/Tools/ReportShared.swift` | `LibboxCreateZipArchive` | v1.14.0 多了 `encrypt` 参数。测试包报告不加密，传 `false`。 | 2026-10-06 | feat/ios-testflight |
| 16 | `Library/Network/CommandClient.swift` | `clientHandler.writeDNSQuery` | veylo-core 的 `LibboxCommandClientHandlerProtocol` 多了 DNS 查询回调。空实现，不影响连接。 | 2026-10-06 | feat/ios-testflight |

> 新增 V7 自有文件（不动上游，不入上表）：
> - `V7/V7About.swift`（GPL 关于页草稿，PR `feat/branding-veylo`）。
> - `ApplicationLibrary/V7/`（登录、session、1.12+ 配置、profile 桥）。由同步目录编进 ApplicationLibrary。
> - `.github/workflows/release-ios.yml`（TestFlight CI，`macos-26` + Xcode 26，Libbox 取 `woshimcs/veylo-core` 标签 `veylo-1.0.0`）。
>
> 登录闸门、`V7_API_BASE`、entitlements 已落在上表 #7–#13。登录后是 Veylo 壳（首页 / 工具 / 我的），不再进上游 `MainView`。
> 1.0.2：隧道核是 Veylo 自有核（sing-box-lx `v1.14.2-lx.11`，含 xhttp）。sing-box 导出能跑的线路直接用；只有 Xray 导出的线路先翻译成同一套出站再进同一条隧道。版本号在 `V7Version.marketing` 与 SFI `MARKETING_VERSION`。

## 待办（计划中的侵入点，落地时回填上表）

> 以下是接后端 / 品牌化阶段**预计**会碰的上游文件，真正改动时移到上表并加 `// MODIFIED-BY-V7`。

| 预计文件 | 预计改动 | 所属阶段 |
|---|---|---|
| `SFI/Info.plist`（或 target build settings） | App 显示名、Bundle ID、URL scheme | 品牌化 |
| `SFI/*.entitlements` | Network Extension entitlement、App Group、Keychain group | 接后端 / 发版 |
| `ApplicationLibrary`（导航 / 根视图） | 挂载 V7 登录闸门、订阅页入口 | 接后端 |
| `Library`（profile 拉取 / 存储） | 用 V7 `/export/singbox` 拉配置并经 config builder 包 inbound/route/DNS | 接后端 |
| asset catalog / 关于页 | 替换图标、About 页 GPL 声明 + 源码地址 | 品牌化 / 合规 |

V7 自有新增代码（不进本表，因为不动上游）：放 `V7/` 目录或 `V7*` 前缀文件，如
`V7Backend.swift`、`V7Session.swift`、`V7Keychain.swift`、`V7ConfigBuilder.swift`。
