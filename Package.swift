// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LogMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SensorsC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "LogMac",
            dependencies: ["SensorsC"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        ),
    ]
)
