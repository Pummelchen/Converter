<!--
AI onboarding file.
Mode: refresh
Indexed commit: c75929f41d4c17970b367c43051de3f6cb09af90
Last generated: 2026-08-04T15:07:37Z
Generator: generic high-end AI coding agent
Purpose: Help future AI sessions understand this repository quickly.
Audience: Any high-capability AI coding agent, regardless of vendor or model family.
Human edits are allowed. Future refreshes should preserve valid human edits.
-->
# AI Index: Converter

## Snapshot

| Field | Value |
|---|---|
| Repository | `Pummelchen/Converter` |
| Purpose | Swift-based media converter and YouTube studio production pipeline for macOS Apple Silicon. |
| Indexed commit | `c75929f41d4c17970b367c43051de3f6cb09af90` |
| Last generated | `2026-08-04T15:07:37Z` |
| Operation mode | `refresh` |
| Primary language | Swift 6 package, with a C++17 bridge target for BW64 support |
| Runtime target | macOS 14+ |

Evidence:
- `README.md`
- `Sources/Package.swift`
- `Sources/converter/Main.swift`
- `Sources/BW64Bridge/`
- `Sources/ThirdParty/libbw64/`

## Verified facts

- The build unit is a Swift Package located at `Sources/`, not at the repository root. Build and test commands must use `--package-path Sources`.
- The package product is the executable `converter`; the executable target is `Sources/converter` and depends on the `BW64Bridge` target.
- The CLI entrypoint is `Sources/converter/Main.swift`, which parses command-line options, bootstraps runtime dependencies, loads configuration, creates `ConverterTool`, initializes execution, and dispatches work.
- Runtime media processing shells out to `ffmpeg`, `ffprobe`, and ImageMagick `magick`; `awk` and `sed` are required macOS system commands.
- Operational commands may auto-install missing Homebrew formulae unless `CONVERTER_AUTO_INSTALL_DEPS=0` is set.
- `Output/` is the default working directory for source inputs and generated outputs; discovery is non-recursive and skips hidden files.
- The prebuilt root `converter` binary is a checked-in release artifact; do not edit it for documentation-only work.
- Short-video actions: `-short` renders a portrait short MP4 from exactly 1 image plus exactly 1 audio-only file; `-nfttoshort` (renamed from `-mp3toshort`, which is now rejected with an actionable error) accepts any single audio-only file supported by ffmpeg and prefers `Vertical_8K.png`, then an existing `*_NFT8K.png`, then derives NFT artwork from a landscape `*_8K.png` or source image.
- Publishing replaces existing outputs via a temporary backup instead of deleting the destination first, and startup removes orphaned `.converter-tmp.*` files whose owning process no longer exists.
- The test suite has 122 XCTest tests (45 unit, 77 integration) and passes on macOS Apple Silicon with Swift 6.3.3 and installed `ffmpeg`/`ffprobe`/`magick`.

Evidence:
- `README.md`
- `Sources/Package.swift`
- `Sources/converter/Main.swift`
- `Sources/converter/DependencyBootstrap.swift`
- `Sources/converter/PipelineCore.swift`
- `.gitignore`

## Inferences

- This repository is optimized for a single-user/local macOS production workflow rather than a server, web API, or distributed service.
- There is no database, migration layer, HTTP API, background worker system, Docker setup, or GitHub Actions workflow. Verified by full clone: no `.github/` directory exists.

Evidence:
- `README.md`
- `Sources/Package.swift`
- verified via `git ls-files` and `ls .github` in a full clone: no `.github/` directory exists

## Architecture summary

`converter` is a command-line media pipeline. Startup flow is:

1. `Main.swift` enriches environment paths and parses CLI arguments.
2. `DependencyBootstrapper` ensures required external tools exist, optionally using Homebrew for `ffmpeg` and `imagemagick`.
3. `ProjectConfig` loads `config.txt`, overlays environment variables and CLI profile choices, then validates settings.
4. `ConverterTool` coordinates source discovery, temporary files, process execution, probe/QC caching, and bounded concurrency.
5. Action-specific methods in `Actions.swift` dispatch image, audio, video, album, short, hashing, loudness, fade, silence, and noise workflows.
6. Specialized pipeline files perform validation, media transforms, delivery rendering, and output verification.

Evidence:
- `Sources/converter/Main.swift`
- `Sources/converter/DependencyBootstrap.swift`
- `Sources/converter/Config.swift`
- `Sources/converter/PipelineCore.swift`
- `Sources/converter/Actions.swift`
- `Sources/converter/ValidationPipeline.swift`
- `Sources/converter/ImagePipeline.swift`
- `Sources/converter/AudioPipeline.swift`
- `Sources/converter/VideoPipeline.swift`

## Directory map

