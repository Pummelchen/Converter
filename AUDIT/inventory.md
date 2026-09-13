# Audit inventory (§2 scope discovery)

Snapshot taken 2026-09-13 at commit `4bb136a` (branch `audit/2026-09-13`).

## 2.0 Reality check against the brief

The brief describes a monorepo of 20+ interdependent projects. This repository is **one SwiftPM
package with three targets plus one vendored C++ header library**. There are no other projects,
services, databases, queues, or HTTP contracts. Every section below is filled in against what
actually exists; sections that cannot apply are marked N/A with the reason rather than omitted.

## 2.1 Projects / modules

| # | Module | Language / standard | Build system | Entry point(s) | Host class | Notes |
|---|---|---|---|---|---|---|
| 1 | `converter` (executable target) | Swift 6.3.3, language mode 6, strict concurrency (mode 6 implies complete checking), 4 upcoming-feature ratchets | SwiftPM (`Sources/Package.swift`, tools 6.3.3, `--package-path Sources`) | `Sources/converter/Main.swift` (`@main ConverterMain`) → `CLIOptions.parse` → `ConverterTool.execute()` | **Mac only** (macOS 15+, Apple Silicon; uses Foundation `Process`, `Synchronization.Mutex`, VideoToolbox encoders via ffmpeg) | 15 source files, 9 021 lines. Release binary is checked in at repo root as `converter`. |
| 2 | `BW64Bridge` (C++ target, C ABI) | C++17 (`cxxLanguageStandard: .cxx17`); public header is C-compatible | SwiftPM target, `publicHeadersPath: include` | `bw64_write_from_f32le_file()` in `Sources/BW64Bridge/bw64_bridge.cpp` | Mac (compiled as part of the package; portable C++ in principle) | Only consumer: `AudioPipeline.swift` (BW64 archival WAV). No C code anywhere in the repo, so the strict-C99 rule from §1 has no target; C++ is held to `-Wall -Wextra -Werror`, cppcheck, clang-tidy, ASan/UBSan. |
| 3 | `converterTests` (XCTest target) | Swift 6.3.3 | SwiftPM test target, `@testable import converter` | `Sources/Tests/converterTests/*.swift` | Mac only | 74 unit + 85 integration tests (159). Integration tests run real ffmpeg/ffprobe/magick in per-test temp workspaces. |
| 4 | `ThirdParty/libbw64` (vendored) | C++ header-only, Apache-2.0 | consumed via `headerSearchPath` from target 2 | n/a | Mac (as above) | Version 0.10.0 == upstream latest release (ebu/libbw64, 2019-01-28). Vendored verbatim; not edited. |
| 5 | CI | YAML | GitHub Actions `.github/workflows/ci.yml` (`macos-26`, Xcode 26.6) + GitHub-managed CodeQL (`dynamic/github-code-scanning/codeql`) | push/PR to `main`, `workflow_dispatch` | GitHub-hosted Mac | `CONVERTER_AUTO_INSTALL_DEPS=0`; installs ffmpeg + imagemagick via brew each run (unpinned). |
| 6 | Runtime configuration | text | — | `config.txt` (KEY=value, 76 keys), `album.txt` (track order) | — | Schema lives in `Sources/converter/Config.swift`; docs in wiki `Configuration`. |
| 7 | Documentation | Markdown | — | `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `docs/FORMATS.md`, `docs/KNOWN_GOOD_VERSIONS.md`, `docs/RELEASE_CHECKLIST.md`, GitHub wiki (8 pages) | — | CLI help text in `CLI.swift` is a third copy of the command reference. |

External runtime dependencies (not built here, resolved at run time by `DependencyBootstrap.swift`):
`ffmpeg`, `ffprobe` (Homebrew `ffmpeg`), `magick` (Homebrew `imagemagick`), system `awk`, `sed`, and
optionally `brew` itself. No SwiftPM package dependencies exist (no `Package.resolved`).

## 2.2 Dependency graph and implicit coupling

Build-time graph (acyclic):

```
converterTests ──@testable──▶ converter ──▶ BW64Bridge ──▶ ThirdParty/libbw64 (headers)
```

Inside `converter` every pipeline file is an `extension ConverterTool` (declared in
`PipelineCore.swift`), so there is one module-wide type rather than layered modules. The de-facto
layering is:

```
Main → CLI / Config / DependencyBootstrap → PipelineCore (tool, temp files, publish, probes)
     → ValidationPipeline (all verifiers)  ← used by every producer below
     → LosslessAudioPipeline → AudioPipeline / VideoPipeline / ImagePipeline → Actions (steps)
     ProcessRunner + Support (AppError, Logger, AsyncSemaphore, LoudnormArgument) underneath all
