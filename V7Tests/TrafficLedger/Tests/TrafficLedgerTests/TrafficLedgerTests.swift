import Foundation
@testable import TrafficLedger
import XCTest

final class TrafficLedgerTests: XCTestCase {
    private let config = """
    {"outbounds":[
      {"type":"urltest","tag":"proxy","outbounds":["HK 1","JP 1"]},
      {"type":"vless","tag":"HK 1","tls":{"enabled":true,"reality":{"enabled":true}}},
      {"type":"trojan","tag":"JP 1","tls":{"enabled":true},"transport":{"type":"ws"}},
      {"type":"shadowsocks","tag":"SG 1"},
      {"type":"direct","tag":"direct"}
    ]}
    """

    private var catalog: [String: V7TrafficLineProfile] { V7TrafficCatalog.fromSingbox(config) }

    func testCatalogReadsProtocolTransportSecurity() {
        let c = catalog
        XCTAssertEqual(Set(c.keys), ["HK 1", "JP 1", "SG 1"])
        XCTAssertEqual(c["HK 1"], V7TrafficLineProfile(tag: "HK 1", proto: "vless", transport: "tcp", security: .reality))
        XCTAssertEqual(c["JP 1"], V7TrafficLineProfile(tag: "JP 1", proto: "trojan", transport: "ws", security: .tls))
        XCTAssertEqual(c["SG 1"]?.security, V7TrafficSecurity.none)
        XCTAssertTrue(V7TrafficCatalog.fromSingbox("not json").isEmpty)
    }

    func testClassifyPicksTheMemberWhateverTheChainOrder() {
        let c = catalog
        XCTAssertEqual(V7TrafficCatalog.classify(chain: ["proxy", "HK 1"], outbound: "proxy", outboundType: "urltest", catalog: c)?.tag, "HK 1")
        XCTAssertEqual(V7TrafficCatalog.classify(chain: ["JP 1", "proxy"], outbound: "proxy", outboundType: "urltest", catalog: c)?.tag, "JP 1")
        XCTAssertEqual(V7TrafficCatalog.classify(chain: ["HK 1#2"], outbound: "", outboundType: "vless", catalog: c)?.tag, "HK 1")
        XCTAssertNil(V7TrafficCatalog.classify(chain: ["direct"], outbound: "direct", outboundType: "direct", catalog: c))
        XCTAssertNil(V7TrafficCatalog.classify(chain: [], outbound: "dns-out", outboundType: "dns", catalog: c))
        let unknown = V7TrafficCatalog.classify(chain: ["proxy"], outbound: "proxy", outboundType: "urltest", catalog: c)
        XCTAssertEqual(unknown?.tag, "proxy")
        XCTAssertEqual(unknown?.proto, "unknown")
    }

