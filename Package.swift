// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "GCF",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(name: "GCF", targets: ["GCF"]),
    ],
    targets: [
        .target(name: "GCF"),
        .testTarget(name: "GCFTests", dependencies: ["GCF"]),
        .executableTarget(name: "GCFCLI", dependencies: ["GCF"]),
        .executableTarget(name: "RunTests", dependencies: ["GCF"], path: "TestRunner"),
    ]
)
