# Baseline (§3) — commit `4bb136a`, captured 2026-09-13 on the local host

This is the regression yardstick. No later state may be worse than any row here without a
numbered, justified ledger task. Raw reports live in `AUDIT/baseline/`. Sanitizer rows are
filled in by the ledger task that ran them (see the bottom of this file).

## Build

| Command | Result | Warnings | Errors |
|---|---|---|---|
| `swift build --package-path Sources -Xswiftc -warnings-as-errors` (clean, debug) | success, 5.8 s | 0 | 0 |
| `swift build --package-path Sources -c release` (canonical, as CI) | success, 54 s | 0 | 0 |
| `swift build --package-path Sources -c release -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror` (strict C++) | **FAILS** | — | 3 × `-Wsign-compare` in `Sources/ThirdParty/libbw64/bw64/reader.hpp:220,225,227` (vendored header, compiled into `BW64Bridge`) |

Swift language mode 6 (strict concurrency complete) with upcoming features `ExistentialAny`,
`MemberImportVisibility`, `InferIsolatedConformances`, `ImmutableWeakCaptures`: clean.

## Tests

| Command | Result |
|---|---|
| `swift test --package-path Sources --enable-code-coverage` (serial, canonical) | **159 executed, 0 failures, 0 unexpected, 0 skipped**, 531.4 s (85 integration 528.7 s + 74 unit 2.7 s) |

## Coverage (`llvm-cov`, production sources only)

| Metric | Value |
|---|---|
| Regions | 72.98 % |
| Functions | 77.05 % |
| **Lines** | **79.57 %** (8 968 lines, 1 832 missed) |

| File | Lines | Missed | Line cov |
|---|---|---|---|
| Main.swift | 61 | 61 | 0.00 % |
| DependencyBootstrap.swift | 245 | 204 | 16.73 % |
| Actions.swift | 1622 | 565 | 65.17 % |
| ProcessRunner.swift | 154 | 29 | 81.17 % |
| AudioPipeline.swift | 2296 | 431 | 81.23 % |
| ImagePipeline.swift | 401 | 74 | 81.55 % |
| ValidationPipeline.swift | 1175 | 171 | 85.45 % |
| Config.swift | 481 | 57 | 88.15 % |
| Support.swift | 260 | 28 | 89.23 % |
| VideoPipeline.swift | 409 | 43 | 89.49 % |
| PipelineCore.swift | 891 | 91 | 89.79 % |
| CLI.swift | 617 | 59 | 90.44 % |
| Diagnostics.swift | 103 | 7 | 93.20 % |
| LosslessAudioPipeline.swift | 212 | 12 | 94.34 % |
| QualityReporting.swift | 41 | 0 | 100.00 % |

Full table: `AUDIT/baseline/coverage-local-4bb136a.txt`.

## Linters / analyzers / type checker

| Tool | Result |
|---|---|
| swiftc, language mode 6, `-warnings-as-errors` | 0 diagnostics |
| swiftlint 0.65.1, default rules, `Sources/converter` + `Sources/Tests` | **533** violations (26 + 8 + 6 + 5 + 4 + 4 + 1 + 1 + 1 = **56 error-level**, 477 warning-level). By rule: line_length 437, inclusive_language 19, function_body_length 21, identifier_name 18, file_length 11, type_body_length 6, cyclomatic_complexity 8, function_parameter_count 4, large_tuple 4, for_where 2, optional_data_string_conversion 1, syntactic_sugar 1, type_name 1. Detail: `AUDIT/baseline/swiftlint-by-rule-4bb136a.txt`. No `.swiftlint.yml` exists in the repo. |
| periphery 3.8.0 (`--retain-public`) | **21** declarations flagged: 6 `unused` (`Actions.swift:114 rankedFullRunImageCandidates()`, `ImagePipeline.swift:26-27` params `filter`, `colorSpace`, `ProcessRunner.swift:78 fileManager`, `ValidationPipeline.swift:857 decodeAudioToCanonicalPCM`, `IntegrationTestSupport.swift:32 projectRoot`) and 15 `assignOnlyProperty` (struct fields used only as data/Hashable keys). Detail: `AUDIT/baseline/periphery-4bb136a.txt`. |
| cppcheck 2.21.0 `--enable=all` on `bw64_bridge.cpp` | 0 findings in first-party code; 10 style/performance notes inside vendored `ThirdParty/libbw64` headers (non-explicit constructors, functionStatic, returnByReference) |
| clang-tidy (LLVM 23.1.1) `bugprone-*,cert-*,clang-analyzer-*,performance-*,misc-*` on `bw64_bridge.cpp` | 3 findings in first-party code: `misc-const-correctness` ×1, `bugprone-easily-swappable-parameters` ×2 (the C ABI signature); 226 in vendored headers |

## Security / SAST / secrets / dependencies

| Tool | Result |
|---|---|
| semgrep 1.176.0 (`p/swift`, `p/c`, `p/security-audit`, `p/secrets`), 21 files | **0** findings |
| gitleaks 8.30.1, full history (`gitleaks git`) | **0** leaks (1.15 MB scanned) |
| trufflehog 3.97.4, full history | **0** verified, **0** unverified secrets (9 269 chunks) |
| Dependency / CVE | No SwiftPM dependencies. Vendored libbw64 0.10.0 == latest upstream release (2019-01-28), no advisories on record. Runtime tools: ffmpeg 9.0.1, ImageMagick 7.1.2-31 (Homebrew, unpinned in CI). |

## Repository hygiene observed at baseline

- Working tree clean at `4bb136a`; `Sources/.build/` and `Output/*` ignored.
- Release binary `converter` (1 533 528 bytes, Mach-O arm64) is committed; no provenance record.
- No `LICENSE` file at the repository root; vendored libbw64 is Apache-2.0.
- `SECURITY.md` is the unedited GitHub template.
- No tags, no releases; `docs/RELEASE_CHECKLIST.md` entirely unchecked.
- CI: `macos-26`, `brew install ffmpeg imagemagick` unpinned, `CONVERTER_AUTO_INSTALL_DEPS=0`; last 8 runs green.

## Sanitizer runs (test suite under `swift test --sanitize=…`, separate scratch paths)

Filled in by the sanitizer ledger entry once the three runs complete; see `AUDIT/ledger.md`.
