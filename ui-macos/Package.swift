// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CloudRedirect", platforms: [.macOS(.v15)], targets: [.executableTarget(name: "CloudRedirect", path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "CloudRedirectTests", dependencies: ["CloudRedirect"], path: "Tests")])
