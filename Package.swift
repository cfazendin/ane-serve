// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ane-serve",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "ane-serve", targets: ["ANEServe"])
    ],
    targets: [
        // Declares the private libIOReport functions used for telemetry; the module map links the library.
        .systemLibrary(
            name: "CIOReport",
            path: "Sources/CIOReport"
        ),
        .executableTarget(
            name: "ANEServe",
            dependencies: ["CIOReport"],
            path: "Sources/ANEServe",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("CoreML"),
                .linkedFramework("CoreAI"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("Vision"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("Metal")
            ]
        ),
        .testTarget(
            name: "ANEServeTests",
            dependencies: ["ANEServe"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
