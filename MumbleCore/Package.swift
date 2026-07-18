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
        .library(name: "MumbleConnection", targets: ["MumbleConnection"]),
        .library(name: "MumbleCrypto", targets: ["MumbleCrypto"]),
        .library(name: "MumbleAudio", targets: ["MumbleAudio"]),
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
        .target(
            name: "MumbleConnection",
            dependencies: ["MumbleProtocol", "MumbleCrypto"]
        ),
        .target(
            name: "MumbleCrypto"
        ),
        // Homebrew libopus for macOS development; iOS builds will need a
        // vendored/xcframework Opus later.
        .systemLibrary(
            name: "COpus",
            pkgConfig: "opus",
            providers: [.brew(["opus"])]
        ),
        .target(
            name: "MumbleAudio",
            dependencies: ["COpus", "MumbleProtocol"]
        ),
        .testTarget(
            name: "MumbleAudioTests",
            dependencies: ["MumbleAudio"]
        ),
        .testTarget(
            name: "MumbleCryptoTests",
            dependencies: ["MumbleCrypto"]
        ),
        .testTarget(
            name: "MumbleProtocolTests",
            dependencies: ["MumbleProtocol"]
        ),
        .testTarget(
            name: "MumbleConnectionTests",
            dependencies: ["MumbleConnection", "MumbleAudio"]
        ),
    ]
)
