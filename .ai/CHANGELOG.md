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
# AI Onboarding Changelog

## 2026-08-04T15:07:37Z — refresh at `c75929f41d4c17970b367c43051de3f6cb09af90`

### Changed

- Re-indexed all onboarding files from `0ec7e71` to `c75929f` after verifying the full clone, build, and all 122 tests.
- Documented previously missed files: `Sources/converter/Diagnostics.swift`, `Sources/converter/LosslessAudioPipeline.swift`, `Sources/converter/QualityReporting.swift`, `Sources/Tests/converterTests/IntegrationTestSupport.swift`.
- Documented the new `-short` action and the `-mp3toshort` -> `-nfttoshort` rename, generic audio-only short inputs, NFT-artwork short image resolution, and same-stem audio auto-ranking.
- Documented full-run changes: direct `Horizontal_8K.png` inputs now still derive companion deliverables via `fullImagePipelineFromDirect8K` and `fourKPNGFrom8K`; shorts fall back to `*_NFT8K.png` when `Vertical_8K.png` is absent.
- Documented runtime behavior changes: backup-based `publishTemp`, run-scoped temp cleanup, orphaned `.converter-tmp.*` cleanup at startup, and stable short MP4 stem naming.
- Updated `Package.swift` facts: swift-tools 6.3.3, `swiftLanguageModes: [.v6]`, release-only `-cross-module-optimization`.
- Marked CI absence and full file inventory as verified; resolved BW64 bridge unknown.
- Updated `README.md` with `-short` and the missing pipeline files.
- Populated the GitHub wiki with pages matching current repository state.

## 2026-06-25T10:26:41Z — bootstrap at `0ec7e71f0decd52d208c001ec16c4d7382d73fa7`

### Added

- Created root `AI_INDEX.md` as the primary repository orientation file.
- Created root `AGENTS.md` with generic, vendor-neutral AI coding-agent instructions.
- Created `.ai/START_HERE.md` with a pasteable first-session prompt.
- Created `.ai/PROJECT_MAP.md`, `.ai/ARCHITECTURE.md`, `.ai/COMPONENTS.md`, `.ai/COMMANDS.md`, `.ai/TESTING.md`, `.ai/SECURITY.md`, `.ai/PLAYBOOKS.md`, `.ai/KNOWN_UNKNOWNS.md`, and `.ai/MANIFEST.json`.
- Added a vendor-neutral AI onboarding block near the top of `README.md`.

### Source areas used

- `README.md`
- `Sources/Package.swift`
- `config.txt`
- `.gitignore`
- `Sources/converter/Main.swift`
- `Sources/converter/CLI.swift`
- `Sources/converter/Config.swift`
- `Sources/converter/DependencyBootstrap.swift`
- `Sources/converter/ProcessRunner.swift`
- `Sources/converter/Support.swift`
- `Sources/converter/PipelineCore.swift`
- `Sources/converter/Actions.swift`
- `Sources/converter/ValidationPipeline.swift`
- `Sources/converter/ImagePipeline.swift`
- `Sources/converter/AudioPipeline.swift`
- `Sources/converter/VideoPipeline.swift`
- `Sources/Tests/converterTests/converterTests.swift`
- `Sources/Tests/converterTests/PipelineIntegrationTests.swift`

### Model-specific migration

None. Checked common paths did not reveal existing model-specific AI instruction files.

### Risks / unknowns recorded

- Complete file tree could not be enumerated through direct clone in this environment.
- CI/CD absence should be rechecked with a full local clone.
- Tool versions are not pinned in repository files beyond Swift package metadata.
