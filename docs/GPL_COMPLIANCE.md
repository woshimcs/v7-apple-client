# GPL-3.0 合规清单（iOS / Veylo）

> 上游 `sing-box-for-apple` 与内核 `sing-box`/`libbox` 均为 **GPL-3.0**。
> iOS 把 libbox 以 FFI 链接进 NE 扩展 = **衍生作品**，GPL 传染整个 app →
> **本 iOS 客户端必须整仓开源**。collections 已拍板接受（`APPLE_ECOSYSTEM_PLAN.md` D2）。

## 为什么 iOS 必须开源（而 macOS 桌面不用）

| | 桌面(Tauri) | iOS |
|---|---|---|
| 内核形态 | sing-box **独立子进程**(sidecar) | libbox **FFI 链接**进 NE 扩展 |
| GPL 边界 | 进程隔离 = 聚合，**壳可闭源** | FFI = 衍生作品，**必须开源** |

## 义务清单

- [x] **仓库 public**：`woshimcs/v7-apple-client` 已建为 public（源码可获取）。
- [x] **保留 LICENSE**：上游 GPL-3.0 `LICENSE` 原样保留，不改授权头。
- [ ] **About / 关于页**（品牌化时加）：
  - GPL-3.0 全文或链接；
  - **源码地址**：`https://github.com/woshimcs/v7-apple-client`；
  - 客户端版本号 + 对应 commit。
- [ ] **不蹭 sing-box 名**：产品名 Veylo，图标/文案不得暗示与 sing-box / SagerNet 关联
  （GPL 附加条款要求）。About 里可注明「基于开源项目 sing-box，遵循 GPL-3.0」但不作为品牌。
- [x] **不改二进制来源**：libbox 用上游产物；若自行编译需同样开源对应源码。
- [ ] **再分发自由**：不得加 DRM/技术措施阻止用户获取与再分发源码（这也是 GPL × App Store 的冲突根源，见下）。

## GPL × App Store（已知风险，不阻塞一期）

- GPLv3 的反 Tivoization + 再分发自由与 App Store 的 DRM/分发限制存在冲突（VLC 曾因此下架）。
- 官方 sing-box-for-apple 目前「因非技术原因」只在 TestFlight。
- **一期走 TestFlight**（GPL 在此实践中可存活），App Store 作为攻坚目标：
  - G1：联系 sing-box 作者求 App Store 分发例外（零成本先试）；
  - 失败再由 owner 决定 D7（是否换 iOS 内核）。
- 详见 `collections-gh-v7-release/docs/APPLE_ECOSYSTEM_PLAN.md` §3。

## Apple 隐私（与 GPL 无关但同属合规）

- VPN **只用** `NEPacketTunnelProvider`，无私有 API。
- **不采集流量负载**，仅元数据；隐私政策如实声明；Privacy Manifest 齐全。
