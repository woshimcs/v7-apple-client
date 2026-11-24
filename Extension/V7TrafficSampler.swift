import Foundation
import Libbox
import Library

/// V7 自有文件（不改上游）。在 Network Extension 里采集走代理的上下行（CF-21）。
///
/// 做法：扩展连自己的 libbox 命令服务（同进程 unix socket），只订阅 CommandConnections。
/// 事件里有每条连接的线路（chain）和上下行增量，交给 [V7TrafficAccumulator] 按线路累加；
/// 每 60 秒把累加结果并进 App Group 的 open.json（[V7TrafficQueue]），封批后由主 App 上传。
///
/// 为了省扩展内存：
///   - 不保留 libbox 的 Connections 列表，只记每条活跃连接的线路和累计值；
///   - 事件间隔 5 秒（增量会累加，间隔长短不影响总量；关闭事件带最终累计）；
///   - 扩展里不联网、不解析 /lines，route_id 等上下文由主 App 写进 meta.json。
///
/// 口径与桌面相同：woshimcs/v7-win-pc docs/TRAFFIC_ACCOUNTING.md。Related to collections#695
final class V7TrafficSampler {
    static let shared = V7TrafficSampler()

    private static let flushInterval: TimeInterval = 60
    private static let reconnectDelay: TimeInterval = 10
    private static let eventIntervalNanos: Int64 = 5_000_000_000

    private let queue = DispatchQueue(label: "link.veylo.traffic", qos: .utility)
    private let accumulator = V7TrafficAccumulator()
    private let store = V7TrafficQueue(directory: FilePath.sharedDirectory.appendingPathComponent("v7-traffic", isDirectory: true))
    private var client: LibboxCommandClient?
    private var timer: DispatchSourceTimer?
    private var running = false
    /// 每次重连加 1；旧连接的回调按代数作废。
    private var generation = 0

    private init() {}

    /// 隧道起来后调用。config 是正在跑的 sing-box 配置，用来查每条线路的协议 / 传输 / 安全层。
    func start(config: String?) {
        queue.async { [self] in
            guard !running else { return }
            running = true
            // 上一次扩展被系统杀掉时遗留的 open.json：先封掉交给主 App。
            store.sealOpen()
            accumulator.setCatalog(V7TrafficCatalog.fromSingbox(config ?? ""))
            startTimer()
            connect()
        }
    }

    /// 主 App 换线路 / 改自动切换后会 reload 配置，线路目录跟着换。
    func reloadCatalog(config: String?) {
        queue.async { [self] in
            guard running, let config, !config.isEmpty else { return }
            flush()
            accumulator.setCatalog(V7TrafficCatalog.fromSingbox(config))
        }
    }

    /// 隧道停止前调用：最后封一批。不联网，耗时只有一次小文件写入。
    func stop() {
        queue.sync { [self] in
            guard running else { return }
            running = false
            generation += 1
            timer?.cancel()
            timer = nil
            flush()
            store.sealOpen()
            let old = client
            client = nil
            DispatchQueue.global(qos: .utility).async { try? old?.disconnect() }
        }
    }

