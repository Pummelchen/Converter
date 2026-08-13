# Known-Good Toolchain and Dependency Versions

Versions recorded from successful local builds and full test runs. These are reference points, not hard pins — the repository only requires Swift tools 6.3.3+, Swift language mode 6, and macOS 15+ (per `.macOS(.v15)` in `Sources/Package.swift`).

## Recorded environment (2026-08-04)

| Component | Version | Notes |
|---|---|---|
| macOS | 26.6 (build 25G72) | Apple Silicon (`arm64`) |
| Xcode | 26.6 (build 17F113) | command line tools |
| Swift | 6.3.3 (`swiftlang-6.3.3.1.3`) | swift-driver 1.148.6 |
| ffmpeg / ffprobe | 8.1.2 | Homebrew formula `ffmpeg` |
| ImageMagick (`magick`) | 7.1.2-29 Q16-HDRI aarch64 | Homebrew formula `imagemagick` |
| Homebrew | 6.0.13 | |

Validation performed at commit `c75929f41d4c17970b367c43051de3f6cb09af90`:

- `swift build --package-path Sources` — success
- `swift test --package-path Sources` — 122 tests, 0 failures (~6 min; integration tests perform real media processing)

## Recorded environment (2026-08-09)

Same machine/toolchain as the 2026-08-04 record. Validation after the production-hardening pass — internal WAV standard is now 24-bit `pcm_s24le` @ 96 kHz stereo, with the new `-master` command, settings-specific fade output stems, fail-closed publishing, and process timeouts:

- `swift build --package-path Sources` — success, no warnings
- `swift test --package-path Sources` — 138 tests, 0 failures (~8 min; integration tests perform real media processing)

## Recorded environment (2026-08-13)

Validation after the production-readiness audit remediation: cancellation-safe `AsyncSemaphore`,
three-file archival set (no `_BW64.flac`), verified BW64 header finalization, fail-closed hash rename,
whole-file canonical PCM comparison, merged QC/image probes, and the shared video encoder ladder.

| Component | Version | Notes |
|---|---|---|
| macOS | 26.6.1 | Apple Silicon (`arm64`) |
| Swift | 6.3.3 (`swiftlang-6.3.3.1.3`) | swift-driver 1.148.6 |
| ffmpeg / ffprobe | 9.0.1 | Homebrew formula `ffmpeg` |
| ImageMagick (`magick`) | 7.1.2-29 Q16-HDRI aarch64 | Homebrew formula `imagemagick` |

- `swift build --package-path Sources` — success, clean under `-warnings-as-errors`
- `swift test --package-path Sources` — 146 tests, 0 failures (~7.5 min)

Note: ffmpeg 9.0.1 is a major-version step up from the 8.1.2 recorded above and passes the full suite.

### Why the release build stays CPU-generic

Measured on an Apple M3, CRC-32 over 256 MB, release settings (`-O -cross-module-optimization`):

| Build | Time per pass |
|---|---|
| Generic `arm64-apple-macosx` (shipped) | 606–646 ms |
| `-Xllvm -mcpu=apple-m3` | 618–630 ms |

The spread between repeated runs of the *same* binary is larger than the difference between
the two binaries, so M3-specific codegen buys nothing measurable here. It is not free either:
`-mcpu=apple-m3` enables BF16, BTI, FRINT and int8-matmul, none of which exist on M1 or M2 and
none of which this code can use — the only hot loops are integer table lookups over memory.
Building that way risks `SIGILL` on older Apple Silicon and on CI runners.

The actual win came from the algorithm, not the target: slice-by-8 CRC-32 runs at **114 ms per
pass**, roughly 5x faster than the byte-at-a-time form, on every Apple Silicon generation.

To produce an M3-tuned local build anyway (not for distribution):

```bash
swift build --package-path Sources -c release -Xswiftc -Xllvm -Xswiftc -mcpu=apple-m3 -Xcc -mcpu=apple-m3
```

## How to collect these versions locally

```bash
sw_vers
uname -m
swift --version
xcodebuild -version
ffmpeg -version | head -1
ffprobe -version | head -1
magick -version | head -1
brew --version
```

## Update policy

Append a new dated section when a materially different toolchain is verified (new macOS major, new ffmpeg/ImageMagick major, or after a compatibility issue). Do not over-pin: converter checks encoder/filter availability at runtime (`-doctor`) and uses encoder fallback ladders, so minor tool version drift is expected to work.