| Path | Responsibility | Notes |
|---|---|---|
| `README.md` | Human-facing usage, build, runtime dependency, and media contract docs | Updated with AI onboarding entry block. |
| `Sources/Package.swift` | Swift Package manifest | Swift tools 6.3.3, Swift language mode 6, macOS 14, executable product `converter`, test target, release-only `-cross-module-optimization`. |
| `Sources/converter/` | Main Swift executable target | CLI parsing, config, runtime support, media pipelines, action dispatch. |
| `Sources/converter/Diagnostics.swift` | ffmpeg encoder/filter capability probing | Encoder-ladder availability checks used by `-doctor` and video rendering. |
| `Sources/converter/LosslessAudioPipeline.swift` | Internal WAV staging and lossless/archive encodes | RF64 internal WAV argument construction, archival FLAC/WAV variants. |
| `Sources/converter/QualityReporting.swift` | Audio QC policy and metrics types | `AudioQCPolicy`, `AudioQCMetrics`, `AudioQCResult` used by validation. |
| `Sources/BW64Bridge/` | C++ bridge target declared by the package | Used by Swift code via `import BW64Bridge`. |
| `Sources/ThirdParty/libbw64/` | Bundled third-party BW64 code referenced by package header search path | Treat as vendored/low-edit unless specifically changing BW64 support. |
| `Sources/Tests/converterTests/` | XCTest unit and integration tests | 122 tests: CLI/config/tooling unit tests, media pipeline integration coverage, `IntegrationTestSupport.swift` workspace helpers. |
| `Output/` | Runtime input/output working directory | Contents ignored except `.gitkeep`; clean manually between runs. |
| `config.txt` | Runtime quality/profile/pipeline policy | Can be overridden by environment and selected profile. |
| `album.txt` | Album ordering input | Referenced by README for album actions; exact parser details should be checked before editing album behavior. |
| `converter` | Prebuilt macOS Apple Silicon executable | Generated binary artifact, not source. |

## Main entrypoints

| Entrypoint | Type | Purpose |
|---|---|---|
| `Sources/converter/Main.swift` | Swift `@main` | CLI startup and top-level error handling. |
| `CLIOptions.parse(...)` in `Sources/converter/CLI.swift` | CLI parser | Maps flags such as `-full`, `-album`, `-loudness`, `-short`, `-nfttoshort`, `-matrix`, `-doctor` to actions; removed flags (e.g. `-mp3toshort`, `-jpegtopng`) throw actionable errors. |
| `ConverterTool.initializeForExecution()` in `Sources/converter/PipelineCore.swift` | Runtime initialization | Ensures source/output dirs and executable dependencies for operational actions. |
| `stepFull()` / `stepAlbum()` in `Sources/converter/Actions.swift` | Pipeline workflows | Full production and album production orchestration. |
| `ProcessRunner` in `Sources/converter/ProcessRunner.swift` | External process boundary | Runs commands and pipelines, captures stdout/stderr, enforces allowed exit codes. |

## Commands

| Task | Command | Status |
|---|---|---|
| Build release | `swift build --package-path Sources -c release` | verified from README and package layout |
| Copy release binary | `cp Sources/.build/arm64-apple-macosx/release/converter ./converter && chmod +x ./converter` | verified from README |
| Run tests | `swift test --package-path Sources` | verified from README and package manifest |
| Help | `./converter -help` or `./converter` | verified from README/CLI tests; no args show help |
| Full production run | `./converter -full` or `./converter -run` | verified from README and CLI parser |
| Dependency check | `./converter -doctor` | verified from README/CLI parser |
| List actions | `./converter -list` | verified from CLI parser |
| Conversion matrix | `./converter -matrix` | verified from README/CLI parser |
| Portrait short from image+audio | `./converter -short` | verified from CLI parser/help text |
| NFT short render | `./converter -nfttoshort` | verified from CLI parser/help text |
| Disable auto-install | `CONVERTER_AUTO_INSTALL_DEPS=0 ./converter -doctor` | verified from dependency bootstrap behavior |

See [`.ai/COMMANDS.md`](./.ai/COMMANDS.md) for command details and validation notes.

## Important conventions

- Use `swift build --package-path Sources` and `swift test --package-path Sources`; root-level SwiftPM commands are likely wrong.
- Prefer changing Swift source under `Sources/converter/`; avoid editing the root binary `converter` unless intentionally replacing a release artifact after a build.
- Treat `Output/` as runtime data. Do not commit generated media files there.
- Add or change CLI actions in `CLI.swift`, dispatch/workflow code in `Actions.swift`, and tests under `Sources/Tests/converterTests/`.
- Keep media validation explicit. The code generally preflights inputs, writes hidden run-scoped temp files, verifies outputs, then atomically publishes.
- Configuration keys must be added to `ProjectConfig.supportedKeys`, applied in `ProjectConfig.apply`, validated, and documented in `config.txt` where relevant.

## Security-sensitive areas

| Area | Why it matters | Agent rule |
|---|---|---|
| `DependencyBootstrap.swift` | Can install Homebrew and formulae non-interactively, including networked installer behavior | Do not broaden network/install behavior without explicit human approval. |
| `ProcessRunner.swift` | Executes external commands using user-controlled file paths and config-derived arguments | Preserve array-based arguments; avoid shell string interpolation. |
| `PipelineCore.swift` path checks | Enforces direct-child paths for inputs/outputs and uses hidden temp files | Do not weaken path containment or hidden-temp naming. |
| `Output/` media inputs | User media may be large, private, or destructive to overwrite | Do not add docs or scripts that upload or expose media. |
| `config.txt` | Controls codecs, dimensions, encoders, quality, and QC thresholds | Validate config changes with tests and current code. |

