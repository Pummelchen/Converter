<!--
AI onboarding file.
Mode: bootstrap
Indexed commit: 0ec7e71f0decd52d208c001ec16c4d7382d73fa7
Last generated: 2026-06-25T10:26:41Z
Generator: generic high-end AI coding agent
Purpose: Help future AI sessions understand this repository quickly.
Audience: Any high-capability AI coding agent, regardless of vendor or model family.
Human edits are allowed. Future refreshes should preserve valid human edits.
-->
# Testing

## Framework

The test target uses XCTest through Swift Package Manager.

Evidence:
- `Sources/Package.swift`
- `Sources/Tests/converterTests/converterTests.swift`

## Test structure

| Path | Purpose |
|---|---|
| `Sources/Tests/converterTests/converterTests.swift` | Unit-style coverage for dependency manifest, PATH enrichment, CLI parsing/help, action arguments, config-oriented behavior. |
| `Sources/Tests/converterTests/PipelineIntegrationTests.swift` | Integration-style media pipeline tests referenced by current HEAD diff and repository inspection. |

Evidence:
- `Sources/Package.swift`
- `Sources/Tests/converterTests/converterTests.swift`
- `Sources/Tests/converterTests/PipelineIntegrationTests.swift`

## Run all tests

```bash
swift test --package-path Sources
```

This is the main validation command documented by the repository.

## Run focused tests

Example:

```bash
swift test --package-path Sources --filter converterTests.testNoArgumentsShowHelpInsteadOfFullRun
```

`inferred`: SwiftPM/XCTest filtering should work, but exact filter behavior depends on the installed Swift toolchain.

## Fixtures and mocks

Verified from inspected tests:

- Tests create temporary directories under `FileManager.default.temporaryDirectory`.
- Tests construct `ConverterTool` directly with parsed `CLIOptions`, `ProjectConfig()`, `Logger`, and `ProcessRunner`.
- Dependency manifest tests assert exact runtime tool lists: system commands `awk`, `sed`; Homebrew formulae `ffmpeg` and `imagemagick`; no Python packages.

Evidence:
- `Sources/Tests/converterTests/converterTests.swift`

## Slow or environment-sensitive tests

`inferred`: Integration tests that exercise actual media processing may require `ffmpeg`, `ffprobe`, and `magick`, and may be slower than pure CLI/config unit tests. Confirm by inspecting `Sources/Tests/converterTests/PipelineIntegrationTests.swift` before running only a subset.

## Minimum validation before a PR

| Change type | Minimum validation |
|---|---|
| CLI parser/help/config logic | `swift test --package-path Sources` or focused relevant XCTest filter plus full tests when feasible |
| Media pipeline behavior | `swift test --package-path Sources`; consider manual runtime command on representative media if safe and user-provided |
| Config schema/defaults | tests plus README/config docs review |
| Dependency bootstrap/process execution | tests plus manual `CONVERTER_AUTO_INSTALL_DEPS=0 ./converter -doctor` where safe |
| Docs-only onboarding | JSON manifest validation and Markdown/link sanity; source tests not required unless docs claim behavior changed |
| Release binary update | release build command, then verify binary was intentionally copied |

## Testing cautions for AI agents

- Do not run commands that process private or large media without confirming the intended `Output/` contents.
- Do not run commands that auto-install dependencies unless that side effect is acceptable. Prefer `CONVERTER_AUTO_INSTALL_DEPS=0` for checks.
- Do not claim full test coverage when only a focused filter was run.
- Note if tests were skipped due to non-macOS environment, missing Swift, missing Homebrew tools, or connector-only execution.
