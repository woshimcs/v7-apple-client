# V7_PATCHES — 侵入式改动登记

> 规则：**能新建文件就不改 upstream 文件**。确需改动上游文件时：
> 1) 改动行上方加 `// MODIFIED-BY-V7: 原因`；2) 在此表登记一行。
> 这样每次同步 upstream 都能逐条核对冲突点。详见 `V7_README.md` §3。

## 改动台账

| # | upstream 文件 | 位置 / 符号 | 改动原因 | 日期 | PR |
|---|---|---|---|---|----|
| — | （暂无）| — | fork 初始化仅新增 V7 文档，未改任何上游文件 | 2026-06-23 | docs/fork-bootstrap |

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
