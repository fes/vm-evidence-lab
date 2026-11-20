// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VMHostObserver",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "vm-host-observer", targets: ["VMHostObserver"]),
    ],
    targets: [
        .executableTarget(
            name: "VMHostObserver",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        .testTarget(name: "VMHostObserverTests", dependencies: ["VMHostObserver"]),
    ]
)
