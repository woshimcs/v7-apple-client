# 前置清单（开发 / 真机 / 发版）

> iOS 端和 Android 不同：建仓 / 写代码 / 写文档不需要 Mac，但**编译、真机调试、TestFlight 发版**
> 有几道 Apple 硬门槛。本表区分「现在不阻塞」与「落地前必须补」。

## 状态总览（2026-06-23）

| 前置 | 是否就绪 | 阻塞什么 |
|---|---|---|
| 公司 Apple Developer 账号（D-U-N-S 已过） | ✅ 已就绪 | App Store 发 VPN 的硬前置（指南 5.4 要求组织主体） |
| 仓库 + fork + 文档 | ✅ 本仓已建 | — |
| Mac + Xcode | ❌ 待备 | 编译、真机、Archive、TestFlight 上传 |
| Network Extension entitlement | ❌ 待申请 | iOS VPN 必需（Apple 人工审批，周期长，尽早申请） |
| iOS Distribution 证书 + Provisioning Profile | ❌ 待办 | 真机签名、TestFlight/App Store 分发 |
| TestFlight（App Store Connect 建 app 记录） | ❌ 待办 | 一期分发通道 |
| 隐私政策页 + Privacy Manifest | ❌ 待办 | App Store / TestFlight 审核 |

## 1. Mac + Xcode

- 任意能跑 Xcode 的 Mac（含云 Mac / CI macOS runner）。**本仓是 public，GitHub Actions macOS runner 免费无限**，
  所以 CI 编译不烧私有仓库额度——但本地调试仍建议有一台 Mac。
- 首次 clone 后初始化子模块：

```bash
git submodule update --init --recursive   # 拉 Frameworks/Runestone
```

- 打开 `sing-box.xcodeproj`，scheme 选 `SFI`（iOS）。Libbox xcframework 由上游 `Frameworks/` 提供或
  Makefile 拉取（见上游 `Makefile`）。

## 2. Network Extension entitlement（最长周期，先申请）

- iOS VPN 必须 `com.apple.developer.networking.networkextension`（packet-tunnel-provider）。
- 在 Apple Developer 账号下为 App ID 申请该 entitlement，部分需向 Apple 提交业务说明 + 隐私政策。
- 申请通过前无法在真机/TestFlight 跑 VPN（模拟器也不支持 NE）。**今天就提交申请**。

## 3. 证书与 Provisioning（公司号 Team 下）

- **iOS Distribution（Apple Distribution）证书**：与 macOS 的 Developer ID 是两套，不通用。
- App ID：`link.veylo.ios`（示例，最终以品牌化 PR 定），勾选 Network Extensions + App Groups + Keychain Sharing。
- Provisioning Profile：主 app + NE 扩展各一个（扩展 Bundle ID 形如 `link.veylo.ios.tunnel`）。
- CI 走 App Store Connect API Key（`.p8`）做签名/上传，对齐桌面 macOS 公证的做法（不要用 Apple ID 密码）。

## 4. App Store Connect / TestFlight

- 在 App Store Connect 建 app 记录（Bundle ID 对齐上一步）。
- 一期分发 = **TestFlight**（容 1 万人，build 90 天滚动续期）。下载页 iOS 卡片放 TestFlight 链接/二维码，
  **不放 IPA 直链**（iOS 不允许侧载）。

## 5. CI Secrets（`release-ios.yml` 落地时配，对齐 Android/桌面）

| Secret | 用途 |
|---|---|
| `V7_API_BASE` | 注入生产后端地址（如 `https://veylo.link`），禁止硬编码 |
| `APPLE_API_ISSUER` / `APPLE_API_KEY_ID` / `APPLE_API_KEY_P8`(b64) | App Store Connect API Key，TestFlight 上传 |
| `IOS_DIST_CERT_P12`(b64) / `IOS_DIST_CERT_PASSWORD` | iOS Distribution 证书 |
| `IOS_PROVISION_PROFILE`(b64) / `IOS_EXT_PROVISION_PROFILE`(b64) | 主 app + 扩展 Provisioning |
| `V7_ADMIN_USER` / `V7_ADMIN_PASS` | 回填 `POST /admin/releases` 的 admin 凭证 |

## 6. 隐私与合规（审核前）

- 隐私政策页（公开 URL）：声明**不采集流量负载**，仅元数据（时长/字节）。
- Privacy Manifest（`PrivacyInfo.xcprivacy`）。
- GPL 合规见 `docs/GPL_COMPLIANCE.md`。
