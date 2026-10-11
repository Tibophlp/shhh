// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shhh",
    platforms: [.macOS(.v14)],
    dependencies: [
        // On-device speech recognition (Parakeet on the Apple Neural Engine)
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        // llama.cpp, used for the optional AI cleanup pass
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11550/llama-b11550-xcframework.zip",
            checksum: "408024918825f85d796403aa9743e8b0726af709296519437c2fe65685221648"
        ),
        .executableTarget(
            name: "Shhh",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "llama",
            ],
            path: "Sources/Shhh",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
