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
# Architecture

## High-level architecture

`converter` is a local macOS CLI for media production. It coordinates external media tools and project-specific validation around a Swift runtime core.

```text
User CLI invocation
  -> Main.swift
  -> CLIOptions / DependencyBootstrapper / ProjectConfig
  -> ConverterTool
  -> Actions.swift workflow
  -> ImagePipeline / AudioPipeline / VideoPipeline
  -> ValidationPipeline + ffprobe/magick/ffmpeg probes
  -> Output/ deliverables
```

Evidence:
- `Sources/converter/Main.swift`
- `Sources/converter/CLI.swift`
- `Sources/converter/DependencyBootstrap.swift`
- `Sources/converter/Config.swift`
- `Sources/converter/Actions.swift`

## Runtime architecture

### Startup

1. `Main.swift` computes current directory, executable path, `CONVERTER_ROOT`, and `CONVERTER_NAME`.
2. It enriches `PATH` using common Homebrew and system directories.
3. It parses CLI arguments with `CLIOptions.parse`.
4. It calls `DependencyBootstrapper.ensureRuntimeDependencies` for operational actions.
5. It loads `ProjectConfig` from `config.txt`, environment, and CLI profile overrides.
6. It creates `ProcessRunner` and `ConverterTool`.
7. It calls `initializeForExecution()` and then executes the selected action.

Evidence:
- `Sources/converter/Main.swift`
- `Sources/converter/CLI.swift`
- `Sources/converter/DependencyBootstrap.swift`
- `Sources/converter/Config.swift`

### Runtime state and scheduling

`ConverterTool` owns:

- parsed CLI options;
- loaded project config;
- logger and process runner;
- file manager;
- temp-file registry;
- probe/QC cache;
- scheduler profile and async semaphores for global/image/audio/video work;
- a run token used for hidden temp-file names.

The scheduler is conservative because `ffmpeg` and `magick` use their own internal threading.

Evidence:
- `Sources/converter/PipelineCore.swift`
- `Sources/converter/Support.swift`

### External process boundary

All command execution goes through `ProcessRunner`, which resolves executables using the enriched path, runs `Process` with array arguments, captures stdout/stderr, checks exit codes, and can run producer/consumer pipelines.

Evidence:
- `Sources/converter/ProcessRunner.swift`

## Primary flows

### Help/list/matrix flow

- No-argument CLI defaults to `.help`.
- `help`, `list`, and `matrix` skip runtime dependency bootstrap.
- `-matrix` returns a static conversion matrix from `CLI.swift`.

Evidence:
- `Sources/converter/CLI.swift`
- `Sources/converter/DependencyBootstrap.swift`
- `Sources/Tests/converterTests/converterTests.swift`

### Full production flow

1. `stepFull()` resolves exactly one source audio file from `.flac`, `.wav`, or `.mp3`, excluding external archival companions.
2. Image and audio preparations run concurrently.
3. Image flow accepts direct `Horizontal_8K.png` and optional `Vertical_8K.png`, or derives image assets from one source image.
4. Audio flow normalizes/prepares internal WAV and delivery M4A/MP3, and generates external RF64/BW64 archival deliverables.
5. Main MP4 is rendered from M4A plus the main image.
6. Short MP4 is rendered directly from `Vertical_8K.png` when present, otherwise shortened from the main MP4.
7. Transients are cleaned.

Evidence:
- `Sources/converter/Actions.swift`
- `Sources/converter/ImagePipeline.swift`
- `Sources/converter/AudioPipeline.swift`
- `Sources/converter/VideoPipeline.swift`
- `README.md`

### Album flow

`-album` builds an album source from multiple `.mp3`, `.wav`, or `.flac` tracks, then runs the same full production flow on that album audio.

Evidence:
- `README.md`
- `Sources/converter/Actions.swift`
- `Sources/Tests/converterTests/converterTests.swift`

### Image flow

Image functions perform preflight checks, use ImageMagick for conversion/resizing/colorspace work, verify dimensions/format/size constraints, and publish through hidden temp files.

Major outputs include:

- 8K/4K PNG variants;
- square NFT 8K/3K/2K PNGs;
- 3K and 8K JPG exports with target byte limits;
- JPG/JPEG to PNG conversion;
- PNG to JPG conversion.

Evidence:
- `Sources/converter/ImagePipeline.swift`
- `config.txt`

### Audio flow

Audio functions stage through an internal project-standard WAV for delivery encoding. The documented internal WAV standard is 32-bit float, 192 kHz, stereo RF64 WAV. Delivery formats include ALAC M4A/MP4 audio and 320 kbps MP3.

Audio features include:

- format conversion among WAV/FLAC/MP3/M4A where supported;
- static loudness gain normalization;
- loudness scans;
- bass adjustment;
- fade/fadecut/fadeout;
- silence/noise padding;
- CRC32 hash renaming;
- RF64/BW64 archival companions.

Evidence:
- `README.md`
- `Sources/converter/AudioPipeline.swift`
- `Sources/converter/ValidationPipeline.swift`
- `config.txt`

### Video flow

Video functions render:

- main MP4 from image + M4A, using configured main encoder ladder;
- short MP4, capped to 58 seconds, using configured short encoder ladder;
- portrait-image short renders when a vertical 8K PNG is available.

Video validation checks dimensions, codecs, pixel format, color metadata, ALAC audio, duration, and source loudness preservation.

Evidence:
- `Sources/converter/VideoPipeline.swift`
- `config.txt`
- `README.md`

## Trust boundaries

| Boundary | Files | Risk |
|---|---|---|
| CLI arguments/environment | `CLI.swift`, `Main.swift`, `Config.swift` | User-controlled paths and config values affect runtime behavior. |
| External commands | `ProcessRunner.swift`, pipeline files | External tool behavior, PATH resolution, media parser surface. |
| Homebrew install path | `DependencyBootstrap.swift` | Network/install side effects. |
| Runtime files | `Output/`, `PipelineCore.swift` | Large/private media, overwrite behavior, hidden temp cleanup. |
| Vendored native bridge | `Sources/BW64Bridge/`, `Sources/ThirdParty/libbw64/` | C++/native code and audio container correctness. |

## Architecture constraints to preserve

- Keep direct-child path restrictions for explicit input/output paths.
- Keep hidden run-scoped temp files and verify-before-publish behavior.
- Preserve array-based process arguments unless a shell is strictly required.
- Keep full-run image/audio work separable and concurrency bounded.
- Keep config schema changes synchronized between `Config.swift`, `config.txt`, README/docs, and tests.
- Keep no-argument behavior as help unless intentionally changing CLI contract and tests.

## Unknowns

- CI/CD architecture was not found at checked common workflow paths.
- Exact local tool versions are not pinned.
- Complete file inventory was not available through direct clone in this environment; the map is based on repository files fetched through GitHub source APIs and checked known paths.
