# Phase E is outstanding — do not merge yet

The Swift 6.4 re-audit (`audit/2026-09-14`) completed Phases A–D for the tasks marked DONE in
`AUDIT/ledger.json`, but **Phase E has not run**, so §12's Definition of Complete is NOT met and no
PR to `main` may be opened.

To finish, on a host that did not develop these fixes (for example `node1`), from a fresh clone:

```bash
git clone -b audit/2026-09-14 <repo> ~/audit/Converter && cd ~/audit/Converter
swift build --package-path Sources --build-tests -Xswiftc -warnings-as-errors
swift build --package-path Sources -c release -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror
swift test  --package-path Sources --enable-code-coverage
shasum -a 256 -c docs/converter.sha256
scripts/lint-budget.sh && scripts/check-python.sh && ./scripts/check-format.sh || true   # #0106 is BLOCKED
gitleaks git --config .gitleaks.toml --no-banner --redact=100 .
trufflehog git file://. --no-update
semgrep scan --error --config p/swift --config p/c --config p/security-audit --exclude Sources/.build --exclude Sources/ThirdParty Sources
cppcheck --enable=all --error-exitcode=1 --std=c++17 --inline-suppr --suppress=missingIncludeSystem -I Sources/ThirdParty/libbw64 -I Sources/BW64Bridge/include Sources/BW64Bridge/bw64_bridge.cpp
swift test --package-path Sources --sanitize=address      # then address/undefined/thread
```

Then record the results against the twelve open tasks (`#0114`, `#0115`, `#0123`, `#0124`, `#0128`,
`#0130`, `#0131`, `#0132`, `#0133`, `#0143`, `#0144`, `#0145`) and the blocked `#0106`, and only then
open the PR.

Operational note for whoever picks this up: both clones under `~/Downloads/Converter` store a GitHub
token in their local `.git/config`; the value was surfaced in a terminal during this session and
should be rotated.
