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
# Playbooks

## Add or change a CLI action

1. Inspect `Sources/converter/CLI.swift`:
   - add/update `Action` case;
   - parse flags in `CLIOptions.parse`;
   - update help text and `printActionList()` if user-facing.
2. Inspect action dispatch in `Sources/converter/Actions.swift` and related pipeline file.
3. Add implementation in the most specific domain file:
   - image: `ImagePipeline.swift`;
   - audio: `AudioPipeline.swift`;
   - video: `VideoPipeline.swift`;
   - validation: `ValidationPipeline.swift`.
4. Add tests in `Sources/Tests/converterTests/`.
5. Update README command docs if user-facing.
6. Run `swift test --package-path Sources`.

## Change a config setting or add a config key

1. Update defaults in `ProjectConfig` in `Sources/converter/Config.swift`.
2. Add the key to `ProjectConfig.supportedKeys`.
3. Add parsing in `ProjectConfig.apply(key:value:)`.
4. Add validation in `ProjectConfig.validate()` if needed.
5. Update `config.txt` with comments and default value.
6. Update README/AI docs if behavior is user-facing.
7. Add tests for parsing, profile overlay behavior, and invalid values.
8. Run `swift test --package-path Sources`.

## Change full production pipeline behavior

1. Read `README.md` full-run contract.
2. Inspect `Sources/converter/Actions.swift` functions:
   - `resolveFullAudio()`;
   - `fullRunImageArtifacts()`;
   - `fullImagePipeline(...)`;
   - `fullAudioPreparation(...)`;
   - `runFullProductionPipeline(...)`;
   - `stepFull()`.
3. Inspect the relevant domain pipeline files.
4. Preserve preflight -> temp output -> verify -> publish behavior.
5. Update integration tests in `PipelineIntegrationTests.swift`.
6. Update README if inputs/outputs change.
7. Run tests; consider manual media validation only with approved sample files.

## Change image output behavior

1. Inspect `ImagePipeline.swift` and config keys in `Config.swift`/`config.txt`.
2. Update output naming carefully; many workflows derive related names from stems and suffixes.
3. Preserve dimension, format, and byte-size verification.
4. Add/update tests for CLI/help and image pipeline outputs as appropriate.
5. Update README deliverables list if user-facing.

## Change audio standards or loudness behavior

1. Inspect README audio standards and `config.txt` audio/QC keys.
2. Inspect `AudioPipeline.swift` and `ValidationPipeline.swift`.
3. Preserve documented source loudness behavior unless intentionally changing it.
4. Update config schema, README, and tests together.
5. Run full tests and use representative media if safe.

## Change video rendering or short output behavior

1. Inspect `VideoPipeline.swift` and video/short keys in `config.txt`.
2. Preserve short hard cap unless intentionally changing a documented constraint.
3. Preserve encoder fallback ladder behavior and validation of codec/dimensions/color/audio/duration.
4. Update README and tests for changed outputs.

## Change dependency bootstrap behavior

1. Inspect `DependencyBootstrap.swift` and tests in `converterTests.swift`.
2. Avoid adding new auto-install/network side effects without human review.
3. Keep `help`, `list`, and `matrix` free of runtime dependency bootstrap unless intentionally changing startup semantics.
4. Update README runtime dependency section.
5. Run tests and, where safe, `CONVERTER_AUTO_INSTALL_DEPS=0 ./converter -doctor`.

## Update the checked-in release binary

Only do this when explicitly requested.

```bash
swift build --package-path Sources -c release
cp Sources/.build/arm64-apple-macosx/release/converter ./converter
chmod +x ./converter
```

Then report that `converter` changed as a generated binary artifact and include build validation.

## Refresh AI onboarding docs

1. Read `.ai/MANIFEST.json` for `indexed_commit`.
2. Diff from previous indexed commit to current HEAD when reachable.
3. Rescan current source/config/tests for architecture-impacting changes.
4. Update stale sections only; preserve correct human edits.
5. Update `AI_INDEX.md`, relevant `.ai/*.md`, `.ai/CHANGELOG.md`, and `.ai/MANIFEST.json`.
6. Validate JSON and links.
7. Ensure no model-specific files were created.
