// swift-tools-version: 6.3.3
import PackageDescription

let package = Package(
    name: "converter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "converter", targets: ["converter"])
    ],
    targets: [
        .target(
            name: "BW64Bridge",
            path: "BW64Bridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../ThirdParty/libbw64")
            ]
        ),
        .executableTarget(
            name: "converter",
            dependencies: ["BW64Bridge"],
            path: "converter",
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "converterTests",
            dependencies: ["converter"],
            path: "Tests/converterTests"
        )
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
