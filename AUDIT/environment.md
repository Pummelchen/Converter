# Audit environment record — session 2026-09-14 (Swift 6.4 / Xcode 27)

Everything here must be re-installable from this file alone. Versions are what was actually
observed on **2026-09-15** (the session's clock; the audit branch is named `audit/2026-09-14`).

## Standard applied

| Language | Standard this audit holds the repo to |
|---|---|
| Swift | **6.4** (Xcode 27), strict concurrency (language mode 6), warnings-as-errors |
| C++ | C++17, `-Wall -Wextra -Werror`; first-party code only, vendored headers stay verbatim |
| C | **N/A** — no C sources exist (no `*.c` outside vendored third-party) |
| Python | 3.14 present only as audit tooling (`AUDIT/tools/*.py`); nothing Python ships in the product |
| C# / .NET | **N/A** — no C# in the repository |

## Hosts

| Host | Role | Hardware | OS | Xcode | Swift | ffmpeg | ImageMagick |
|---|---|---|---|---|---|---|---|
| local | development, baseline, all static scanning | **Apple M2, 8 GB** | **27.0 (26A428)** | **27.0 (27A266a)** | **6.4 (swiftlang-6.4.0.34.1)** | 9.0.1 | 7.1.2-31 Q16-HDRI |
| `node1` (Mac Mini M2, 8 GB) | independent verification (Phase E) | M2, 8 GB | 27.0 | 27.0 | 6.4 | 9.0.1 | 7.1.2-31 |
| `node2`, `node3`, `node4` (Mac Mini M2, 8 GB) | reserve | M2, 8 GB | 27.0 | 27.0 | 6.4 | 9.0.1 | 7.1.2-31 |
| Debian 13 Intel VPS | **not used** — nothing in this repository builds on Linux (Swift/Xcode only), so the standard's Linux/x86 rules have no target here | — | — | — | — | — | — |

SSH reaches `node1`..`node4` with key authentication as `<host>@<host>`; no password is stored or
transmitted anywhere. The VPS is available but **not provisioned** — the rules require asking
first, and nothing in this repo needs it.

### Work distribution actually used

- All Swift builds/tests run on Macs. At most **one** heavy job per Mac at a time.
- The local machine for this session is an **8 GB M2**, so that rule applies here too: the full
  suite never runs concurrently with a build or an analyzer that indexes the package.
- Docker 29.8.0 is installed but **not used**: there is no Linux-targeted work in this repo
  (the C++ bridge and all Swift code build natively). Recorded rather than silently skipped.

## Tooling installed for this audit (Homebrew, global, on the local host)

Install command (reproducible):

```bash
brew install swiftlint periphery gitleaks trufflehog semgrep cppcheck llvm jq
```

| Tool | Version | Purpose (§1 minimum coverage) | Install method |
|---|---|---|---|
| `swiftlint` | 0.65.1 | Swift linter | `brew install swiftlint` |
| `swift format` | bundled with Swift 6.4 (`swift format --version` prints `main`) | Swift formatter | ships with Xcode 27 |
| Swift compiler | 6.4 (`swiftlang-6.4.0.34.1`), language mode 6, `-warnings-as-errors` | type checker / strict concurrency | ships with Xcode 27 |
| `periphery` | 3.8.0 | Swift unused-code static analyzer | `brew install periphery` |
| `semgrep` | 1.176.0 | SAST (`p/swift`, `p/c`, `p/security-audit`, `p/secrets`) | `brew install semgrep` |
| `gitleaks` | 8.30.1 | secret scan, full git history | `brew install gitleaks` |
| `trufflehog` | 3.97.4 | secret scan, full git history (second engine) | `brew install trufflehog` |
| `cppcheck` | 2.21.0 | C++ static analyzer (bridge) | `brew install cppcheck` |
| `clang-tidy` | Homebrew LLVM 23.1.1 | C++ static analyzer, `bugprone-*,cert-*,clang-analyzer-*,performance-*,misc-*` | `brew install llvm` |
| `xcrun llvm-cov` | Apple LLVM 21.0.0 | coverage measurement | ships with Xcode 27 |
| `swift build --sanitize=address/undefined/thread` | Xcode 27 toolchain | sanitizer builds for Swift + the C++ bridge | ships with Xcode 27 |
| `jq` | 1.8.2 | report processing | `brew install jq` |
| `python3` | 3.14.7 | audit tooling (`AUDIT/tools/*.py`) | system / Homebrew |
| `ruff` | 0.16.7 | Python formatter + linter (`pyproject.toml`, `scripts/check-python.sh`) | `brew install ruff` |
| `mypy` | 2.3.1 | Python type checker, `--strict` (`pyproject.toml`) | `brew install mypy` |
| Docker | 29.8.0 (88096ef005) | disposable Linux toolchains — unused here, see above | Docker Desktop |

### Coverage of the §1 minimum per language

| Requirement | Swift | C++ (bridge) | Python (audit tooling only) |
|---|---|---|---|
| formatter | `swift format` (`swift-format` config committed, enforced by `scripts/check-format.sh` and CI — task #0106) | `clang-format` (LLVM 23.1.1) | `ruff format`, enforced by `scripts/check-python.sh` |
| linter | swiftlint (`.swiftlint.yml` pins the rule set; `scripts/lint-budget.sh` ratchets it) | clang-tidy | `ruff check`, enforced by `scripts/check-python.sh` |
| static analyzer | periphery + compiler | cppcheck + clang-tidy + clang static analyzer | `mypy --strict` (`pyproject.toml`) |
| type checker | swiftc, language mode 6, warnings-as-errors | `clang -std=c++17 -Wall -Wextra -Werror` | `mypy --strict` |
| SAST | semgrep `p/swift`, `p/security-audit` | semgrep `p/c`, `p/security-audit` | semgrep `p/python` (covered by the CI SAST job) |
| dependency / CVE scanner | **N/A with justification**: no SwiftPM dependencies exist (no `Package.resolved`); the only vendored dependency is libbw64 0.10.0, equal to the latest upstream release (2019-01-28) with no advisories on record. Runtime tools (ffmpeg/ImageMagick) are Homebrew-managed and outside the build; versions recorded above. The vendored tree is hash-compared against the upstream tag in `Sources/ThirdParty/libbw64/UPSTREAM.md`. | same | stdlib only |
| secret scanner over full history | gitleaks (`.gitleaks.toml` carries one documented false-positive exception) + trufflehog | same | same |
| sanitizer builds + memory checker | ASan/UBSan/TSan via `swift test --sanitize=…`; macOS has no valgrind, ASan+LeakSanitizer is the memory checker | same (the bridge is compiled into the sanitized build) | n/a |
| coverage | `swift test --enable-code-coverage` + `llvm-cov` | included (the bridge object is instrumented) | n/a |

## Commands used for the baseline (copy-paste reproducible)

```bash
# from the repository root, Sources/.build removed first
swift build --package-path Sources --build-tests -Xswiftc -warnings-as-errors
swift build --package-path Sources -c release -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror
swift test  --package-path Sources --enable-code-coverage
xcrun llvm-cov report Sources/.build/debug/converterPackageTests.xctest/Contents/MacOS/converterPackageTests \
  -instr-profile Sources/.build/debug/codecov/default.profdata -ignore-filename-regex='Tests|ThirdParty|\.build'
swiftlint lint --quiet --reporter json Sources/converter Sources/Tests
periphery scan --project-root Sources --retain-public --format csv
gitleaks git --no-banner --redact=100 .
trufflehog git file://. --no-update
semgrep scan --config p/swift --config p/c --config p/security-audit --config p/secrets --exclude .build --exclude ThirdParty Sources
# --check-level=exhaustive analyses every branch; the vendored path is out of the *gate* (its
# integrity is the hash comparison in Sources/ThirdParty/libbw64/UPSTREAM.md), and checkersReport is
# cppcheck's own informational summary rather than a finding.
cppcheck --enable=all --check-level=exhaustive --error-exitcode=1 --std=c++17 --inline-suppr \
  --suppress=missingIncludeSystem --suppress=checkersReport --suppress='*:*/ThirdParty/*' \
  -I Sources/ThirdParty/libbw64 -I Sources/BW64Bridge/include Sources/BW64Bridge/bw64_bridge.cpp
clang-tidy Sources/BW64Bridge/bw64_bridge.cpp \
  -checks='bugprone-*,cert-*,clang-analyzer-*,performance-*,misc-*,-misc-include-cleaner' -- \
  -std=c++17 -I Sources/ThirdParty/libbw64 -I Sources/BW64Bridge/include -isysroot "$(xcrun --show-sdk-path)"
```

### Swift 6.4 build-layout note (periphery / index store)

Swift 6.4 changed the SwiftPM build layout: products now live under
`Sources/.build/out/Products/Debug/…`, and `.build/debug` is a symlink to it. The index store that
`periphery scan` consumes is **no longer emitted by a plain build**; it only appears when the build
is run with the flag, so the analyzer must be preceded by:

```bash
swift build --package-path Sources --build-tests --enable-index-store
# index store: Sources/.build/out/Products/Debug/index/store  (reachable as Sources/.build/debug/index/store)
```

Without it, periphery 3.8.0 fails with
`Error: index store path does not exist: …/.build/debug/index/store`. The coverage command above is
unaffected (`.build/debug` resolves through the symlink).

## Host state

- Nothing was installed on `node1`..`node4`; they already carry Xcode 27.0 / Swift 6.4 and the media
  tools. Phase E clones into `~/audit/Converter` and removes it afterwards.
- No Docker containers or images were created.
- The VPS was not touched.

## Previous session

The 2026-09-13 audit ran on macOS 26.6.2 / Xcode 26.6 / Swift 6.3.3 on a 24 GB M3 laptop. That host
is not part of this session's fleet; this file was rewritten because the whole environment changed
(OS major version, Xcode major version, Swift minor version, and the local machine itself).
