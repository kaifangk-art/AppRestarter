// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppRestarter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AppRestarter", targets: ["AppRestarter"])
    ],
    targets: [
        .executableTarget(
            name: "AppRestarter"
        )
    ]
)
