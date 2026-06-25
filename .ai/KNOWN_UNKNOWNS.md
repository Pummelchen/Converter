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
# Known Unknowns

## Repository facts not fully verifiable in this run

| Status | Item | Why it matters | Suggested follow-up |
|---|---|---|---|
| `unknown` | Complete file inventory | Direct `git clone` was unavailable in the execution container; repository understanding used GitHub source fetches for known paths and current commit metadata. | On a local machine, run `git ls-files` and compare against `.ai/MANIFEST.json` source file list. |
| `unknown` | CI/CD | Common Swift/CI workflow paths were not found, but full tree enumeration was unavailable. | Check `.github/workflows/` with `git ls-files .github/workflows`. |
| `unknown` | Local tool versions | Repository documents required tools but does not pin Swift, FFmpeg, ImageMagick, or Homebrew formula versions beyond Swift tools 6.0/macOS 14 in `Sources/Package.swift`. | Record known-good local versions after a successful build/test run. |
| `unknown` | Full BW64 bridge internals | Package declares `Sources/BW64Bridge` and `Sources/ThirdParty/libbw64`, but detailed bridge source was not inspected. | Inspect bridge files before changing BW64/RF64/BW64 behavior. |
| `unknown` | Runtime performance envelope | Large media processing cost depends on input size, codecs, and hardware. | Benchmark on representative media before performance-sensitive changes. |

## Conflicts identified

No active docs/code conflicts were identified in inspected files.

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

None. This was the initial bootstrap generation.
