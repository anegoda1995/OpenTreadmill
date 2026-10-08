// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenTreadmill",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenTreadmill", targets: ["OpenTreadmill"]),
    ],
    targets: [
        // Protocols, parsing and models: no UI, no CoreBluetooth, unit tested.
        .target(name: "TreadmillKit"),
        // The SwiftUI app with the CoreBluetooth layer. Swift 5 mode: CoreBluetooth types are not
        // Sendable, and every delegate callback already runs on the main queue (see TreadmillManager).
        .executableTarget(name: "OpenTreadmill", dependencies: ["TreadmillKit"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TreadmillKitTests", dependencies: ["TreadmillKit"]),
    ]
)
