// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CloudRedirect",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CloudRedirectSupport", targets: ["CloudRedirectSupport"])],
    targets: [
        .target(name: "CloudRedirectSupport", path: "Support", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "CloudRedirect", dependencies: ["CloudRedirectSupport"], path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CloudRedirectTests", dependencies: ["CloudRedirectSupport"], path: "Tests")
    ]
)
