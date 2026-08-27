// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "EasySticky",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "EasySticky", targets: ["EasySticky"]),
        .executable(name: "EasyStickyCoreChecks", targets: ["EasyStickyCoreChecks"])
    ],
    targets: [
        .target(name: "EasyStickyCore"),
        .executableTarget(
            name: "EasySticky",
            dependencies: ["EasyStickyCore"]
        ),
        .executableTarget(
            name: "EasyStickyCoreChecks",
            dependencies: ["EasyStickyCore"]
        )
    ]
)
