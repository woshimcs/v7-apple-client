import Darwin
import Foundation
import NetworkExtension
import VeyloEngine

/// iOS packet tunnel. This process links only veylo-engine.
/// The app still links Libbox for the existing screens. Two Go runtimes in one
/// process crash on launch, so the engine stays out of the app.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnel: VeyloBound?
    private var reading = false

    override func startTunnel(options: [String: NSObject]?) async throws {
        guard let config = options?["configContent"] as? String, !config.isEmpty else {
            throw NSError(domain: "Veylo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "缺少隧道配置",
            ])
        }
        reading = false
        tunnel?.close()
        var translateError: NSError?
        let engineJSON = MobileConfigFromSingbox(config, &translateError)
        if let translateError {
            throw translateError
        }
        try await applySettings()
        let platform = VeyloPlatform(owner: self)
        let bound = try VeyloBound(configJSON: engineJSON, platform: platform)
        try bound.start()
        tunnel = bound
        reading = true
        readPackets()
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        reading = false
        tunnel?.close()
        tunnel = nil
    }

    private func applySettings() async throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500
        let dns = NEDNSSettings(servers: ["172.19.0.2"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.reading, let tunnel = self.tunnel else { return }
            for packet in packets {
                tunnel.input(packet)
            }
            self.readPackets()
        }
    }

    fileprivate func writePacket(_ packet: Data) {
        let family: Int32 = (packet.first ?? 0) >> 4 == 6 ? AF_INET6 : AF_INET
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: family)])
    }
}

private final class VeyloBound {
    private let engine: MobileEngine
    private let platform: VeyloPlatform

    init(configJSON: String, platform: VeyloPlatform) throws {
        self.platform = platform
        var error: NSError?
        guard let created = MobileNewEngine(configJSON, platform, &error) else {
            throw error ?? NSError(domain: "Veylo", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "引擎没有创建",
            ])
        }
        engine = created
    }

    func start() throws { try engine.start() }
    func close() { try? engine.close() }
    func input(_ packet: Data) { try? engine.inputPacket(packet) }
}

private final class VeyloPlatform: NSObject, MobilePlatformProtocol {
    weak var owner: PacketTunnelProvider?

    init(owner: PacketTunnelProvider) { self.owner = owner }

    func openTun(_ optionsJSON: String?, ret0_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        ret0_?.pointee = 0
    }

    func protect(_ fd: Int32) throws {}

    func log(_ level: Int32, line: String?) {
        NSLog("veylo [%d] %@", level, line ?? "")
    }

    func usePacketFlow() -> Bool { true }

    func writePacket(_ packet: Data?) throws {
        guard let packet, !packet.isEmpty else { return }
        owner?.writePacket(packet)
    }
}
