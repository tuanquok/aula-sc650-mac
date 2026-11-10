// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "aula-mac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AulaKit", targets: ["AulaKit"]),
        .executable(name: "aulactl", targets: ["aulactl"]),
        .executable(name: "AulaApp", targets: ["AulaApp"]),
    ],
    targets: [
        .target(name: "AulaKit"),
        .executableTarget(name: "aulactl", dependencies: ["AulaKit"]),
        .executableTarget(name: "AulaApp", dependencies: ["AulaKit"]),
        .testTarget(name: "AulaKitTests", dependencies: ["AulaKit"]),
    ]
)
