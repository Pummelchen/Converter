# Contributing to Converter

Converter is a Swift CLI media production pipeline for macOS Apple Silicon. Contributions are welcome; please read this guide before opening a pull request.

## Getting started

```bash
git clone https://github.com/Pummelchen/Converter.git
cd Converter
brew install ffmpeg imagemagick        # runtime media tools
swift build --package-path Sources     # build
swift test --package-path Sources      # run all tests (122 tests, ~6 min)
```

Requires Swift tools 6.3.3+ (Swift language mode 6) and macOS 14+. See the [wiki](https://github.com/Pummelchen/Converter/wiki) for command reference and configuration details.

## Repository layout essentials

- The Swift Package lives at `Sources/` — always use `--package-path Sources` with `swift` commands.
- `Output/` is a runtime working directory for inputs/outputs. It is git-ignored except `.gitkeep`. Do not commit media files.
- `converter` at the repo root is a checked-in release binary. Only replace it intentionally after a release build (see below).
- `Sources/ThirdParty/libbw64/` is vendored code; avoid editing unless the change is specifically about BW64 support.

## Build and test commands

```bash
swift build --package-path Sources            # build/typecheck
swift build --package-path Sources -c release # release build
swift test --package-path Sources             # full test suite
swift test --package-path Sources --filter converterTests.<testName>  # focused test
```

Integration tests perform real media processing with `ffmpeg`/`ffprobe`/`magick` in isolated temporary workspaces; they never touch your `Output/` directory.

Dependency auto-install is disabled in tests; for manual dependency checks without install side effects:

```bash
CONVERTER_AUTO_INSTALL_DEPS=0 ./converter -doctor
```

## Safety rules for changes

- Keep command execution through `ProcessRunner` with array arguments; do not build shell command strings.
- Preserve direct-child path containment for explicit input/output paths (no subfolder or absolute-path escapes).
- Preserve hidden run-scoped temp files, backup-based publishing, and verify-before-publish behavior.
- Do not weaken media validation/QC thresholds or loudness-preservation semantics without calling it out explicitly.
- Operational commands may auto-install missing Homebrew formulae; do not broaden install/network behavior without review.

## Tests

- Use XCTest in `Sources/Tests/converterTests/`; `@testable import converter`.
- Unit tests go in `converterTests.swift`; media-processing tests in `PipelineIntegrationTests.swift` using the `IntegrationWorkspace` helpers from `IntegrationTestSupport.swift` (generated fixtures only — never private/user media).
- Config schema changes need tests for parsing, profile overlay, and invalid values.
- CLI changes need parser/help-text tests; removed flags must keep their actionable rejection errors.

## Documentation sync

Keep these consistent with any behavior change:

- `README.md` (user-facing contracts)
- `config.txt` + `Sources/converter/Config.swift` (config schema — both together)
- CLI help text in `Sources/converter/CLI.swift`
- Wiki pages where relevant

## Release binary updates

Only when explicitly part of the change:

```bash
swift build --package-path Sources -c release
cp Sources/.build/arm64-apple-macosx/release/converter ./converter
chmod +x ./converter
```

State in the PR that the binary was regenerated and why.

## Pull request expectations

- One focused change per PR; describe commands run and results (do not claim tests passed without running them).
- New behavior requires tests; bug fixes require a regression test where practical.
