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
# Security Notes

This repository does not appear to implement authentication, authorization, payments, a network service, or a database. Security sensitivity comes from local command execution, dependency installation, file path handling, and private media processing.

## Security-sensitive areas

| Area | Files | Risk | Rule for agents |
|---|---|---|---|
| External process execution | `Sources/converter/ProcessRunner.swift`, pipeline files | User/config-derived paths and options are passed to powerful media tools. | Preserve array-based `Process.arguments`; avoid shell string interpolation. |
| Runtime dependency bootstrap | `Sources/converter/DependencyBootstrap.swift` | Can run Homebrew install and `brew install` non-interactively. | Do not add new network/install behavior without explicit human review. |
| Homebrew installer path | `DependencyBootstrap.ensureHomebrew` | Uses a downloaded Homebrew installer executed by the system shell. | Prefer documenting and gating behavior; keep `CONVERTER_AUTO_INSTALL_DEPS=0` escape hatch. |
| Path containment | `Sources/converter/PipelineCore.swift` | Prevents explicit paths from escaping configured source/output directories. | Do not weaken `requireDirectChild`, `resolveOutputPath`, or explicit input path checks. |
| Temp files and publishing | `PipelineCore.swift` | Avoids source discovery collisions and partial outputs. | Keep hidden run-scoped temp names and verify-before-publish flow. |
| Media inputs/outputs | `Output/`, README full-run contract | Media may be private, large, copyrighted, or expensive to process. | Do not upload, expose, or commit media files. |
| Vendored/native code | `Sources/BW64Bridge/`, `Sources/ThirdParty/libbw64/` | Native bridge correctness and memory safety. | Review carefully and run build/tests before changes. |

## Secrets and credentials

Verified repository files inspected do not define application secrets, API keys, or credential files.

Still apply these rules:

- Never commit access tokens, credentials, local paths containing secrets, or private media metadata.
- Before committing onboarding/docs changes, scan generated files for token-like strings, private-key markers, cloud credentials, and generic credential assignment patterns.
- Do not include user-provided credentials in docs, comments, commit messages, or manifests.

## Environment variables observed

| Variable | Purpose | Source |
|---|---|---|
| `CONVERTER_ROOT` | Overrides script/root directory calculation | `Main.swift` |
| `CONVERTER_NAME` | Overrides script display name | `Main.swift` |
| `CONVERTER_AUTO_INSTALL_DEPS` | Disables auto-install when set to `0`, `false`, `no`, or `off` | `DependencyBootstrap.swift`, README |
| `OUTPUT_DIR` | Sets default source and output dirs | `CLI.swift` |
| `SRC_DIR` | Sets source dir | `CLI.swift` |
| `OUT_DIR` | Sets output dir | `CLI.swift` |
| `CONFIG_FILE` | Overrides config file path | `CLI.swift` |
| `DEBUG` | Enables debug logging when truthy | `CLI.swift` |
| config keys from `ProjectConfig.supportedKeys` | Override project media settings | `Config.swift`, `config.txt` |

## Safe validation commands

Use these for docs/onboarding work:

```bash
python -m json.tool .ai/MANIFEST.json >/dev/null
git diff --check
git status --short
```

Use this to check dependencies without auto-install side effects:

```bash
CONVERTER_AUTO_INSTALL_DEPS=0 ./converter -doctor
```

## Agent red flags

Ask for human review before:

- adding new external downloads or installers;
- adding shell-based command construction;
- allowing recursive source discovery again;
- processing subdirectories or arbitrary absolute paths;
- lowering validation/QC thresholds;
- changing loudness preservation semantics;
- changing default output overwrite behavior;
- replacing vendored native code;
- committing a regenerated `converter` binary.
