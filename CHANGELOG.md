# Changelog

Notable changes to `converter`. The audit ledger behind these entries is
[`AUDIT/ledger.json`](AUDIT/ledger.json) (mirrored to the wiki tracker); every task names its evidence,
its commit and the host that verified it.

## [1.0] - 2026-09-16

First stable release. It is the state of the project after two pre-production audits — 161 tasks
(#0001–#0161, 160 DONE, 1 open watch item) — whose whole point was that a conversion should fail
loudly rather than publish something wrong.

### Toolchain

- Swift 6.4 / Xcode 27, Swift language mode 6, `swift-tools-version: 6.4`, built with
  `-warnings-as-errors`; the C++ BW64 bridge also builds under `-Wall -Wextra -Werror`.
- The Swift layout is owned by `swift format` (`.swift-format`, enforced by `scripts/check-format.sh`
  and a blocking CI step); `swiftlint` keeps the rule gate with a recorded ratchet that fell from
  461 to 151 violations during the audit. The audit tooling under `AUDIT/tools` is `ruff`-clean and
  `mypy --strict`.
- CI runs on the `xcode-27` image: checksum, lint budget, formatter, Python checks, gitleaks over the
  full history, semgrep, cppcheck (exhaustive), clang-tidy, both builds and the suite.

### Fixed

- **A source file can no longer be overwritten by its own render.** `-aipix`/`-runpix` on a master
  already named `<prefix>_8K.png` resolved that file as its output, re-rendered it and deleted the
  backup, destroying the original. Every image publish site now refuses `output == source`, as the
  audio converters already did.
- **The delivered files are verified against the QC ceilings the operator configures.** The M4A, the
  MP3 and the main 8K MP4 were published with no absolute audio QC beyond loudness drift and
  audibility; they now take the delivery policy rebased to the source, so an encode is rejected for
  what it *added* — clipping, DC offset, channel imbalance, true peak.
- **A hung child can no longer stall a finished command.** The success path drained stdout/stderr
  without a deadline, so a grandchild holding the pipe hung the run after the child had exited.
- **Cancelling one operation stops only its own work.** A cancelled fan-out branch used to SIGTERM
  every live child of the shared runner, failing unrelated branches with a misleading
  "killed by signal 15".
- **Audio actions measure the audio stream, not the container.** An MP4/MOV whose video outlasted its
  audio was rejected with a misleading duration mismatch.
- **Verification gaps that could pass by default**: canonical-PCM equivalence on two empty decodes,
  padding probes too small to measure, a no-op fade, FLAC bit depth following the source instead of
  the archival standard, and reuse that never checked whether the source had changed.
- **A standard-conforming MP3 with ID3 artwork is copied byte for byte** instead of being re-encoded
  into a second lossy generation.
- **File-safety hardening**: run-scoped temps created with `O_EXCL|O_NOFOLLOW`, destination
  permissions preserved on publish, backup recovery that restores rather than deletes after a
  partial replace.
- **Input validation**: filter-graph config values must be bare tokens, an explicitly named config
  file that does not exist is an error, out-of-range `--sleep-seconds` and `--num-dots` are rejected,
  action-scoped options are rejected by actions that cannot consume them.
- **The entry point is testable and no longer resolves itself against the caller's directory**, so a
  `converter` found on `PATH` does not read `config.txt` or write `Output` in whatever directory you
  happened to be in.

### Security

- gitleaks over the full history reports nothing; the one historical hit is a documented false
  positive (a config-key *name* beside a parameter label) with a narrow, commented exception in
  `.gitleaks.toml` that never excludes a file or a commit. Trufflehog, semgrep and cppcheck report
  nothing; clang-tidy reports nothing in first-party code.
- The auto-install path downloads the Homebrew installer from a pinned commit and refuses to execute
  it unless the SHA-256 matches.

### Verified

- 278 tests, 0 failures, 0 skipped, 0 compiler warnings; coverage 86.99 % of lines / 81.06 % of
  regions / 84.67 % of functions.
- Phase E ran from a fresh clone on a machine that did not develop the fixes: clean debug and strict
  release builds, committed-binary checksum, every scanner, the full suite, and a `-help`/`-matrix`/
  `-doctor` smoke test.
- The bundled `converter` binary is rebuilt from this release's commit; size, toolchain, source
  commit and SHA-256 are recorded in [`docs/BINARY_PROVENANCE.md`](docs/BINARY_PROVENANCE.md) and
  checked by CI.

### Known

- Re-enabling CodeQL's Swift analysis is tracked as an open watch item (#0160): GitHub's CodeQL
  default setup autobuilds with Swift 6.3.3, which cannot parse a 6.4 manifest, so Swift is switched
  off there until that image moves. CodeQL still covers actions, C/C++ and Python, and the
  repository's own scanners cover Swift.
