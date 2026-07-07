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
# Project Map

## Repository shape

| Path | Type | Responsibility | Evidence |
|---|---|---|---|
| `README.md` | Markdown | Primary human docs for build, test, runtime dependencies, commands, media contracts | `README.md` |
| `Sources/Package.swift` | SwiftPM manifest | Defines executable product `converter`, target paths, macOS platform, test target, BW64 bridge | `Sources/Package.swift` |
| `Sources/converter/Main.swift` | Swift source | `@main` entrypoint and top-level startup flow | `Sources/converter/Main.swift` |
| `Sources/converter/CLI.swift` | Swift source | Action enum, argument parser, help/list/matrix text, argument validation | `Sources/converter/CLI.swift` |
| `Sources/converter/Config.swift` | Swift source | Defaults, supported config keys, profile overlays, environment/file overrides, validation | `Sources/converter/Config.swift`, `config.txt` |
| `Sources/converter/DependencyBootstrap.swift` | Swift source | Homebrew/system dependency detection and optional installation | `Sources/converter/DependencyBootstrap.swift` |
| `Sources/converter/ProcessRunner.swift` | Swift source | External process execution and pipeline capture | `Sources/converter/ProcessRunner.swift` |
| `Sources/converter/Support.swift` | Swift source | App error, logging, semaphores, scheduler, utilities, parsing specs | `Sources/converter/Support.swift` |
| `Sources/converter/PipelineCore.swift` | Swift source | Runtime state, temp files, probe/QC cache, path checks, ffprobe/magick probes | `Sources/converter/PipelineCore.swift` |
| `Sources/converter/Actions.swift` | Swift source | Action workflows: full, album, image batches, dispatch helpers | `Sources/converter/Actions.swift` |
| `Sources/converter/ValidationPipeline.swift` | Swift source | Media identity, preflight, output validation, loudness/QC checks | `Sources/converter/ValidationPipeline.swift` |
| `Sources/converter/ImagePipeline.swift` | Swift source | JPG/PNG conversion, AIPix images, NFT assets, sized JPEG outputs | `Sources/converter/ImagePipeline.swift` |
| `Sources/converter/AudioPipeline.swift` | Swift source | Audio conversions, loudness, fade, bass, noise/silence, archival variants | `Sources/converter/AudioPipeline.swift` |
| `Sources/converter/VideoPipeline.swift` | Swift source | Main MP4 rendering, short MP4 rendering, encoder fallback ladders | `Sources/converter/VideoPipeline.swift` |
| `Sources/BW64Bridge/` | C++ target path | Package target imported by Swift for BW64 writing | `Sources/Package.swift`, `PipelineCore.swift`, `ValidationPipeline.swift` |
| `Sources/ThirdParty/libbw64/` | vendored dependency path | Header search path for BW64 bridge target | `Sources/Package.swift` |
| `Sources/Tests/converterTests/` | XCTest target | Unit/integration tests for CLI, dependencies, config, pipelines | `Sources/Package.swift`, `Sources/Tests/converterTests/converterTests.swift` |
| `config.txt` | Runtime config | Project-wide audio/video/image/album defaults | `config.txt`, `Config.swift` |
| `Output/` | Runtime data dir | Default source/output directory; ignored except `.gitkeep` | `README.md`, `.gitignore` |
| `converter` | Binary artifact | Prebuilt macOS Apple Silicon executable | `README.md` |

## Package/module map

| Package target | Path | Kind | Dependencies |
|---|---|---|---|
| `converter` | `Sources/converter` | executable Swift target | `BW64Bridge`, Foundation, external tools at runtime |
| `BW64Bridge` | `Sources/BW64Bridge` | C++ target | header search path `../ThirdParty/libbw64`, C++17 |
| `converterTests` | `Sources/Tests/converterTests` | XCTest target | `converter` |

Evidence:
- `Sources/Package.swift`

## Entrypoints and dispatch

