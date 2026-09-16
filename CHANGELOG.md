# Changelog

Notable changes to `converter`. Open work is tracked in the wiki
[Audit Tracker](https://github.com/Pummelchen/Converter/wiki/Audit-Tracker), which is the only
tracker for this repository.

## [1.1] - 2026-09-16

Release and identity tooling, plus documentation corrections. **No change to conversion behaviour:
the executable is byte-for-byte the `v1.0` build.**

- The version is now single-sourced in a root `VERSION` file, with
  `scripts/check-version-sync.sh` failing when the `CHANGELOG.md` heading or the release-notes
  filename disagrees, and CI running that gate.
- `scripts/release.sh` is the release mechanism: a clean canonical build (the products are removed
  first, so the warning scan cannot pass vacuously over an incremental build), a `lipo -archs` arm64
  assertion, the digest and byte count, a dry run by default, and `--publish` refusing on a dirty
  tree, the wrong `gh` account, an existing Release, a tag that is not `HEAD`, or notes carrying
  neither the placeholder nor the real digest and size.
- The build is content-deterministic but **not bit-reproducible**: the linker's `LC_UUID` and the
  ad-hoc signature over it are regenerated on every link — measured at 85 bytes of 1 715 256 against
  the committed file, with identical section sizes — and a `swift build --scratch-path` build differs
  in size and in 17 664 bytes, because the module metadata follows the build directory.
  `release.sh` therefore builds canonically and publishes the **committed** binary, which is the
  artifact CI's checksum gate and `docs/BINARY_PROVENANCE.md` already describe.
- `docs/RELEASE_CHECKLIST.md` no longer carries a version in its title, so it is not a second place
  to bump. Release notes now live in `docs/release-notes-vX.Y.md`.
- Corrected root-level test counts, the lint budget and the release/build-path facts across
  `README.md`, `CONTRIBUTING.md`, `AGENTS.md` and `SECURITY.md`.
- CodeQL's Swift analysis remains switched off (#0160, re-check by 2026-10-15), so a green CodeQL
  check here does not mean Swift was scanned; the repository's own scanners cover it.

## [1.0] - 2026-09-16

First stable release. It is the state of the project after two pre-production audits — 162 tasks
(#0001–#0162, 161 DONE, 1 BLOCKED) — whose whole point was that a conversion should fail
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
