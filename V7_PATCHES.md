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

> 新增 V7 自有文件（不动上游，不入上表）：
> - `V7/V7About.swift`（GPL 关于页草稿，PR `feat/branding-veylo`）。
> - `V7/V7Backend.swift`、`V7/V7Keychain.swift`、`V7/V7Session.swift`、`V7/V7ConfigBuilder.swift`、
>   `V7/V7ProfileBridge.swift`、`V7/V7AppState.swift`、`V7/V7LoginView.swift`（接后端实现，PR `feat/backend-integration`）。
> - `.github/workflows/release-ios.yml`（发版 CI，同上 PR；本仓 public，macOS runner 免费）。
>
> **Mac 落地**（详见 `docs/BACKEND_INTEGRATION.md §9.B`）：
> - 上述 `V7/*.swift` 需在 Xcode 加入 SFI / ApplicationLibrary target 的 Compile Sources；
>   `V7ProfileBridge` 需链接 `Library` + `Libbox`。
> - **待落侵入点**：`SFI/Info.plist` 增 `V7_API_BASE` = `$(V7_API_BASE)`（运行时读后端地址，CI 已传值）；
>   挂 `V7LoginView` 闸门、把上游「连接」改接 `V7AppState`。真改 Info.plist 时移到上表并加 `// MODIFIED-BY-V7`。

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