    // MARK: - 内部（都在 queue 上）

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
    }

    private func flush() {
        let buckets = accumulator.drain()
        let meta = store.readMeta()
        let samples = V7TrafficSample.make(buckets, meta: meta)
        // 没有新样本也调一次：open.json 到期了要封批。
        store.append(samples, owner: meta.owner)
    }

    private func connect() {
        generation += 1
        let gen = generation
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandConnections)
        options.statusInterval = Self.eventIntervalNanos
        guard let newClient = LibboxNewCommandClient(Handler(self, generation: gen), options) else {
            scheduleReconnect(gen)
            return
        }
        let old = client
        client = newClient
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? old?.disconnect()
            do {
                try newClient.connect()
            } catch {
                self?.connectionLost(gen)
            }
        }
    }

    private func scheduleReconnect(_ gen: Int) {
        queue.asyncAfter(deadline: .now() + Self.reconnectDelay) { [weak self] in
            guard let self, self.running, gen == self.generation else { return }
            self.connect()
        }
    }

    fileprivate func connectionLost(_ gen: Int) {
        queue.async { [self] in
            guard running, gen == generation else { return }
            scheduleReconnect(gen)
        }
    }

    fileprivate func apply(_ events: LibboxConnectionEvents, generation gen: Int) {
        // 先在回调线程把事件转成值，避免 gomobile 对象跨线程。
        var rows: [Row] = []
        if let it = events.iterator() {
            while it.hasNext() {
                guard let event = it.next() else { continue }
                rows.append(Row(event))
            }
        }
        let batch = rows
        queue.async { [self] in
            guard running, gen == generation else { return }
            for row in batch {
                switch row.kind {
                case .new, .closed:
                    if let c = row.connection {
                        accumulator.observe(
                            id: row.id,
                            chain: c.chain,
                            outbound: c.outbound,
                            outboundType: c.outboundType,
                            network: c.network,
                            upTotal: c.upTotal,
                            downTotal: c.downTotal,
                            isClosed: row.kind == .closed
                        )
                    } else if row.kind == .closed {
                        accumulator.markClosed(id: row.id)
                    }
                case .update:
                    accumulator.addDelta(id: row.id, up: row.upDelta, down: row.downDelta)
                case .other:
                    break
                }
            }
        }
    }

    private struct Row {
        enum Kind { case new, update, closed, other }
        struct Conn {
            let chain: [String]
            let outbound: String
            let outboundType: String
            let network: String
            let upTotal: Int64
            let downTotal: Int64
        }

        let kind: Kind
        let id: String
        let upDelta: Int64
        let downDelta: Int64
        let connection: Conn?

        init(_ event: LibboxConnectionEvent) {
            switch Int(event.type) {
            case Int(LibboxConnectionEventNew): kind = .new
            case Int(LibboxConnectionEventUpdate): kind = .update
            case Int(LibboxConnectionEventClosed): kind = .closed
            default: kind = .other
            }
            id = event.id_
            upDelta = event.uplinkDelta
            downDelta = event.downlinkDelta
            if let c = event.connection {
                connection = Conn(
                    chain: c.chain()?.toArray() ?? [],
                    outbound: c.outbound,
                    outboundType: c.outboundType,
                    network: c.network,
                    upTotal: c.uplinkTotal,
                    downTotal: c.downlinkTotal
                )
            } else {
                connection = nil
            }
        }
    }

    /// 只关心连接事件；其余回调空实现。方法表对齐 Library/Network/CommandClient.swift 的 clientHandler。
    private final class Handler: NSObject, LibboxCommandClientHandlerProtocol {
        private weak var sampler: V7TrafficSampler?
        private let generation: Int

        init(_ sampler: V7TrafficSampler, generation: Int) {
            self.sampler = sampler
            self.generation = generation
        }

        func connected() {}

        func disconnected(_: String?) {
            sampler?.connectionLost(generation)
        }

        func setDefaultLogLevel(_: Int32) {}
        func clearLogs() {}
        func writeLogs(_: (any LibboxLogIteratorProtocol)?) {}
        func writeStatus(_: LibboxStatusMessage?) {}
        func writeGroups(_: LibboxOutboundGroupIteratorProtocol?) {}
        func writeOutbounds(_: (any LibboxOutboundGroupItemIteratorProtocol)?) {}
        func initializeClashMode(_: LibboxStringIteratorProtocol?, currentMode _: String?) {}
        func updateClashMode(_: String?) {}
        func write(_: LibboxDnsQuery?) {}

        func write(_ events: LibboxConnectionEvents?) {
            guard let events else { return }
            sampler?.apply(events, generation: generation)
        }
    }
}
