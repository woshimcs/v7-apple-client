import Foundation

/// 对齐安卓 V7SubscriptionRepo：拉全部有效订阅，下载 sing-box 导出，再按线路名 join /lines。
public enum V7Catalog {
    public static func sync(fallback: [V7Subscription]) async throws -> (lines: [V7ConfigBuilder.Line], proxy: [String: Any]) {
        let subs = await activeSubscriptions(fallback: fallback)
        var lines: [V7ConfigBuilder.Line] = []
        for sub in subs {
            guard let url = sub.export_links?.singbox, !url.isEmpty else { continue }
            guard let raw = try? await V7ProfileBridge.downloadExport(url),
                  let export = try? V7ConfigBuilder.parseExport(raw)
            else { continue }
            let parsed = V7ConfigBuilder.lines(
                in: export,
                subscriptionId: sub.id,
                subscriptionName: (sub.name?.isEmpty == false ? sub.name! : "订阅"),
                exportURL: url
            )
            let meta = (try? await V7Api.subscriptionLines(sub.id)) ?? []
            lines.append(contentsOf: join(parsed, meta: meta))
        }
        let proxy = (try? await V7Api.proxyConfig()) ?? [:]
        return (lines, proxy)
    }

    private static func activeSubscriptions(fallback: [V7Subscription]) async -> [V7MySubscription] {
        if let rows = try? await V7Api.subscriptions() {
            return rows.filter(isActive)
        }
        return fallback.compactMap { row in
            guard row.export_allowed, let link = row.export_links?.singbox, !link.isEmpty else { return nil }
            guard row.status != "revoked", row.status != "expired" else { return nil }
            return V7MySubscription(id: row.id, name: row.name, status: row.status, export_allowed: row.export_allowed, export_links: row.export_links)
        }
    }

    private static func isActive(_ row: V7MySubscription) -> Bool {
        guard row.status != "revoked", row.status != "expired" else { return false }
        guard row.export_allowed != false else { return false }
        return !(row.export_links?.singbox ?? "").isEmpty
    }

    /// stealth_primary=false 的隐身兄弟不进列表；缺字段则展示。地区来自 /lines。
    private static func join(_ parsed: [V7ConfigBuilder.Line], meta: [V7LineMeta]) -> [V7ConfigBuilder.Line] {
        var queues: [String: [V7LineMeta]] = [:]
        for item in meta {
            let name = (item.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            queues[name, default: []].append(item)
        }
        var visible: [V7ConfigBuilder.Line] = []
        for var line in parsed {
            let key = line.tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if var bucket = queues[key], !bucket.isEmpty {
                let item = bucket.removeFirst()
                queues[key] = bucket
                if item.stealth_primary == false { continue }
                let region = [item.region_emoji, item.region_name]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !region.isEmpty { line.region = region }
            }
            visible.append(line)
        }
        return visible
    }
}
