// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "Headroom", targets: ["Headroom"])],
    targets: [
        .target(name: "HeadroomCore"),
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore"],
                          linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("CoreAudio")]),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"])
    ],
    swiftLanguageModes: [.v5]
)
