# iOS 流量计量与额度（CF-21 / CF-20 / CF-23）

> 1.1.0 起。口径与桌面相同：`woshimcs/v7-win-pc` 的 `docs/TRAFFIC_ACCOUNTING.md`。
> 这里只写 iOS 不一样的地方。Related to collections#695 / collections#698。

## 分工

iOS 的 Network Extension 内存上限很低（几十 MB），所以扩展只做最少的事：

| 位置 | 做什么 | 代码 |
|---|---|---|
| 扩展 | 连自己的 libbox 命令服务，只订阅 `CommandConnections`；按连接把上下行记到线路上；每 60 秒并进 `open.json`；满 10 分钟或 80 条样本封成 `sealed-*.json`。**不联网** | `Extension/V7TrafficSampler.swift`、`Library/V7/V7TrafficLedger.swift` |
| 主 App | 连接前写 `meta.json`（账户、route_id、订阅 id、版本）；回前台、连接 / 断开后、每 2 分钟（前台）把 `sealed-*.json` 传到 `POST /api/v1/me/traffic` | `ApplicationLibrary/V7/V7TrafficReporter.swift` |

App Group 目录 `v7-traffic/`：

| 文件 | 谁写 | 谁读 / 删 |
|---|---|---|
| `meta.json` | 主 App | 扩展（每次封批时读） |
| `open.json` | 扩展 | 扩展；扩展不在跑时主 App 可以把它封掉 |
| `sealed-<毫秒>-<batch_id>.json` | 扩展（原子改名） | 主 App 上传后删除 |

两边只通过「写 open / 改名封批」和「读 / 删 sealed」交接，不需要锁。`sealed-*` 最多留 500 个（约 3.5 天），更老的服务端也不收（7 天）。

## 数据来源

只有一种：libbox 的连接事件（相当于桌面的 `connections` 来源，但是事件流，不是轮询快照）。

- `New`：带 Connection（chain、出站、网络、累计上下行）。在这里定下这条连接记到哪条线路。
- `Update`：只带本次增量。没见过 `New` 的连接丢掉（不知道线路）。
- `Closed`：带最终累计时补差额；关闭的连接服务端还会保留 5 分钟，重新订阅时会再发一次，所以计过的 ID 记 10 分钟，不重复计。
- 订阅断开（reload 配置时会断）10 秒后重连；Reset 快照里已跟踪的连接只计增长部分。
- 扩展进程只活在隧道期间，所以不存在桌面「接手已经在跑的内核」的问题：每条连接从 0 开始都是这次隧道产生的。

线路判定：chain 里第一个在当前配置出站目录里的名字（不假设 chain 顺序）；都对不上时按第一个名字记 `unknown`。
`direct` / `block` / `dns` 不计。

## 上报字段

与桌面相同，差别：

| 字段 | iOS |
|---|---|
| `platform` | `ios`（**需要 veylo-api 放开**：`trafficUsageNormalize.ts` 的白名单和 `client_traffic_usage_platform_chk`，迁移 0046） |
| `vpn_mode` | `tun`（NE 就是 TUN） |
| `core` | `veylo`（sing-box 导出与 Xray 翻译的线路都跑在 Veylo 核上） |
| `arch` | `arm64` |
| `os` | `iOS 18.1.0` 这种 |
| `route_id` / `collection_id` | 连接时由主 App 写进 `meta.json`：`/lines` 的 `route_id`（含隐身分组 `fallbacks`），订阅 id |
| `x-hwid` 头 | Keychain 里的稳定 UUID（`V7Keychain.hwid()`，登出不清）。**只**在流量上报时带，订阅导出不带（避免改变设备数判定） |

账户归属、丢弃 / 重试规则与桌面相同：`400/403/404/409/413/422` 丢弃；`401` 和网络失败停止本轮；其余留着重试。
只传 `owner` 与当前账户一致（或没有 owner）的批次。

## 已知局限

- 主 App 不在前台时不上传（没有接 BGTaskScheduler），攒在 App Group，下次打开 App 时传。
- 统计间隔 5 秒、封批 60 秒；扩展被系统杀掉时最多丢最近 60 秒（`open.json` 会在下次启动隧道或主 App 发现隧道空闲时封掉）。
- `bucket_start` 取并批时刻的整点，跨整点最多 60 秒误差（同桌面）。

## 额度（CF-23）与可用率（CF-20）

- 额度：`/me/session` 的 `traffic_quota` + `GET /api/v1/me/traffic/summary`（全量同步、回前台、打开「我的」时拉，节流 60 秒）。
  多个团队显示最紧张的一个（同服务端 `tightestQuota`）。首页一张小卡，「我的」里一张带「流量明细」的卡。
  超额 / 接近只弹一次提示（同一账户、团队、周期、状态），引导去网页买流量包，**不断开**。
  网页地址：API 在 `veylo.link` 系时同源，否则 `https://veylo.link`。代码：`ApplicationLibrary/V7/V7Quota.swift`。
- 可用率：`/lines` 的 `uptime`，规则同桌面 `lineUptimeView`（24 小时窗口、样本 ≥ 3、bars 1–48 个 0/1），线路列表右侧显示百分比。

## 验证

单测（macOS 或 Linux 的 Swift 5.9+）：

```bash
cd V7Tests/TrafficLedger && swift test
```

TestFlight 真机：

1. 登录 → 选线连接 → 正常上网几分钟 → 断开。
2. 回到 App（或等 2 分钟），后台 `client_traffic_usage` 里应出现 `platform = 'ios'` 的行，`route_id` 有值。
3. 「我的 → 流量」显示本周期已用 / 总量；把测试团队额度调到接近 / 超出，回前台应弹一次提示，连接不断。
