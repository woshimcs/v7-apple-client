import Foundation

/// 对齐安卓 V7SubscriptionRepo：拉全部有效订阅，下载 sing-box 导出，再按线路名 join /lines。
public enum V7Catalog {
    public static func sync(fallback: [V7Subscription]) async throws -> (lines: [V7ConfigBuilder.Line], proxy: [String: Any]) {
        let subs = await activeSubscriptions(fallback: fallback)
        var lines: [V7ConfigBuilder.Line] = []
        for sub in subs {
            let singURL = sub.export_links?.singbox ?? ""
            let xrayURL = sub.export_links?.xray ?? ""
            guard !singURL.isEmpty || !xrayURL.isEmpty else { continue }
            let name = (sub.name?.isEmpty == false ? sub.name! : "订阅")
            var parsed: [V7ConfigBuilder.Line] = []
            if !singURL.isEmpty,
               let raw = try? await V7ProfileBridge.downloadExport(singURL),
               let export = try? V7ConfigBuilder.parseExport(raw) {
                parsed = V7ConfigBuilder.lines(in: export, subscriptionId: sub.id, subscriptionName: name, exportURL: singURL, xrayExportURL: xrayURL)
            }
            let meta = (try? await V7Api.subscriptionLines(sub.id)) ?? []
            lines.append(contentsOf: join(parsed, meta: meta, subscriptionId: sub.id, subscriptionName: name, xrayExportURL: xrayURL))
        }
        let proxy = (try? await V7Api.proxyConfig()) ?? [:]
        return (lines, proxy)
    }

    private static func activeSubscriptions(fallback: [V7Subscription]) async -> [V7MySubscription] {
        if let rows = try? await V7Api.subscriptions() {
            return rows.filter(isActive)
        }
        return fallback.compactMap { row in
            let sing = row.export_links?.singbox ?? ""
            let xray = row.export_links?.xray ?? ""
            guard row.export_allowed, !sing.isEmpty || !xray.isEmpty else { return nil }
            guard row.status != "revoked", row.status != "expired" else { return nil }
            return V7MySubscription(id: row.id, name: row.name, status: row.status, export_allowed: row.export_allowed, export_links: row.export_links)
        }
    }

    private static func isActive(_ row: V7MySubscription) -> Bool {
        guard row.status != "revoked", row.status != "expired" else { return false }
        guard row.export_allowed != false else { return false }
        let sing = row.export_links?.singbox ?? ""
        let xray = row.export_links?.xray ?? ""
        return !sing.isEmpty || !xray.isEmpty
    }

    /// stealth_primary=false 的隐身兄弟不进列表。sing-box 导出里没有、但 /lines 有的线路也列出来，并标上该用的内核。
    private static func join(_ parsed: [V7ConfigBuilder.Line], meta: [V7LineMeta], subscriptionId: Int, subscriptionName: String, xrayExportURL: String) -> [V7ConfigBuilder.Line] {
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
                line = apply(item, to: line)
            }
            visible.append(line)
        }
        for (name, leftover) in queues {
            for item in leftover {
                if item.stealth_primary == false { continue }
                let choice = V7ConfigBuilder.Line.chooseCore(singboxOK: item.singbox_ok, cores: item.cores ?? [], bestCore: item.best_core)
                var line = V7ConfigBuilder.Line(
                    subscriptionId: subscriptionId,
                    subscriptionName: subscriptionName,
                    tag: name,
                    type: choice.core,
                    region: nil,
                    exportURL: "",
                    xrayExportURL: xrayExportURL,
                    cores: item.cores ?? [],
                    bestCore: item.best_core,
                    singboxOK: item.singbox_ok,
                    singboxRunnable: false,
                    core: choice.core
                )
                line.region = regionText(item)
                visible.append(line)
            }
        }
        return visible
    }

    private static func apply(_ item: V7LineMeta, to line: V7ConfigBuilder.Line) -> V7ConfigBuilder.Line {
        var copy = line
        let region = regionText(item)
        if let region { copy.region = region }
        let cores = item.cores ?? []
        let choice = V7ConfigBuilder.Line.chooseCore(singboxOK: item.singbox_ok, cores: cores, bestCore: item.best_core)
        copy.cores = cores
        copy.bestCore = item.best_core
        copy.singboxOK = item.singbox_ok
        copy.core = choice.core
        copy.singboxRunnable = choice.runnable && !line.exportURL.isEmpty
        return copy
    }

    private static func regionText(_ item: V7LineMeta) -> String? {
        let region = [item.region_emoji, item.region_name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return region.isEmpty ? nil : region
    }
}
