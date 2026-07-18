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
        // libopus 1.5.2 compiled from vendored source so every Apple
        // platform (macOS, iOS, simulator) builds without Homebrew.
        // Plain-C paths only: arch-specific dirs are excluded, float build.
        .target(
            name: "COpus",
            path: "Vendor/opus",
            exclude: [
                "src/opus_demo.c",
                "src/opus_compare.c",
                "src/repacketizer_demo.c",
                "src/meson.build",
                "celt/arm", "celt/mips", "celt/tests", "celt/x86",
                "celt/opus_custom_demo.c",
                "celt/meson.build",
                "silk/arm", "silk/fixed", "silk/mips", "silk/tests", "silk/x86",
                "silk/float/x86",
                "silk/meson.build",
            ],
            sources: ["src", "celt", "silk"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .define("OPUS_BUILD"),
                .define("FLOATING_POINT"),
                .define("VAR_ARRAYS", to: "1"),
                .define("HAVE_LRINT", to: "1"),
                .define("HAVE_LRINTF", to: "1"),
            ]
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
