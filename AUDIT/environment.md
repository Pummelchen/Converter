# Audit environment record (§1 / §1b)

Everything here must be re-installable from this file alone. Versions are what was actually
observed on 2026-09-13.

## Hosts

| Host | Role in this audit | Hardware | OS | Xcode | Swift | Homebrew | ffmpeg | ImageMagick | Docker |
|---|---|---|---|---|---|---|---|---|---|
| local (`Mac15,3`, Apple Silicon, 24 GB) | development, baseline, all static scanning | M3-class laptop | macOS 26.6.2 (25G83) | 26.6 (17F113) | 6.3.3 (swiftlang-6.3.3.1.3) | 6.0.22 | 9.0.1 | 7.1.2-31 Q16-HDRI | available (not used) |
| `node1` (Mac Mini M2, 8 GB) | **Phase E independent verification** (fresh clone) | M2, 8 GB | 26.6.2 | 26.6 | 6.3.3 | 6.0.22 | 9.0.1 | 7.1.2-31 | installed, not used |
| `node2`, `node3`, `node4` (Mac Mini M2, 8 GB) | reserve; not used | M2, 8 GB | 26.6.2 | 26.6 | 6.3.3 | 6.0.22 | 9.0.1 | 7.1.2-31 | installed, not used |
| Debian 13 Intel VPS | **not used** — this repository has no Linux-buildable project (Swift/Xcode/Apple-platform only, see `inventory.md`) | — | — | — | — | — | — | — | — |

Fleet rule applied: at most one heavy job per Mac Mini, never Docker and Xcode concurrently.
Nothing was installed on any remote host. Phase E on `node1` uses only what was already present
(Xcode 26.6, Swift 6.3.3, Homebrew ffmpeg/imagemagick) plus a fresh clone under
`~/audit/Converter` that is removed afterwards (see the ledger for the cleanup entry).

## Tooling installed for this audit (local host, Homebrew, global)

Install command (reproducible):

```bash
brew install swiftlint periphery gitleaks trufflehog semgrep cppcheck
```

| Tool | Version | Purpose (§1 minimum coverage) | Install method |
|---|---|---|---|
| `swiftlint` | 0.65.1 | Swift linter | `brew install swiftlint` |
| `swift format` | 6.3.0 (bundled with Swift 6.3.3 toolchain) | Swift formatter | ships with Xcode 26.6 |
| Swift compiler `-warnings-as-errors`, language mode 6 | 6.3.3 | Swift type checker / strict concurrency | ships with Xcode 26.6 |
| `periphery` | 3.8.0 | Swift unused-code static analyzer | `brew install periphery` |
| `semgrep` | 1.176.0 | SAST (rulesets `p/swift`, `p/c`, `p/security-audit`, `p/secrets`) | `brew install semgrep` |
| `gitleaks` | 8.30.1 | secret scan, full git history | `brew install gitleaks` |
| `trufflehog` | 3.97.4 | secret scan, full git history (second engine) | `brew install trufflehog` |
| `cppcheck` | 2.21.0 | C++ static analyzer (bridge) | `brew install cppcheck` |
| `clang-tidy` | Homebrew LLVM 23.1.1 | C++ static analyzer (bridge), checks `bugprone-*,cert-*,clang-analyzer-*,performance-*,misc-*` | pre-existing `brew install llvm` |
| `swift build --sanitize=address` / `--sanitize=undefined` / `--sanitize=thread` | toolchain | sanitizer builds for the C++ bridge and Swift | ships with Xcode 26.6 |
| `swift test --enable-code-coverage` + `xcrun llvm-cov` | toolchain | coverage measurement | ships with Xcode 26.6 |
| `jq` | 1.8.2 | report processing | pre-existing |
| `python3` | system | report processing | ships with macOS |

### Coverage of the §1 minimum per language

| Requirement | Swift | C++ (bridge) |
|---|---|---|
| formatter | `swift format` | `clang-format` (LLVM 23.1.1, pre-existing) |
| linter | swiftlint | clang-tidy |
| static analyzer | periphery + compiler | cppcheck + clang-tidy + clang static analyzer (`clang-analyzer-*`) |
| type checker | swiftc (language mode 6, `-warnings-as-errors`) | clang `-std=c++17 -Wall -Wextra -Werror` |
| SAST | semgrep `p/swift`, `p/security-audit` | semgrep `p/c`, `p/security-audit` |
| dependency / CVE scanner | **N/A with justification**: no SwiftPM dependencies exist (no `Package.resolved`); the only vendored dependency is libbw64 0.10.0, which equals the latest upstream release and has no published CVEs (checked GitHub advisories, 2026-09-13). Runtime tools ffmpeg/ImageMagick are Homebrew-managed and outside the build; their versions are recorded above. | same |
| secret scanner over full history | gitleaks + trufflehog | same |
| sanitizer builds + memory checker | ASan/UBSan/TSan via `swift build --sanitize=…` running the test suite (macOS has no valgrind; ASan + LeakSanitizer is the memory checker used) | same (bridge is compiled into the sanitized build) |
| coverage | `swift test --enable-code-coverage` | included (llvm-cov, bridge object is instrumented) |

Python / C# / C: not present in the repository; their §1 rows do not apply.

## Commands used for the baseline (copy-paste reproducible)

```bash
# from the repository root, Sources/.build removed first
swift build --package-path Sources -Xswiftc -warnings-as-errors
swift build --package-path Sources -c release -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror
swift test  --package-path Sources --enable-code-coverage
xcrun llvm-cov report Sources/.build/debug/converterPackageTests.xctest/Contents/MacOS/converterPackageTests \
  -instr-profile Sources/.build/debug/codecov/default.profdata -ignore-filename-regex='Tests|ThirdParty|\.build'
swiftlint lint --quiet --reporter json Sources/converter Sources/Tests
semgrep scan --config p/swift --config p/c --config p/security-audit --config p/secrets --exclude .build --exclude ThirdParty Sources
gitleaks git --no-banner --redact=100 .
trufflehog git file://. --no-update
cppcheck --enable=all --std=c++17 --inline-suppr --suppress=missingIncludeSystem -I Sources/ThirdParty/libbw64 -I Sources/BW64Bridge/include Sources/BW64Bridge/bw64_bridge.cpp
clang-tidy Sources/BW64Bridge/bw64_bridge.cpp -checks='bugprone-*,cert-*,clang-analyzer-*,performance-*,misc-*,-misc-include-cleaner' -- -std=c++17 -I Sources/ThirdParty/libbw64 -I Sources/BW64Bridge/include -isysroot "$(xcrun --show-sdk-path)"
periphery scan --project-path Sources   # run only when no other SwiftPM build holds Sources/.build
```
