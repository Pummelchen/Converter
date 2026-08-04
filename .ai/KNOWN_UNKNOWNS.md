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
# Known Unknowns

## Repository facts not fully verifiable in this run

| Status | Item | Why it matters | Suggested follow-up |
|---|---|---|---|
| `verified` | Complete file inventory | Known from a direct clone via `git ls-files`; the bootstrap-era warning about partial inventory no longer applies. | None. |
| `verified` | CI/CD absence | No `.github/` directory exists in the clone; there are no workflows. | None unless CI is added. |
| `resolved` | BW64 bridge scope | `Sources/BW64Bridge/bw64_bridge.cpp` (192 lines) wraps vendored `libbw64` read/write for archival WAV/FLAC companions; internals are small and inspectable. | Re-inspect when changing BW64/RF64 behavior. |
| `unknown` | Local tool versions | Repository documents required tools but does not pin FFmpeg, ImageMagick, or Homebrew formula versions beyond Swift tools 6.3.3, Swift language mode 6, and macOS 14 in `Sources/Package.swift`. | Record known-good local versions after a successful build/test run. |
| `unknown` | Runtime performance envelope | Large media processing cost depends on input size, codecs, and hardware. | Benchmark on representative media before performance-sensitive changes. |

## Conflicts identified

No active docs/code conflicts remain after the `c75929f` refresh.

Historical note: the bootstrap-era docs (indexed at `0ec7e71`) missed four files that already existed then (`Sources/converter/Diagnostics.swift`, `Sources/converter/LosslessAudioPipeline.swift`, `Sources/converter/QualityReporting.swift`, `Sources/Tests/converterTests/IntegrationTestSupport.swift`) and predated the `-short` action, the `-mp3toshort` -> `-nfttoshort` rename, generic-audio short renders, backup-based publishing, and orphaned temp cleanup. All fixed in this refresh.

## Areas requiring human review before risky edits

- Auto-install/network behavior in `Sources/converter/DependencyBootstrap.swift`.
- Any change that relaxes path containment in `Sources/converter/PipelineCore.swift`.
- Any change that weakens output verification in `Sources/converter/ValidationPipeline.swift`, `ImagePipeline.swift`, `AudioPipeline.swift`, or `VideoPipeline.swift`.
- Any update to the checked-in `converter` binary.
- Any change to vendored `Sources/ThirdParty/libbw64/` or native `Sources/BW64Bridge/` code.
- Any command that processes or uploads user media from `Output/`.

## Model-specific AI files

Common model-specific/generated instruction paths were checked and none were found at the inspected paths. No model-specific files were migrated, deprecated, preserved, or removed during bootstrap.

## Stale facts removed

- Removed bootstrap-era warnings about unavailable `git clone`, partial file inventory, and unverified CI absence; all three were resolved by a direct clone at `c75929f`.
- Removed `inferred` qualifiers from integration-test environment requirements, now verified by running the full suite.
