// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LogRollerModules",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LogRollerCore", targets: ["LogRollerCore"]),
        .library(name: "LogRollerServer", targets: ["LogRollerServer"]),
    ],
    targets: [
        .target(name: "LogRollerCore"),
        .target(name: "LogRollerServer", dependencies: ["LogRollerCore"]),
        .testTarget(name: "LogRollerCoreTests", dependencies: ["LogRollerCore"]),
    ]
)
