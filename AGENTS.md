# Converter

<!-- agent-harnesses:begin -->
> **One instruction file.** This is it. Codex, DeepSeek Harness, OpenCode,
> Qwen Code, Qoder and Zed read `AGENTS.md` directly, and Claude Code reads it
> through the committed `CLAUDE.md`, which contains nothing but `@AGENTS.md`.
> **Edit only this file** — do not add a second set of instructions anywhere.
>
> Do **not** add `.rules`, `.cursorrules`, `.windsurfrules`, `.clinerules`,
> `.github/copilot-instructions.md` or `AGENT.md`. Zed takes the *first match*
> from that list, **ahead of `AGENTS.md`**, so any one of them silently
> replaces this file for every Zed user.
<!-- agent-harnesses:end -->

A Swift CLI that turns one song and one image into a complete, verified upload set
for macOS Apple Silicon. Every output is verified before it is published — a wrong
size, a wrong codec, silent audio or drifted loudness fails the run instead of
producing a bad file. It is a single executable (the `converter` product of the
SwiftPM package under `Sources/`) with a vendored libbw64 and an in-process BW64
bridge, driven by `config.txt` and an `Output/` working directory. It is at stable
release `v1.0`, and it is for someone preparing a release-grade media set from
source files — not for library consumers.

## Layout

- `Sources/` — the SwiftPM package: `Package.swift`, `converter/` (the CLI and its
  pipelines), `Tests/converterTests/`, `BW64Bridge/` (the C++ bridge),
  `ThirdParty/libbw64/` (vendored libbw64 0.10.0, Apache-2.0).
- `Output/` — **both the input and the output directory**; discovery is
  non-recursive and it is meant to be cleared between runs. Only `.gitkeep` is
  tracked.
- `config.txt` — quality, render, loudness and profile settings.
  `album.example.txt` is the template for the git-ignored `album.txt`.
- `converter` — a committed prebuilt Apple Silicon binary at the repository root.
- `docs/` — `FORMATS.md`, `KNOWN_GOOD_VERSIONS.md`, `RELEASE_CHECKLIST.md`,
  `BINARY_PROVENANCE.md`, `converter.sha256`.
- `scripts/` — the local gates. `AUDIT/` — the audit ledger and its Python tooling.

## Build and test

Every SwiftPM command needs `--package-path Sources`, because the package lives
there rather than at the root.

```bash
swift build --package-path Sources -c release
cp "$(swift build --package-path Sources -c release --show-bin-path)/converter" ./converter && chmod +x ./converter

swift test --package-path Sources
swift test --package-path Sources --filter ConverterTests.<testName>
```

The suite performs **real media processing**: 278 tests, roughly 11 minutes. Plan
for it rather than assuming it is fast.

## Run

```bash
./converter -doctor     # verify toolchain, encoders and filters (brew install ffmpeg imagemagick)
./converter -full
./converter -album
./converter -short
./converter -matrix
./converter -help
```

## Identity

**There is no version constant in the Swift sources and no `--version` flag.** The
release identity lives in `CHANGELOG.md` (`## [1.0] - 2026-09-16`), mirrored by the
git tag `v1.0` and by the title of `docs/RELEASE_CHECKLIST.md`. The committed
binary is pinned by **hash, not version**: `docs/converter.sha256`, with the source
commit, toolchain and build command recorded in `docs/BINARY_PROVENANCE.md`.

## Gates

- `build-and-test` (`.github/workflows/ci.yml`, `xcode-27`):
  `shasum -a 256 -c docs/converter.sha256`; a `swift --version | grep -q 'Swift
  version 6.4'` assertion; `scripts/lint-budget.sh`; a debug build with
  `-warnings-as-errors`; a release build with `-warnings-as-errors -Xcc -Wall
  -Xcc -Wextra -Xcc -Werror`; `swift test --package-path Sources`.
- `static-analysis`: `scripts/check-format.sh`, `scripts/lint-budget.sh`,
  `scripts/check-python.sh`, `gitleaks git --config .gitleaks.toml`, `semgrep`
  (`p/swift`, `p/c`, `p/security-audit`), `cppcheck --enable=all
  --check-level=exhaustive`, and `clang-tidy` requiring **zero** first-party
  findings.
- Local: run `scripts/check-format.sh --write` before pushing. `.githooks/pre-push`
  is opt-in via `git config core.hooksPath .githooks`, and refuses to push a tree
  with uncommitted tracked changes.

## Traps

- **The committed `converter` binary is hash-gated.** CI runs
  `shasum -a 256 -c docs/converter.sha256` on every push and pull request, so
  regenerating the binary without updating `docs/converter.sha256` **and**
  `docs/BINARY_PROVENANCE.md` fails the build.
- **`swift format lint` exits 0 even when it reports differences** on this
  toolchain. `scripts/check-format.sh` treats *any* output as failure. Fix with
  `scripts/check-format.sh --write`.
- `scripts/lint-budget.sh` is a ratchet against `scripts/lint-budget.json`
  (`swiftlint` 0.65.1, 151 total, 21 error-level). Never raise the budget silently;
  a `swiftlint` version change is reported but does not fail.
- **Swift is deliberately disabled in this repository's CodeQL default setup**,
  because the autobuild runner ships Swift 6.3.3, below the package's 6.4 floor
  (`Sources/Package.swift` comment; tracked as #0160 with a re-check date).
- `CONVERTER_AUTO_INSTALL_DEPS` is **off by default**. Setting it to `1` opts into
  `brew install` and — if Homebrew is absent — into downloading and executing
  Homebrew's installer (`curl … | bash`).
- macOS only, Apple Silicon: `.macOS(.v15)`, and the committed binary is Mach-O
  thin `arm64`, ad-hoc/linker-signed and **not notarized**, so Gatekeeper
  quarantines it.
- `Output/` is input *and* output, and discovery is non-recursive. Run-scoped temps
  and fail-closed publishing mean a failed run leaves the destination untouched
  rather than half-written.
- `album.txt` is git-ignored; copy `album.example.txt` to create it for
  `-wavtoalbum` / `-mp3toalbum`.

<!-- release-rules:begin -->
## Releasing

**Read [`RELEASE.md`](RELEASE.md) before cutting a release.** It carries the
generic rules every Pummelchen repository follows, plus this repository's own
section. Do not improvise a release.

The non-negotiables:

- **Apple Silicon only** — build native `arm64` (M1–M6). Never `--arch x86_64`,
  never `ARCHS=arm64 x86_64`, and never `lipo -create`, which is how a universal
  binary gets made.
- **Assert it** — `lipo -archs <binary>` must report exactly `arm64`. A build that
  silently produced a fat binary is a release defect, not a build option.
- **Every release carries the artifacts.** A tag alone is not a release.
- **Identity is single-sourced and enforced** — never bump one declaration of the
  version or build number on its own; the build or CI must fail on a mismatch.
- **Dry run first**; publish only on an explicit flag.
- **Never fetch a model, dataset or dependency to make a gate pass.** A check that
  cannot run is reported *not checked*, and the release notes must name it.
<!-- release-rules:end -->
