// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "converter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "converter", targets: ["converter"]),
        .executable(name: "bw64_writer", targets: ["bw64_writer"])
    ],
    targets: [
        .executableTarget(
            name: "converter",
            path: "converter",
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release))
            ]
        ),
        .executableTarget(
            name: "bw64_writer",
            path: "Tools",
            cxxSettings: [
                .headerSearchPath("../ThirdParty/libbw64")
            ]
        ),
        .testTarget(
            name: "converterTests",
            dependencies: ["converter"],
            path: "Tests/converterTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
