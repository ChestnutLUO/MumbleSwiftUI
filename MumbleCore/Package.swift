// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MumbleCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "MumbleProtocol", targets: ["MumbleProtocol"]),
    ],
    dependencies: [
        // Vendored (1.38.1) because SwiftPM's full git clone of
        // github.com/apple/swift-protobuf repeatedly failed on this network;
        // matches the brew-installed protoc-gen-swift used for codegen.
        .package(path: "Vendor/swift-protobuf"),
    ],
    targets: [
        .target(
            name: "MumbleProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: ["Proto"]
        ),
        .testTarget(
            name: "MumbleProtocolTests",
            dependencies: ["MumbleProtocol"]
        ),
    ]
)
