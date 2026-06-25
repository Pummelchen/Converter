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
# Components

## `converter` executable target

| Field | Details |
|---|---|
| Responsibility | User-facing CLI and all media workflow orchestration. |
| Key files | `Main.swift`, `CLI.swift`, `Actions.swift`, `PipelineCore.swift`, pipeline files. |
| Public interface | `./converter` CLI flags and environment/config inputs. |
| Internal dependencies | `ProjectConfig`, `ProcessRunner`, `DependencyBootstrapper`, `BW64Bridge`. |
| External dependencies | Swift runtime, `ffmpeg`, `ffprobe`, `magick`, `awk`, `sed`, Homebrew for optional install. |
| Tests | `Sources/Tests/converterTests/`. |
| Risks | Shelling out to media tools, large/private media, config-driven codec/quality behavior. |

## CLI and options

| Field | Details |
|---|---|
| Responsibility | Parse user arguments, select `Action`, validate action-specific arguments, generate help/list/matrix text. |
| Key file | `Sources/converter/CLI.swift` |
| Public interface | Flags such as `-full`, `-run`, `-album`, `-doctor`, `-matrix`, `-loudness`, `-noise`, `-silence`, `-mp3toshort`. |
| Invariants | No arguments mean help; removed flags throw explicit errors; `--recursive` is rejected. |
| Tests | `converterTests.swift` includes no-arg help and help-text assertions. |
| Risks | CLI contract is documented in README and tests; update all three together. |

## Configuration

| Field | Details |
|---|---|
| Responsibility | Centralize project profile/defaults and validate runtime settings. |
| Key files | `Sources/converter/Config.swift`, `config.txt` |
| Public interface | `config.txt`, environment variables matching supported keys, `--profile`, `--sharpness`. |
| Invariants | Supported keys must be listed, applied, and validated. Built-in profiles are `youtube_master`, `youtube_short`, `archive`, `fast_preview`. |
| Tests | Config-related tests should be added/updated when schema changes. |
| Risks | Config changes affect codecs, output dimensions, QC thresholds, and encoder ladders. |

## Dependency bootstrap

| Field | Details |
|---|---|
| Responsibility | Locate required commands and optionally install missing Homebrew dependencies. |
| Key file | `Sources/converter/DependencyBootstrap.swift` |
| Public interface | `CONVERTER_AUTO_INSTALL_DEPS`; operational command startup. |
| Invariants | `help`, `list`, and `matrix` skip runtime dependency bootstrap. |
| Tests | `converterTests.swift` asserts dependency manifest and path enrichment. |
| Risks | Non-interactive install and network side effects. |

## Process runner

| Field | Details |
|---|---|
| Responsibility | Resolve and run external commands, capture output, enforce exit codes, run pipelines. |
| Key file | `Sources/converter/ProcessRunner.swift` |
| Public interface | Internal `run` and `runPipeline` methods. |
| Invariants | Use array arguments; do not construct shell command strings for normal media operations. |
| Risks | Command injection, PATH confusion, excessive logs, external tool variance. |

## Pipeline core

| Field | Details |
|---|---|
| Responsibility | Shared runtime state, temp files, path containment, probe caches, scheduler semaphores, media probe helpers. |
| Key file | `Sources/converter/PipelineCore.swift` |
| Invariants | Hidden temp files use run-scoped names; explicit paths must be direct children of configured directories; discovery is non-recursive. |
| Risks | Weakening temp/path behavior can overwrite or process unintended files. |

## Image pipeline

| Field | Details |
|---|---|
| Responsibility | JPG/PNG conversion, 8K/4K derivation, NFT/square PNGs, size-targeted JPG exports. |
| Key file | `Sources/converter/ImagePipeline.swift` |
| External dependencies | ImageMagick `magick`. |
| Invariants | Verify dimensions/format/byte targets before publishing. |
| Risks | Output dimensions and byte targets are config-driven and user-visible. |

## Audio pipeline

| Field | Details |
|---|---|
| Responsibility | Audio format conversion, internal WAV staging, loudness, bass, fade, silence/noise, archives, hashing. |
| Key file | `Sources/converter/AudioPipeline.swift` |
| External dependencies | `ffmpeg`, `ffprobe`; BW64 bridge for BW64-related support. |
| Invariants | Preserve source loudness for normal conversions where documented; use project-standard internal WAV. |
| Risks | Loudness/QC mistakes can damage deliverables; avoid hidden remastering unless intended. |

## Video pipeline

| Field | Details |
|---|---|
| Responsibility | Main MP4 and short MP4 rendering with encoder fallback and validation. |
| Key file | `Sources/converter/VideoPipeline.swift` |
| External dependencies | `ffmpeg`, `ffprobe`, configured encoders. |
| Invariants | Shorts are hard-capped at 58 seconds; verify codec, dimensions, color metadata, ALAC audio, duration, and loudness preservation. |
| Risks | Encoder availability differs by machine; fallback ladders matter. |

## Validation pipeline

| Field | Details |
|---|---|
| Responsibility | Input preflight, media identity, audio QC, output verification, duration/loudness equivalence. |
| Key file | `Sources/converter/ValidationPipeline.swift` |
| External dependencies | `ffmpeg`, `ffprobe`, `magick` depending on media type. |
| Invariants | Validate before reuse/publish. |
| Risks | Removing validation can produce invalid or misleading media deliverables. |

## Tests

| Field | Details |
|---|---|
| Responsibility | XCTest validation for CLI, dependency manifest, and media pipeline behavior. |
| Key paths | `Sources/Tests/converterTests/converterTests.swift`, `PipelineIntegrationTests.swift` |
| Run command | `swift test --package-path Sources` |
| Risks | Integration tests may require local media tooling and macOS-compatible environment. |

## BW64 bridge and vendored code

| Field | Details |
|---|---|
| Responsibility | In-process BW64 support through C++ bridge target and bundled libbw64 headers/source. |
| Key paths | `Sources/BW64Bridge/`, `Sources/ThirdParty/libbw64/` |
| Evidence | `Sources/Package.swift`, Swift imports of `BW64Bridge`. |
| Risks | Native/vendor changes need careful build and media verification. |
