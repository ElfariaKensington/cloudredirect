// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CloudRedirectSwift", platforms: [.macOS(.v15)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(name: "CloudRedirectSwift", dependencies: [.product(name: "CloudRedirectSupport", package: "ui-macos")], path: "Sources/CloudRedirectSwift", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NativeBackendTests", dependencies: ["CloudRedirectSwift"], path: "Tests")
    ]
)
