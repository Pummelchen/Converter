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
# Start Here: Fresh AI Session Prompt

Use the prompt below for a brand-new AI coding session in this repository.

```text
You are working in the Converter repository.

First, read these files in order:
1. AI_INDEX.md
2. AGENTS.md
3. .ai/PROJECT_MAP.md
4. .ai/ARCHITECTURE.md
5. .ai/COMMANDS.md
6. .ai/TESTING.md
7. .ai/KNOWN_UNKNOWNS.md
8. README.md
9. Sources/Package.swift
10. The source files directly relevant to my requested change.

Before editing, summarize:
- verified facts from the current repository;
- assumptions;
- inferences;
- unknowns or conflicts;
- files you expect to modify;
- validation commands you expect to run.

Important repository rules:
- Current source code, package config, runtime config, and tests override generated onboarding docs.
- This is a Swift Package under Sources/, so use swift commands with --package-path Sources.
- Do not edit the checked-in converter binary or Output/ media files unless explicitly asked.
- Do not weaken path containment, temp-file safety, media validation, or process execution safety without calling it out.
- Inspect current source files before making edits.
- Keep context focused: read the relevant onboarding docs and only the source/test files needed for the task.

When finished, report:
- changed files;
- what changed;
- validation commands run and results;
- skipped validation and why;
- remaining risks or unknowns.
```

## Context-loading strategy

- Start with `AI_INDEX.md` for the repo map and task routing.
- Use `AGENTS.md` for operating rules and safety expectations.
- Use `.ai/PROJECT_MAP.md` and `.ai/COMPONENTS.md` to choose files.
- Use `.ai/ARCHITECTURE.md` only as a quick system overview; verify details in source before editing.
- Use `.ai/COMMANDS.md` and `.ai/TESTING.md` for validation.
- Use `.ai/KNOWN_UNKNOWNS.md` to avoid overclaiming.

## Uncertainty handling

Use these labels in your own notes and responses:

- `verified`: directly supported by current files or commands.
- `assumption`: necessary working assumption not yet verified.
- `inference`: likely conclusion based on repository evidence.
- `unknown`: not verifiable from available files.
- `conflicting`: docs/source mismatch requiring care.

## Implementation-plan format

For code changes, produce a compact plan:

| Step | Files | Purpose | Validation |
|---|---|---|---|
| 1 | ... | ... | ... |

Do not over-plan small documentation-only edits.