| Flow | Files | Notes |
|---|---|---|
| Process startup | `Main.swift` | Builds runtime environment, parses CLI, bootstraps deps, loads config, invokes `ConverterTool.execute()`. |
| CLI parsing | `CLI.swift` | Default action is help. `-full`/`-run` trigger full production. Removed flags throw explicit errors. |
| Full production | `Actions.swift` | Resolves exactly one source audio and image/direct PNG inputs, runs image/audio work, renders main video, renders or shortens short video. |
| Album production | `Actions.swift`, audio helpers | Builds a normalized RF64 album WAV, then reuses full production flow. |
| Image-only actions | `ImagePipeline.swift`, `Actions.swift` | PNG/JPG conversions and size-specific image deliverables. |
| Audio-only actions | `AudioPipeline.swift`, `Actions.swift` | Format conversion, hash rename, loudness, bass, fade, silence, noise. |
| Video actions | `VideoPipeline.swift`, `Actions.swift` | M4A+PNG to MP4, NFT/portrait PNG to short MP4, and MP4 to short MP4. |
| Validation | `ValidationPipeline.swift`, `PipelineCore.swift` | Uses `ffprobe`, `ffmpeg`, and `magick identify`; caches per-file probes. |

## Internal dependencies

```text
Main.swift
  -> CLIOptions.parse
  -> DependencyBootstrapper
  -> ProjectConfig.load
  -> ProcessRunner
  -> ConverterTool.initializeForExecution
  -> ConverterTool.execute / action steps

ConverterTool
  -> ProcessRunner for external commands
  -> ProjectConfig for settings
  -> ProbeCache for ffprobe/magick/audio QC reuse
  -> ImagePipeline / AudioPipeline / VideoPipeline / ValidationPipeline methods via extensions
  -> BW64Bridge for in-process BW64 support where imported
```

## External dependencies

| Dependency | How used | Source evidence |
|---|---|---|
| Swift 6.3.3 tools, Swift language mode 6 | Build/test package | `Sources/Package.swift` |
| macOS 14+ | Package platform | `Sources/Package.swift` |
| `ffmpeg` | Audio/video transforms and audio analysis | `README.md`, `DependencyBootstrap.swift`, pipeline files |
| `ffprobe` | Media metadata probing | `README.md`, `DependencyBootstrap.swift`, `PipelineCore.swift` |
| ImageMagick `magick` | Image conversion, dimensions, colorspace | `README.md`, `DependencyBootstrap.swift`, `ImagePipeline.swift`, `PipelineCore.swift` |
| `awk`, `sed` | Required macOS system commands | `README.md`, `DependencyBootstrap.swift` |
| Homebrew | Optional auto-install provider | `DependencyBootstrap.swift`, `README.md` |
| `libbw64` | Vendored BW64 support through C++ target | `Sources/Package.swift` |

## Important config files

| File | Purpose | Notes |
|---|---|---|
| `config.txt` | Defaults for codecs, dimensions, QC thresholds, profile | Update with `Config.swift` schema changes. |
| `.gitignore` | Excludes build output and runtime media | `Output/*` ignored except `.gitkeep`; `Sources/.build/` ignored. |
| `Sources/Package.swift` | Build/test/source target shape | Root package commands without `--package-path Sources` are likely wrong. |

## Existing docs and templates checked

| Path | Result |
|---|---|
| `README.md` | present |
| `CONTRIBUTING.md` | not found at checked path |
| `.github/workflows/ci.yml` | not found at checked path |
| `.github/workflows/swift.yml` | not found at checked path |
| `docs/architecture.md` | not found at checked path |
| `AI_INDEX.md`, `AGENTS.md`, `.ai/MANIFEST.json` | not found before bootstrap |
| Common model-specific AI instruction paths | not found at checked paths |

## Monorepo status

`inferred`: This does not appear to be a monorepo. The repository contains one Swift Package under `Sources/` with one executable target, one bridge target, and one test target.
