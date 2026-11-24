import Foundation
import Library
import NetworkExtension

// MODIFIED-BY-V7: 隧道起停 / reload 时带上 Veylo 用量采样（Extension/V7TrafficSampler.swift，CF-21）。
// 上游这里是空子类；采样只在 super 之后启动、在 super 之前停止，不影响隧道本身。
class PacketTunnelProvider: ExtensionProvider {
    override func startTunnel(options: [String: NSObject]?) async throws {
        try await super.startTunnel(options: options)
        V7TrafficSampler.shared.start(config: tunnelOptions?["configContent"] as? String)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        V7TrafficSampler.shared.stop()
        await super.stopTunnel(with: reason)
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        let reply = await super.handleAppMessage(messageData)
        V7TrafficSampler.shared.reloadCatalog(config: tunnelOptions?["configContent"] as? String)
        return reply
    }
}
