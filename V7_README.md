# V7_README — Veylo Apple 客户端（fork of sing-box-for-apple）

> 本仓库是 **V7 / Veylo** 对 [`SagerNet/sing-box-for-apple`](https://github.com/SagerNet/sing-box-for-apple) 的 fork。
> 目标平台：**iOS / iPadOS**（一期），可选 macOS(SFM) / tvOS(SFT)。
> 内核沿用上游 **sing-box / libbox**，不自研；V7 只做**品牌化 + 后端集成**。
>
> 配套规则（collections 仓库）：`docs/UPSTREAM_FORK_STRATEGY.md`、`docs/CLIENT_REPO_SETUP.md`、
> `docs/VERSION_MANAGEMENT.md`、`docs/APPLE_ECOSYSTEM_PLAN.md`。本文件是它们在本仓的落地版。

---

## 0. 这是什么 / 为什么 fork

- Apple 平台 VPN 必须用 `NEPacketTunnelProvider`，且 iOS 沙盒禁止 spawn 子进程，
  所以无法照搬桌面 Tauri 的 sidecar 方案——**libbox 必须以 FFI 链接进 NE 扩展**。
- 既然 GPL 内核躲不掉，就**不自研**，直接 fork 官方已经处理好 NE + libbox 的
  `sing-box-for-apple`，只改品牌、接 V7 后端（登录/订阅/闸门/导出）。
- 决策依据见 collections `docs/APPLE_ECOSYSTEM_PLAN.md`（D1–D6 已拍板）。

## 1. Upstream 起点

| 项 | 值 |
|---|---|
| upstream | `https://github.com/SagerNet/sing-box-for-apple` |
| 起始分支 | `dev`（上游默认分支） |
| 起始 commit | `b70a3d9`（"Fix missing api version check for usb/ip"，2026-06 clone 时 HEAD） |
| License | **GPL-3.0**（保留，见 `LICENSE` 与 `docs/GPL_COMPLIANCE.md`） |
| 子模块 | `Frameworks/Runestone`（上游配置编辑器，按需 `git submodule update --init`） |

## 2. Remote 与分支约定

```
remotes:
  upstream  →  SagerNet/sing-box-for-apple（只读；push 已禁用 = DISABLED）
  origin    →  woshimcs/v7-apple-client（可写，public）

branches:
  v7-main                  我们主分支（默认分支，一直领先 upstream）
  sync/upstream-<tag>      同步上游时的临时分支
  v7-release-<version>     发布快照分支（打 tag 后冻结）
  feature/<topic>          日常功能开发
  docs/<topic>             文档
```

- **默认分支 = `v7-main`**。
- 禁止直接 push `v7-main`：走 `feature/*`、`docs/*` 分支 + PR。
- upstream 已 `git remote set-url --push upstream DISABLED`，防误推。

## 3. V7 代码隔离纪律（防 upstream merge 冲突）

1. **能新建文件就不改 upstream 文件**。V7 自有代码集中放：
   - Swift 源码：新建 `V7/` 目录（或文件名前缀 `V7*`，如 `V7Backend.swift`、`V7Session.swift`）。
   - 资源 / 字符串：前缀 `v7_` 或独立 asset catalog。
2. **不可避免要改 upstream 文件**时：
   - 改动行上方加注释 `// MODIFIED-BY-V7: 一句话原因`。
   - 在 `V7_PATCHES.md` 登记（文件 / 位置 / 原因 / 日期 / PR）。
3. **永远 `git merge` 同步上游，绝不 squash**（保留共同祖先，否则下次同步识别不了 base）。
4. **不改 LICENSE 头**（GPL-3.0 必须保留）。
5. 不重排上游目录（`SFI`/`SFM`/`SFT`/`Extension`/`Library`/`ApplicationLibrary` 原样）。

### 上游目录速览（改哪里前先认门）

| 目录 | 作用 | V7 是否常碰 |
|---|---|---|
| `SFI` | iOS app target（入口、Info.plist、entitlements、资源） | 品牌化会碰（记 PATCHES） |
| `SFM` / `SFT` | macOS / tvOS target | 一期不碰 |
| `Extension` | `NEPacketTunnelProvider` 扩展（libbox 在此跑） | 接后端可能碰 |
| `ApplicationLibrary` | 跨 target 共享 UI / 逻辑（profile 列表、设置等） | V7 登录/订阅 UI 挂这里 |
| `Library` | 核心库（Libbox 封装、profile 存储、网络） | 读多写少 |
| `Frameworks/` | Libbox xcframework + Runestone 子模块 | 不改 |

## 4. 同步 upstream 流程（摘要，详见 collections `UPSTREAM_FORK_STRATEGY.md` §4）

```bash
git checkout v7-main && git pull origin v7-main
git fetch upstream --tags
git checkout -b sync/upstream-<tag>
git merge <tag>            # 解冲突，重点查 V7_PATCHES.md 列的文件
# 在 Mac 上 Xcode build 验证（本仓 Swift 无法在非 mac 环境编译）
git checkout v7-main && git merge --no-ff sync/upstream-<tag>
git push origin v7-main
```

同步频率：安全补丁 24h 内；协议兼容更新 2 周内；小修季度合并。8 周未合触发「fork 跟版告警」。

## 5. 版本号与 tag 规范

- V7 版本与上游 **完全解耦**（同 `docs/VERSION_MANAGEMENT.md`）。
- iOS 客户端 tag：**`v7-ios-x.y.z`**（对齐 Android 的 `v7-android-x.y.z`、桌面的 `v7-win-pc`）。
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`（Xcode）由 CI 注入，禁止硬编码 `1.0.0`。
- 发布后回填后端 `POST /api/v1/admin/releases`，`platform=ios`，`download_url` = **TestFlight 链接**（不是 IPA）。

## 6. 后端地址与密钥纪律

- **禁止把生产后端 URL 硬编码进源码**：用 build setting / xcconfig 注入（如 `V7_API_BASE`），
  对齐 Android 的 `BuildConfig.API_BASE_URL`、桌面的 `VITE_API_BASE`。
- **禁止把 token / 证书 / Provisioning Profile / `.p8` push 进仓库**。CI 用 GitHub Secrets 注入。
- 登录 Bearer 存 **Keychain**，不落明文。

## 7. 文档索引（本仓 `docs/`）

| 文件 | 内容 |
|---|---|
| `docs/BACKEND_INTEGRATION.md` | V7 后端契约（登录/session/订阅/export）+ 接入点清单 + Swift 代码草稿 |
| `docs/PREREQUISITES.md` | 开发/发版前置（Mac、公司号、NE entitlement、证书、TestFlight、子模块） |
| `docs/GPL_COMPLIANCE.md` | GPL-3.0 义务清单（整仓开源、About 声明、不蹭名） |
| `V7_PATCHES.md` | 所有侵入式改 upstream 文件的登记台账 |

## 8. 反例（不要做）

- 把 V7 业务逻辑塞进上游文件中段而不加 `// MODIFIED-BY-V7` / 不记 PATCHES。
- squash merge upstream。
- 改 LICENSE / 删 GPL 头。
- 硬编码生产 API URL 或把密钥提交进仓库。
- 重命名上游 target 目录。