    func testAccumulatorCountsNewUpdateAndCloseOnce() {
        let acc = V7TrafficAccumulator(catalog: catalog)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        acc.observe(id: "a", chain: ["proxy", "HK 1"], outbound: "proxy", outboundType: "urltest", network: "tcp", upTotal: 10, downTotal: 20, isClosed: false, now: t0)
        acc.addDelta(id: "a", up: 5, down: 7)
        acc.addDelta(id: "ghost", up: 100, down: 100) // 没见过 New，丢掉
        // Closed 带最终累计：只补差额（15/27 已计过）
        acc.observe(id: "a", chain: ["proxy", "HK 1"], outbound: "proxy", outboundType: "urltest", network: "tcp", upTotal: 16, downTotal: 30, isClosed: true, now: t0)
        // 重新订阅 Reset 时，5 分钟内关闭的连接会再出现：不能再计
        acc.observe(id: "a", chain: ["HK 1"], outbound: "HK 1", outboundType: "vless", network: "tcp", upTotal: 16, downTotal: 30, isClosed: true, now: t0)
        acc.observe(id: "u", chain: ["JP 1"], outbound: "JP 1", outboundType: "trojan", network: "UDP", upTotal: 1, downTotal: 2, isClosed: false, now: t0)
        acc.observe(id: "d", chain: ["direct"], outbound: "direct", outboundType: "direct", network: "tcp", upTotal: 999, downTotal: 999, isClosed: false, now: t0)

        let buckets = acc.drain(now: t0)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].line.tag, "HK 1")
        XCTAssertEqual(buckets[0].up, 16)
        XCTAssertEqual(buckets[0].down, 30)
        XCTAssertEqual(buckets[1].line.tag, "JP 1")
        XCTAssertEqual(buckets[1].flow, "udp")
        XCTAssertTrue(acc.drain(now: t0).isEmpty)

        // 关闭 10 分钟后 ID 被忘掉（服务端只保留 5 分钟，不会再出现）
        _ = acc.drain(now: t0.addingTimeInterval(11 * 60))
        acc.observe(id: "a", chain: ["HK 1"], outbound: "HK 1", outboundType: "vless", network: "tcp", upTotal: 1, downTotal: 1, isClosed: false, now: t0)
        XCTAssertEqual(acc.drain(now: t0).first?.up, 1)
    }

    func testAccumulatorSnapshotAfterReconnectOnlyCountsTheGrowth() {
        let acc = V7TrafficAccumulator(catalog: catalog)
        acc.observe(id: "x", chain: ["SG 1"], outbound: "SG 1", outboundType: "shadowsocks", network: "tcp", upTotal: 100, downTotal: 100, isClosed: false)
        _ = acc.drain()
        // 订阅断开重连后 Reset 快照再发一次 New，累计 150/120：只记 50/20
        acc.observe(id: "x", chain: ["SG 1"], outbound: "SG 1", outboundType: "shadowsocks", network: "tcp", upTotal: 150, downTotal: 120, isClosed: false)
        let b = acc.drain()
        XCTAssertEqual(b.first?.up, 50)
        XCTAssertEqual(b.first?.down, 20)
    }

    func testSamplesCarryRouteAndCollectionAndHourBucket() {
        let acc = V7TrafficAccumulator(catalog: catalog)
        acc.observe(id: "a", chain: ["HK 1"], outbound: "HK 1", outboundType: "vless", network: "tcp", upTotal: 3, downTotal: 4, isClosed: false)
        acc.observe(id: "b", chain: ["JP 1"], outbound: "JP 1", outboundType: "trojan", network: "tcp", upTotal: 1, downTotal: 1, isClosed: false)
        let meta = V7TrafficMeta(owner: "id:u1", appVersion: "1.1.0", os: "iOS 18.1", preferredTag: "HK 1", collectionId: 9, routeIds: ["HK 1": 42, "JP 1": 0])
        let now = Date(timeIntervalSince1970: 1_795_000_000 + 1234) // 不在整点
        let samples = V7TrafficSample.make(acc.drain(), meta: meta, now: now)
        XCTAssertEqual(samples.count, 2)
        let hk = samples.first { $0.line_tag == "HK 1" }!
        XCTAssertEqual(hk.platform, "ios")
        XCTAssertEqual(hk.vpn_mode, "tun")
        XCTAssertEqual(hk.core, "veylo")
        XCTAssertEqual(hk.line_security, "reality")
        XCTAssertEqual(hk.route_id, 42)
        XCTAssertEqual(hk.collection_id, 9)
        XCTAssertTrue(hk.bucket_start.hasSuffix(":00:00Z"), hk.bucket_start)
        XCTAssertNil(samples.first { $0.line_tag == "JP 1" }!.route_id, "route_id 0 不带")

        // 上传体：route_id 为空时整个键省略（服务端旧版本按 line_tag 兜底）
        let batch = V7TrafficBatch(batch_id: "ABC", owner: nil, created_at: 0, samples: samples)
        let json = String(data: try! JSONEncoder().encode(batch.upload), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"batch_id\":\"abc\""))
        XCTAssertEqual(json.components(separatedBy: "route_id").count - 1, 1)
        XCTAssertFalse(json.contains("owner"))
    }

    func testHourBucketIsUTC() {
        XCTAssertEqual(V7TrafficSample.hourBucket(Date(timeIntervalSince1970: 1_795_003_599)), "2026-11-18T12:00:00Z")
    }

    func testQueueMergesSealsAndHandsOver() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v7q-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = V7TrafficQueue(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_795_000_000)
        func sample(_ tag: String, _ up: Int64) -> V7TrafficSample {
            V7TrafficSample(platform: "ios", app_version: "1.1.0", os: nil, arch: "arm64", line_tag: tag, preferred_tag: nil, line_protocol: "vless", line_transport: "tcp", line_security: "tls", vpn_mode: "tun", core: "veylo", flow_network: "tcp", bytes_up: up, bytes_down: up, bucket_start: V7TrafficSample.hourBucket(t0), route_id: nil, collection_id: nil)
        }

        XCTAssertFalse(q.append([sample("HK", 1)], owner: "id:1", now: t0))
        XCTAssertFalse(q.append([sample("HK", 2), sample("JP", 5)], owner: "id:1", now: t0.addingTimeInterval(60)))
        XCTAssertTrue(q.sealedFiles().isEmpty)
        let open = try XCTUnwrap(q.readOpen())
        XCTAssertEqual(open.samples.count, 2)
        XCTAssertEqual(open.samples.first { $0.line_tag == "HK" }?.bytes_up, 3)

        // 10 分钟到了：下一拍（即使没有新样本）就封批
        XCTAssertTrue(q.append([], owner: "id:1", now: t0.addingTimeInterval(601)))
        XCTAssertNil(q.readOpen())
        XCTAssertEqual(q.sealedFiles().count, 1)

        // 换账户：旧账户的 open 先封掉，新账户另起一批
        q.append([sample("HK", 1)], owner: "id:1", now: t0.addingTimeInterval(700))
        q.append([sample("HK", 1)], owner: "id:2", now: t0.addingTimeInterval(710))
        XCTAssertEqual(q.sealedFiles().count, 2)
        XCTAssertEqual(q.readOpen()?.owner, "id:2")
        XCTAssertTrue(q.sealOpen(now: t0.addingTimeInterval(720)))
        let files = q.sealedFiles()
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.compactMap { q.readSealed($0)?.owner }, ["id:1", "id:1", "id:2"], "旧的在前")
        q.remove(files[0])
        XCTAssertEqual(q.sealedFiles().count, 2)
        XCTAssertFalse(q.sealOpen())
    }

    func testQueueSealsWhenFull() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v7q-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = V7TrafficQueue(directory: dir)
        let rows = (0 ..< V7TrafficQueue.sealAtSamples).map { i in
            V7TrafficSample(platform: "ios", app_version: nil, os: nil, arch: nil, line_tag: "L\(i)", preferred_tag: nil, line_protocol: "vless", line_transport: "tcp", line_security: "none", vpn_mode: "tun", core: "veylo", flow_network: "tcp", bytes_up: 1, bytes_down: 0, bucket_start: "2026-11-24T14:00:00Z", route_id: nil, collection_id: nil)
        }
        XCTAssertTrue(q.append(rows, owner: nil))
        XCTAssertEqual(q.sealedFiles().count, 1)
    }

    func testMetaRoundTripsAndToleratesGarbage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v7q-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = V7TrafficQueue(directory: dir)
        XCTAssertEqual(q.readMeta(), V7TrafficMeta())
        let meta = V7TrafficMeta(owner: "id:7", appVersion: "1.1.0", os: "iOS", preferredTag: "HK", collectionId: 3, routeIds: ["HK": 11])
        q.writeMeta(meta)
        XCTAssertEqual(q.readMeta(), meta)
        try Data("{\"owner\":\"id:7\",\"route_ids\":\"bad\"}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        XCTAssertEqual(q.readMeta().owner, "id:7")
        XCTAssertEqual(q.readMeta().routeIds, [:])
    }

    func testUploadOutcomeMatchesDesktop() {
        XCTAssertEqual(V7TrafficUploadOutcome.from(status: 201), .remove)
        XCTAssertEqual(V7TrafficUploadOutcome.from(status: 200), .remove)
        for s in [400, 403, 404, 409, 413, 422] { XCTAssertEqual(V7TrafficUploadOutcome.from(status: s), .remove) }
        XCTAssertEqual(V7TrafficUploadOutcome.from(status: 401), .stop)
        XCTAssertEqual(V7TrafficUploadOutcome.from(status: 0), .stop)
        XCTAssertEqual(V7TrafficUploadOutcome.from(status: 429), .keep)
        XCTAssertEqual(V7TrafficUploadOutcome.from(status: 503), .keep)
    }

    func testOwnerKeys() {
        let keys = V7TrafficOwner.keys(userId: "u1", username: "bob")
        XCTAssertEqual(keys, ["id:u1", "name:bob"])
        XCTAssertTrue(V7TrafficOwner.belongs(nil, to: keys))
        XCTAssertTrue(V7TrafficOwner.belongs("name:bob", to: keys))
        XCTAssertFalse(V7TrafficOwner.belongs("id:u2", to: keys))
    }
}
