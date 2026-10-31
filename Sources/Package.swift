// swift-tools-version: 6.4
// The audited standard, and what CI enforces: the `xcode-27` runner image asserts `Swift version 6.4`
// and builds with -warnings-as-errors. Recorded locally on Swift 6.4.2 / Xcode 27.2 (see
// docs/KNOWN_GOOD_VERSIONS.md); the gate stays on the 6.4 line so a patch move does not fail it.
//
// GitHub's CodeQL default setup could not follow: its autobuild runner ships Swift 6.3.3, so with this
// floor it failed with "package 'sources' is using Swift tools version 6.4.0 but the installed
// version is 6.3.3" (PR #24, job 104457722762). Swift is therefore switched off in the repository's
// CodeQL default setup until that image moves to Swift 6.4 — re-check by 2026-10-15, tracked as
// #0160 in the wiki Audit Tracker. CodeQL still runs for actions, c-cpp and python, and the
// repository's own static analysis (semgrep, gitleaks, cppcheck, clang-tidy, swiftlint) is unaffected.
import PackageDescription

// Upcoming-feature flags adopted ahead of the next language mode. All of them already build
// clean, so they act as ratchets: new code cannot reintroduce what they forbid.
//
// NonisolatedNonsendingByDefault is adopted together with explicit `@concurrent` annotations on
// the media entry points. The feature makes a `nonisolated` async function run on its caller's
// actor, which is wrong for this tool: the scheduler deliberately runs blocking ffmpeg/magick
// work off the caller's executor (`ConverterTool.execute`, the album/full/runpix steps and
// `ConverterMain.run`). Naming those functions `@concurrent`, and `AsyncSemaphore.withPermit`'s
// operation, keeps the executor they had under Swift 6 mode while moving the default to the
// caller's actor everywhere the tool does not opt out.
//
// Deliberately NOT adopted:
//   - InternalImportsByDefault — governs library API surface; irrelevant to an executable.
//   - StrictMemorySafety — needs `-strict-memory-safety` (the upcoming-feature spelling is a
//     no-op) and flags ~40 sites, most of them `String(format:)` rather than genuine
//     memory unsafety. Poor signal-to-noise here; revisit if the C interop surface grows.
let upcomingFeatures: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
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
