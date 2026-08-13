// swift-tools-version: 6.3.3
import PackageDescription

// Upcoming-feature flags adopted ahead of the next language mode. All four already build
// clean, so they act as ratchets: new code cannot reintroduce what they forbid.
//
// Deliberately NOT adopted:
//   - NonisolatedNonsendingByDefault — changes which executor `nonisolated` async work runs
//     on. The scheduler deliberately runs blocking media tools off the caller's actor, so
//     this is a real behavioral change for no functional gain.
//   - InternalImportsByDefault — governs library API surface; irrelevant to an executable.
//   - StrictMemorySafety — needs `-strict-memory-safety` (the upcoming-feature spelling is a
//     no-op) and flags ~40 sites, most of them `String(format:)` rather than genuine
//     memory unsafety. Poor signal-to-noise here; revisit if the C interop surface grows.
let upcomingFeatures: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures")
]

let package = Package(
    name: "converter",
    platforms: [
        .macOS(.v15)
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
            swiftSettings: upcomingFeatures + [
                // Kept CPU-generic on purpose: the binary must run on every Apple Silicon
                // Mac, and `-mcpu=apple-m3` measured no faster here (see docs/KNOWN_GOOD_VERSIONS.md).
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "converterTests",
            dependencies: ["converter"],
            path: "Tests/converterTests",
            swiftSettings: upcomingFeatures
        )
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
