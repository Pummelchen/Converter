# Known-Good Toolchain and Dependency Versions

Versions recorded from a successful local build and full test run (122/122 tests passing). These are reference points, not hard pins — the repository only requires Swift tools 6.3.3+, Swift language mode 6, and macOS 14+.

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
