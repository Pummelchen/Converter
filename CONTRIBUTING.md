# Contributing to Converter

Converter is a Swift CLI media production pipeline for macOS Apple Silicon. Contributions are welcome; please read this guide before opening a pull request.

## Getting started

```bash
git clone https://github.com/Pummelchen/Converter.git
cd Converter
brew install ffmpeg imagemagick        # runtime media tools
swift build --package-path Sources     # build
swift test --package-path Sources      # run all tests (263 tests, ~11 min)
```

Requires Swift tools 6.4+ (Xcode 27, Swift language mode 6) and macOS 15+, matching the `.macOS(.v15)` platform in `Sources/Package.swift`. See the [wiki](https://github.com/Pummelchen/Converter/wiki) for command reference and configuration details.

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
swift test --package-path Sources --filter ConverterTests.<testName>  # focused test
```

Integration tests perform real media processing with `ffmpeg`/`ffprobe`/`magick` in isolated temporary workspaces; they never touch your `Output/` directory.

Dependency auto-install is disabled in tests; for manual dependency checks without install side effects:

```bash
CONVERTER_AUTO_INSTALL_DEPS=0 ./converter -doctor
```

## Language level

The package declares Swift language mode 6 and additionally opts into four upcoming-feature
flags (`ExistentialAny`, `MemberImportVisibility`, `InferIsolatedConformances`,
`ImmutableWeakCaptures`) in `Sources/Package.swift`. They build clean today and act as
ratchets — new code cannot reintroduce bare existentials or the other patterns they forbid.
`Sources/Package.swift` documents which upcoming features were deliberately declined and why.

Release builds stay CPU-generic so the binary runs on every Apple Silicon Mac. Do not add
`-mcpu=` targeting to the package; see `docs/KNOWN_GOOD_VERSIONS.md` for the measurements
behind that decision.

## Safety rules for changes

- Keep command execution through `ProcessRunner` with array arguments; do not build shell command strings.
- Preserve direct-child path containment for explicit input/output paths (no subfolder or absolute-path escapes).
- Preserve hidden run-scoped temp files, backup-based publishing, and verify-before-publish behavior.
- Do not weaken media validation/QC thresholds or loudness-preservation semantics without calling it out explicitly.
- Missing Homebrew formulae are installed **only** when `CONVERTER_AUTO_INSTALL_DEPS=1` is set
  (off by default; the Homebrew installer download is pinned and SHA-256 verified); do not broaden
  install/network behavior without review.

## Tests

- Use XCTest in `Sources/Tests/converterTests/`; `@testable import converter`.
- Unit tests go in `converterTests.swift`; media-processing tests in `PipelineIntegrationTests.swift` using the `IntegrationWorkspace` helpers from `IntegrationTestSupport.swift` (generated fixtures only — never private/user media).
- Config schema changes need tests for parsing, profile overlay, and invalid values.
- CLI changes need parser/help-text tests; removed flags must keep their actionable rejection errors.

## Lint gate

`scripts/lint-budget.sh` runs swiftlint over `Sources/converter` and `Sources/Tests` and compares
the result with `scripts/lint-budget.json` (currently 471 violations, 19 error-level). It fails when
violations grow and prints the per-rule delta. The structural rules (`file_length`,
`type_body_length`, `function_body_length`, `cyclomatic_complexity`) and the 120-character
`line_length` preference are accepted debt, recorded with their rationale in the `#0073` commit;
the budget is a ratchet, so lower it when violations are removed and never raise it silently. A
swiftlint version change is reported as a warning instead of a failure — re-record the budget with
`scripts/lint-budget.sh --write` after reviewing the delta.

## Committing

`.githooks/pre-push` refuses to push a branch with uncommitted tracked changes, which catches the
"one file was left out of a batch commit" mistake. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

The audit's batch helpers (`AUDIT/tools/commit_one.py`, `commit_task.py`) enforce the same rule at
commit time and refuse to commit when a tracked file is modified but unstaged; set
`AUDIT_ALLOW_DIRTY=1` only when that is deliberate.

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
shasum -a 256 converter
```

Update `docs/converter.sha256` and the record in `docs/BINARY_PROVENANCE.md` (size, source commit,
toolchain) in the same commit — CI verifies the checksum, so a replaced binary with a stale record
fails the build. State in the PR that the binary was regenerated and why.

## Licensing

Converter is released under the [MIT License](LICENSE). By submitting a pull request you agree
that your contribution is licensed under the same terms (inbound = outbound); there is no separate
contributor licence agreement to sign.

Third-party code keeps its own licence and attribution. `Sources/ThirdParty/libbw64/` is vendored
Apache-2.0 code by the EBU and stays verbatim apart from a recorded upstream update.

## Pull request expectations

- One focused change per PR; describe commands run and results (do not claim tests passed without running them).
- New behavior requires tests; bug fixes require a regression test where practical.
