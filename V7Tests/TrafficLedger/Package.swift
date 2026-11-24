// swift-tools-version:5.9
// V7 计量逻辑的独立单测包（不进 Xcode 工程）。源文件软链到 Library/V7/V7TrafficLedger.swift。
// 运行：cd V7Tests/TrafficLedger && swift test   （macOS 或 Linux 的 Swift 5.9+ 都行）
import PackageDescription

let package = Package(
    name: "TrafficLedger",
    targets: [
        .target(name: "TrafficLedger", path: "Sources/TrafficLedger"),
        .testTarget(name: "TrafficLedgerTests", dependencies: ["TrafficLedger"], path: "Tests/TrafficLedgerTests"),
    ]
)
