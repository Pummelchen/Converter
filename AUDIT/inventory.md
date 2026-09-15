# Audit inventory (§2 scope discovery) — session 2026-09-14, Swift 6.4 / Xcode 27

Snapshot taken at commit `40bfadd` on branch `audit/2026-09-14`, on macOS 27.0 / Xcode 27.0 /
Swift 6.4. Supersedes the 2026-09-13 inventory (kept in git history).

## 2.0 Reality check against the brief

The brief describes a monorepo of 20+ interdependent projects. This repository is **one SwiftPM
package with three targets plus one vendored C++ header library** — the same shape the 2026-09-13
audit found and the same shape today. There are no other projects, services, databases, queues,
HTTP contracts, LLM interfaces, or Python/C#/C product code. Sections that cannot apply are marked
N/A with the reason rather than omitted.

## 2.1 Projects / modules

| # | Module | Language / standard | Build system | Entry point(s) | Host class | Notes |
|---|---|---|---|---|---|---|
| 1 | `converter` (executable target) | Swift 6.4, language mode 6 (strict concurrency), 4 upcoming-feature ratchets | SwiftPM (`Sources/Package.swift`, tools 6.3.3, `--package-path Sources`) | `Sources/converter/Main.swift` (`@main ConverterMain`) → `CLIOptions.parse` → `ConverterTool.execute()` | **Mac only** (macOS 15+; Apple Silicon; Foundation `Process`, `Synchronization.Mutex`, VideoToolbox via ffmpeg) | 18 source files, 10 485 lines. Release binary checked in at the repo root (provenance in `docs/BINARY_PROVENANCE.md`). |
| 2 | `BW64Bridge` (C++ target, C ABI) | C++17 (`cxxLanguageStandard: .cxx17`) | SwiftPM target, `publicHeadersPath: include` | `bw64_write_from_f32le_file()` in `Sources/BW64Bridge/bw64_bridge.cpp` | Mac (portable C++ in principle; only consumed by target 1) | 327 lines incl. header. Sole consumer: `AudioPipeline.swift`. No C anywhere, so the strict-C99 rule has no target. |
| 3 | `converterTests` (XCTest target) | Swift 6.4 | SwiftPM test target, `@testable import converter` | `Sources/Tests/converterTests/*.swift` | Mac only | 3 files, 8 012 lines; integration tests run real ffmpeg/ffprobe/magick in per-test temp workspaces. |
| 4 | `ThirdParty/libbw64` (vendored) | C++ header-only, Apache-2.0 | consumed via `headerSearchPath` | n/a | Mac | 0.10.0 == latest upstream release (2019-01-28). Vendored verbatim; never edited. |
| 5 | CI + hooks + scripts | YAML / shell | GitHub Actions, git hooks, `scripts/` | `.github/workflows/ci.yml`, `.githooks/pre-push`, `scripts/lint-budget.sh` | GitHub-hosted Mac + local | CI pins `actions/checkout` by SHA, asserts Swift **6.3.3** (stale for this session — finding), runs the lint budget, both builds and the suite. |
| 6 | Runtime configuration | text | — | `config.txt` (KEY=value), `album.example.txt` (template for the git-ignored `album.txt`) | — | Schema lives in `Sources/converter/Config.swift`; docs in the wiki `Configuration`. |
| 7 | Documentation | Markdown | — | `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `docs/*.md`, wiki (8 pages) | — | CLI help in `CLI.swift` is a third copy of the command reference. |
| 8 | Audit tooling | Python 3.14 | plain scripts | `AUDIT/tools/*.py` (6 files) | local | Not shipped; still subject to the §1 Python standard (annotations + strict type-checking) — recorded as a task. |

External runtime dependencies (resolved at run time by `DependencyBootstrap.swift`): `ffmpeg`,
`ffprobe` (Homebrew `ffmpeg`), `magick` (Homebrew `imagemagick`), system `awk`, `sed`, optionally
`brew`. No SwiftPM package dependencies exist (no `Package.resolved`).

## 2.2 Dependency graph and implicit coupling

Build-time graph (acyclic):

```
converterTests ──@testable──▶ converter ──▶ BW64Bridge ──▶ ThirdParty/libbw64 (headers)
```

Inside `converter` every pipeline file is an `extension ConverterTool` (declared in
`PipelineCore.swift`), so there is one module-wide type rather than layered modules. The de-facto
layering:

```
Main → CLI / Config / DependencyBootstrap → PipelineCore (tool, temps, publish, probes)
     → ValidationPipeline (all verifiers)  ← used by every producer
     → LosslessAudioPipeline → AudioPipeline / VideoPipeline / ImagePipeline → Actions (steps)
     ProcessRunner + Support + AsyncSemaphore + RIFFChunkWalker underneath all
```

Implicit contracts (each a place two files must agree without the compiler checking):

| Contract | Producer | Consumer(s) |
|---|---|---|
| `config.txt` key names, defaults, validation ranges | `Config.swift` | `config.txt`, wiki `Configuration`, `-doctor` |
| Config keys doubled as environment variables | `Config.swift` load order | any shell that sets e.g. `WAV_SAMPLE_RATE` |
| Env vars `SRC_DIR`, `OUT_DIR`, `OUTPUT_DIR`, `CONFIG_FILE`, `DEBUG`, `CONVERTER_ROOT`, `CONVERTER_NAME`, `CONVERTER_AUTO_INSTALL_DEPS` | `CLI.swift`, `Main.swift`, `DependencyBootstrap.swift` | users, CI, tests |
| Output-name suffix grammar (`_8K`, `_4K`, `_3K`, `_2K`, `_NFT*`, `_1MB…`, `_Short[_CenterCut|_FullSong]`, `_RF64`, `_BW64`, `_bass…`, `_loudness…`, `_mastered`, `_faded_…`, `_fadecut_…`, `_fadeout_…`, `_silence_…`, `_noise_…`, `album.wav`, `1.<ext>`, `1_source.<ext>`) | every pipeline | `Actions.swift` source-selection filters (rerun stability), docs, users |
| Named inputs `Horizontal_8K.png`, `Vertical_8K.png`, `*_NFT8K.png`, `album.txt` | users | `Actions.swift` |
| Hidden temp/backup names `.converter-tmp.<host>.<pid>.<uuid>.*`, `.<name>.publish-backup` | `PipelineCore.swift` | `-clean`, startup recovery, `.gitignore` |
| ffmpeg/ffprobe/magick CLI argument and output formats (loudnorm JSON, `astats`, `volumedetect`, `ffprobe -show_entries`, `identify -format`) | external tools | `ProcessRunner` callers, `ValidationPipeline` parsers |
| Encoder / filter names checked by `-doctor` vs names used in renders | `Diagnostics.swift` | `VideoPipeline.swift`, `AudioPipeline.swift`, `config.txt` ladders |
| C ABI `bw64_write_from_f32le_file` (arg order, error-buffer semantics) | `include/bw64_bridge.h` | `AudioPipeline.swift` |
| Binary checksum `docs/converter.sha256` | release build | CI, `CONTRIBUTING` |
| Lint budget `scripts/lint-budget.json` | current swiftlint run | CI, `CONTRIBUTING` |
| Test count / toolchain versions quoted in prose | tests | `README.md`, `CONTRIBUTING.md`, `docs/KNOWN_GOOD_VERSIONS.md` |

N/A for this repository: shared schemas, IPC, HTTP contracts, sockets, DB tables, queues, LLM
interfaces. None exist.

## 2.3 Trust boundaries

| Boundary | What crosses it | Where it is handled |
|---|---|---|
| Untrusted media files in `SRC_DIR` (audio, images, MP4) | arbitrary bytes | Parsed by ffmpeg/ffprobe/magick (separate processes); RIFF/WAV headers additionally parsed in Swift (`ValidationPipeline.swift`, `RIFFChunkWalker.swift`) and by libbw64 in the bridge |
| File **names** in `SRC_DIR`, `album.txt`, `--output-file`, `--src-dir`, `--out-dir` | paths | `requireDirectChild` / `resolveExplicitPath` (`PipelineCore.swift`); all tools invoked with argument arrays (no shell) |
| `config.txt` and same-named environment variables | numbers, strings that become ffmpeg/magick arguments | `Config.validate()`; filter-name allow-lists (`VIDEO_MP4_SCALE_FILTER`, `VIDEO_COLOR_*`, `validateLoudnessFilterIsEQNeutral`) |
| `docs/converter.sha256` and the committed binary | a prebuilt executable | CI checksum gate; rebuilt from source in the previous session |
| Network | **only** when `CONVERTER_AUTO_INSTALL_DEPS=1`: `brew install …` and, if brew is absent, a pinned + SHA-256-verified installer | `DependencyBootstrap.swift` / `DependencyInstaller.swift`; off by default; CI sets `0` |
| Credentials | the product holds and reads none; the PAT embedded in the local `git remote` URL lives outside the repo and outside the product | reported in the ledger as a hygiene item, never echoed |
| Listening sockets / inbound network | none | — |
| Process environment | `PATH` is enriched with Homebrew/system dirs before resolving tools | `DependencyBootstrap.enrichedEnvironment` |

## 2.4 Blast radius

| Module / file | Consumers | Audit severity uplift |
|---|---|---|
| `PipelineCore.swift` (temps, publish/backup, probes, path containment) | every pipeline and action | **High** — a defect here corrupts or loses user outputs across all actions |
| `ValidationPipeline.swift` (verify-before-publish) | every producer | **High** — a wrong verifier either blocks all runs or lets bad deliverables ship |
| `Support.swift`, `ProcessRunner.swift`, `AsyncSemaphore.swift` | all | **High** |
| `Config.swift` | all | High |
| `LosslessAudioPipeline.swift` | audio, video, actions | Medium-high |
| `AudioPipeline.swift`, `VideoPipeline.swift`, `ImagePipeline.swift` | `Actions.swift` | Medium |
| `Actions.swift`, `CLI.swift`, `Main.swift` | user | Medium (single consumer, but the product surface) |
| `BW64Bridge` + `libbw64` | `AudioPipeline.swift` (one call site) | Medium (native code, memory safety) |
| `DependencyBootstrap.swift` / `DependencyInstaller.swift` | startup | Medium (the only network path) |
| `scripts/`, `.githooks/`, CI | contributors, CI | Low-medium (a broken gate silently stops protecting `main`) |
| Docs / wiki / CLI help | users | Low, but three copies must agree |