See [`.ai/SECURITY.md`](./.ai/SECURITY.md).

## Generated files / do-not-edit zones

- `converter`: checked-in binary artifact; regenerate via documented build command if intentionally updating release output.
- `Sources/.build/`: ignored Swift build directory.
- `Output/*`: ignored runtime media output/input area except `Output/.gitkeep`.
- Hidden temp files matching `.converter-tmp.*`: runtime scratch files created by the tool.
- `Sources/ThirdParty/libbw64/`: vendored code; edit only when intentionally changing the bundled third-party dependency.

Evidence:
- `.gitignore`
- `Sources/converter/PipelineCore.swift`
- `Sources/Package.swift`

## Common task map

| Task | Start here | Then inspect |
|---|---|---|
| Add or change a CLI flag/action | `Sources/converter/CLI.swift` | `Sources/converter/Actions.swift`, tests in `Sources/Tests/converterTests/` |
| Change full production flow | `Sources/converter/Actions.swift` | image/audio/video pipeline files, README full-run contract, integration tests |
| Change image conversion outputs | `Sources/converter/ImagePipeline.swift` | `Config.swift`, `config.txt`, tests |
| Change audio standards/QC | `Sources/converter/AudioPipeline.swift` and `ValidationPipeline.swift` | `Config.swift`, `config.txt`, README audio standards, tests |
| Change video rendering | `Sources/converter/VideoPipeline.swift` | `Config.swift`, `config.txt`, README short/full video behavior, tests |
| Change short-video behavior | `Sources/converter/Actions.swift` (`resolveShortAudio`, `resolveShortRenderImage`, `stepShort`, `stepNFTToShort`) | `VideoPipeline.swift`, `ImagePipeline.swift`, tests |
| Change config schema | `Sources/converter/Config.swift` | `config.txt`, README profiles/standards, tests |
| Change dependency behavior | `Sources/converter/DependencyBootstrap.swift` | `ProcessRunner.swift`, README runtime dependencies, tests |
| Change process execution | `Sources/converter/ProcessRunner.swift` | all pipeline command construction sites, security notes |
| Add tests | `Sources/Tests/converterTests/` | `Sources/Package.swift` test target |
| Update release binary | `swift build --package-path Sources -c release` | copy resulting binary to `./converter`; document whether this was intentional |

## Recommended first-read order

1. `AI_INDEX.md`
2. `AGENTS.md`
3. `.ai/START_HERE.md`
4. `README.md`
5. `Sources/Package.swift`
6. `Sources/converter/Main.swift`
7. `Sources/converter/CLI.swift`
8. `Sources/converter/Actions.swift`
9. `Sources/converter/Config.swift`
10. Relevant pipeline file for the task
11. `Sources/Tests/converterTests/`
12. `.ai/KNOWN_UNKNOWNS.md`

## Local AI files

- [`AGENTS.md`](./AGENTS.md) — generic agent operating rules.
- [`.ai/START_HERE.md`](./.ai/START_HERE.md) — pasteable first-session prompt.
- [`.ai/PROJECT_MAP.md`](./.ai/PROJECT_MAP.md) — repository map and source references.
- [`.ai/ARCHITECTURE.md`](./.ai/ARCHITECTURE.md) — runtime architecture and flows.
- [`.ai/COMPONENTS.md`](./.ai/COMPONENTS.md) — component cards.
- [`.ai/COMMANDS.md`](./.ai/COMMANDS.md) — exact commands and validation notes.
- [`.ai/TESTING.md`](./.ai/TESTING.md) — test framework and expectations.
- [`.ai/SECURITY.md`](./.ai/SECURITY.md) — security-sensitive behavior.
- [`.ai/PLAYBOOKS.md`](./.ai/PLAYBOOKS.md) — common change workflows.
- [`.ai/KNOWN_UNKNOWNS.md`](./.ai/KNOWN_UNKNOWNS.md) — ambiguity and missing facts.
- [`.ai/CHANGELOG.md`](./.ai/CHANGELOG.md) — onboarding generation history.
- [`.ai/MANIFEST.json`](./.ai/MANIFEST.json) — machine-readable metadata.

## Unknowns and conflicts

- Resolved: CI/CD absence verified by full clone — no `.github/` directory exists.
- Resolved: full file inventory is now known from a direct clone (`git ls-files`).
- Resolved: the bootstrap-era docs missed `Sources/converter/Diagnostics.swift`, `LosslessAudioPipeline.swift`, `QualityReporting.swift`, and `Sources/Tests/converterTests/IntegrationTestSupport.swift`, which already existed at the previous indexed commit; they are now documented.
- Unknown: local macOS/Homebrew/FFmpeg/ImageMagick versions are not pinned in the repository.
- No current docs/code conflict remains after this refresh.

See [`.ai/KNOWN_UNKNOWNS.md`](./.ai/KNOWN_UNKNOWNS.md).