```

Implicit contracts (each one is a place where two files must agree without the compiler checking):

| Contract | Producer | Consumer(s) |
|---|---|---|
| `config.txt` key names, defaults, validation ranges | `Config.swift` | `config.txt`, wiki `Configuration`, `-doctor` |
| Config keys doubled as environment variables (same names) | `Config.swift` load order | any shell that sets e.g. `WAV_SAMPLE_RATE` |
| Env vars `SRC_DIR`, `OUT_DIR`, `OUTPUT_DIR`, `CONFIG_FILE`, `DEBUG`, `CONVERTER_ROOT`, `CONVERTER_NAME`, `CONVERTER_AUTO_INSTALL_DEPS` | `CLI.swift`, `Main.swift`, `DependencyBootstrap.swift` | users, CI (`ci.yml`), tests |
| Output-name suffix grammar: `_8K`, `_4K`, `_3K`, `_2K`, `_NFT8K/3K/2K`, `_1MB/_2MB/_5MB/_20MB`, `_Short`, `_Short_CenterCut`, `_FullSong`, `_RF64`, `_BW64`, `_bass…`, `_loudness…`, `_mastered`, `_faded_…`, `_fadecut_…`, `_fadeout_…`, `_silence_…`, `_noise_…`, `album.wav`, `1.<ext>` | every pipeline | `Actions.swift` source-selection filters (rerun stability), docs, users |
| Named inputs `Horizontal_8K.png`, `Vertical_8K.png`, `*_NFT8K.png`, `album.txt` | users | `Actions.swift` |
| Hidden temp/backup names `.converter-tmp.<pid>.<uuid>.*`, `.<name>.publish-backup` | `PipelineCore.swift` | `-clean`, startup recovery, `.gitignore` |
| ffmpeg/ffprobe/magick CLI argument and output formats (loudnorm JSON, `astats`, `volumedetect`, `ffprobe -show_entries`, `identify -format`) | external tools | `ProcessRunner` callers, `ValidationPipeline` parsers |
| Encoder / filter names checked by `-doctor` vs names used in renders | `Diagnostics.swift` | `VideoPipeline.swift`, `AudioPipeline.swift`, `config.txt` ladders |
| C ABI `bw64_write_from_f32le_file` (arg order, error buffer semantics) | `include/bw64_bridge.h` | `AudioPipeline.swift` |
| Test count and timing quoted in prose | tests | `README.md`, `CONTRIBUTING.md`, `KNOWN_GOOD_VERSIONS.md` |

N/A for this repository: shared schemas, IPC, HTTP contracts, sockets, DB tables, queues, LLM
interfaces. None exist.

## 2.3 Trust boundaries

| Boundary | What crosses it | Where it is handled |
|---|---|---|
| Untrusted media files in `SRC_DIR` (audio, images, MP4) | arbitrary bytes | Parsed by ffmpeg/ffprobe/magick (external, sandboxed only by being separate processes); RIFF/WAV headers additionally parsed in Swift (`ValidationPipeline.swift`) and by libbw64 in the bridge |
| File **names** in `SRC_DIR`, `album.txt`, `--output-file`, `--src-dir`, `--out-dir` | paths | `requireDirectChild` / `resolveExplicitPath` (`PipelineCore.swift`); all tools invoked with argument arrays (no shell) |
| `config.txt` and same-named environment variables | numbers, strings that become ffmpeg/magick arguments | `Config.validate()`; filter-name allow-list for loudness (`validateLoudnessFilterIsEQNeutral`) |
| Network | **only** when `CONVERTER_AUTO_INSTALL_DEPS=1`: `brew install …` and, if brew is absent, `curl … install.sh \| bash` | `DependencyBootstrap.swift`; off by default; CI sets `0` |
| Credentials | none held, none read | — |
| Listening sockets / inbound network | none | — |
| Process environment | `PATH` is enriched with Homebrew/system dirs before resolving tools | `DependencyBootstrap.enrichedEnvironment` |

## 2.4 Blast radius

| Module / file | Consumers | Audit severity uplift |
|---|---|---|
| `PipelineCore.swift` (temp files, publish/backup, probes, path containment) | every pipeline and every action | **High** — a defect here corrupts or loses user outputs across all 50+ actions |
| `ValidationPipeline.swift` (verify-before-publish) | every producer | **High** — a wrong verifier either blocks all runs or lets bad deliverables ship |
| `Support.swift` (`AppError`, `Logger`, `AsyncSemaphore`, `LoudnormArgument`) | all | **High** |
| `ProcessRunner.swift` | all external tool calls | **High** |
| `Config.swift` | all | High |
| `LosslessAudioPipeline.swift` | audio, video, actions | Medium-high |
| `AudioPipeline.swift`, `VideoPipeline.swift`, `ImagePipeline.swift` | `Actions.swift` | Medium |
| `Actions.swift`, `CLI.swift`, `Main.swift` | user | Medium (single consumer, but it is the product surface) |
| `BW64Bridge` + `libbw64` | `AudioPipeline.swift` (one call site) | Medium (native code, memory safety) |
| `DependencyBootstrap.swift` | startup | Medium (only network path) |
| Docs / wiki / CLI help | users | Low, but three copies must agree |
