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
# Generic AI Agent Guide for Converter

## Start every session this way

1. Read [`AI_INDEX.md`](./AI_INDEX.md), then this file, then [`.ai/START_HERE.md`](./.ai/START_HERE.md).
2. Read `README.md`, `Sources/Package.swift`, and the source files relevant to the requested change.
3. Before editing, summarize verified facts, assumptions, inferences, unknowns, and planned validation.
4. Treat these onboarding files as guidance only. Current source code, package config, tests, and runtime config are the source of truth.

## Source-of-truth order

1. Current Swift/C++ source and package manifest.
2. Runtime config in `config.txt` and dependency bootstrap logic.
3. Tests under `Sources/Tests/converterTests/`.
4. README and project docs.
5. These AI onboarding files.
6. Inference.

When docs and code disagree, trust code/config first and record the discrepancy in `.ai/KNOWN_UNKNOWNS.md` if you update onboarding docs.

## Project-specific guardrails

- This task space is media-processing CLI code, not a web app. Do not introduce server/API assumptions.
- Do not edit product/source code unless the user explicitly asks for a code change. For onboarding-only work, modify only docs and `.ai/` metadata.
- Do not edit the checked-in `converter` binary unless intentionally replacing a release artifact after building.
- Do not commit runtime media outputs from `Output/`; `Output/*` is ignored except `.gitkeep`.
- Do not weaken direct-child path checks, hidden temp naming, or output verification behavior without explicit review.
- Keep command execution through `ProcessRunner` array arguments. Avoid shell string construction unless there is a verified need and appropriate escaping.
- Be cautious with `DependencyBootstrap.swift`: it can install Homebrew/formulae non-interactively.

## Planning changes

For non-trivial changes, produce a short implementation plan with:

- files to inspect first;
- verified current behavior;
- expected source files to modify;
- expected tests to add/update;
- risks and rollback considerations.

Use this task map:

| Change type | Primary files |
|---|---|
| CLI flag/action | `Sources/converter/CLI.swift`, `Sources/converter/Actions.swift`, tests |
| Full production flow | `Sources/converter/Actions.swift`, `ImagePipeline.swift`, `AudioPipeline.swift`, `VideoPipeline.swift` |
| Image behavior | `Sources/converter/ImagePipeline.swift`, `Config.swift`, `config.txt` |
| Audio behavior/QC | `Sources/converter/AudioPipeline.swift`, `ValidationPipeline.swift`, `Config.swift`, `config.txt` |
| Video render/shorts | `Sources/converter/VideoPipeline.swift`, `Config.swift`, `config.txt` |
| Config schema | `Sources/converter/Config.swift`, `config.txt`, README |
| Runtime dependencies | `Sources/converter/DependencyBootstrap.swift`, `ProcessRunner.swift`, README |
| Tests | `Sources/Tests/converterTests/` |

## Validation expectations

Minimum validation for source changes:

```bash
swift test --package-path Sources
```

For release build or binary updates:

```bash
swift build --package-path Sources -c release
cp Sources/.build/arm64-apple-macosx/release/converter ./converter
chmod +x ./converter
```

For docs/onboarding-only changes, validate at least:

```bash
python -m json.tool .ai/MANIFEST.json >/dev/null
git diff --check
git status --short
```

Do not claim tests passed unless they were actually run in the current environment.

## Coding conventions inferred from source

- Swift files use small focused structs/classes plus `extension ConverterTool` blocks split by domain.
- Media operations preflight inputs, produce hidden temp files, verify outputs, then publish.
- Config values are centralized in `ProjectConfig`, with default values, supported key lists, profile overlays, apply logic, and validation.
- Tests use XCTest and `@testable import converter`.
- CLI parser explicitly rejects removed or unsupported flags with actionable messages.

Evidence:
- `Sources/converter/CLI.swift`
- `Sources/converter/Config.swift`
- `Sources/converter/PipelineCore.swift`
- `Sources/converter/Actions.swift`
- `Sources/Tests/converterTests/converterTests.swift`

## Commit / PR expectations

- Keep commits focused by task.
- For documentation-only onboarding updates, use a `docs:` commit message.
- Mention commands actually run and commands skipped with reasons.
- List changed files and distinguish generated/onboarding docs from source changes.
- Do not push directly to `main`.

## Refresh policy for AI onboarding files

Update this onboarding system when any of these change meaningfully:

- `README.md`
- `Sources/Package.swift`
- `config.txt`
- `.github/workflows/**`
- `Sources/converter/**`
- `Sources/BW64Bridge/**`
- `Sources/ThirdParty/**`
- `Sources/Tests/**`
- dependency, build, release, or runtime setup

During refresh, preserve correct human edits, remove stale generated claims, and update `.ai/MANIFEST.json` with the new indexed commit.

## Required factual discipline

When answering or editing:

- label facts as verified only when grounded in current files or commands;
- label assumptions and inferences explicitly;
- mark unknowns rather than guessing;
- inspect current source before editing, even if these docs seem current;
- update onboarding docs if your change invalidates them.
