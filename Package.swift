// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceOverRadarKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "VoiceOverRadarKit", targets: ["VoiceOverRadarKit"]),
    ],
    targets: [
        .target(name: "VoiceOverRadarKit"),
        .testTarget(
            name: "VoiceOverRadarKitTests",
            dependencies: ["VoiceOverRadarKit"]
        ),
    ]
)
