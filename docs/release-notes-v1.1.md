# Converter v1.1 — release notes

Released 2026-09-16. Previous release: `v1.0`.

**This release changes no conversion behaviour.** The executable is byte-for-byte the same build as
`v1.0`; `v1.1` carries the release and identity tooling that `RELEASE.md` requires, plus
documentation corrections. If you only want the converter, `v1.0`'s artifact and this one are
identical — verify with the checksum block at the end.

## Added — a single source for the version

- `VERSION` at the repository root is now the one authoritative value, and
  `scripts/check-version-sync.sh` fails when a mirror disagrees: the topmost `## [X.Y]` heading of
  `CHANGELOG.md`, and the name of this file. **Backed by:** the gate runs in CI's `static-analysis`
  job and is exercised by `scripts/release.sh`, which refuses to build when it fails.
- The gate was confirmed able to fail before it was trusted — pointing `VERSION` at a version with
  no matching changelog heading and no notes file makes it exit 1, and CI reports
  `::error::CHANGELOG.md's current heading is …`.

## Added — a release script

- `scripts/release.sh` builds the release, asserts the artifact is `arm64` and only `arm64`
  (`lipo -archs`), reports the digest and size, and publishes only on an explicit `--publish`
  (§1.2.6). It refuses when the tree is dirty, when `gh` is not the repository owner, when the
  rebuilt binary is not the committed one, when the release already exists, when an existing tag
  points somewhere other than `HEAD`, and when the notes carry neither the placeholder nor the real
  digest and size. **Backed by:** the script's own preconditions, and a dry run before any tag.
- The build runs in a **fresh scratch path**, so the warning scan cannot pass vacuously over an
  incremental build (§1.5).

## Changed — documentation

- `docs/RELEASE_CHECKLIST.md` is now version-agnostic (it was titled for one release), so it does
  not become a second place to bump.
- Root-level test counts, the lint budget and the release/build-path facts corrected in `README.md`,
  `CONTRIBUTING.md`, `AGENTS.md`, `SECURITY.md` and `CHANGELOG.md`. **Backed by:**
  `scripts/lint-budget.sh` and the suites recorded in `docs/KNOWN_GOOD_VERSIONS.md`.
- `AGENTS.md` and `RELEASE.md` now carry the account-wide release and build rules.

## Note — the build is not bit-reproducible

Two builds of the same source produce the same size and the same code, but not the same bytes: the
linker's `LC_UUID` is regenerated on every link, and the ad-hoc signature covers it. Measured against
the committed binary, a clean canonical rebuild differed in **85 bytes of 1 715 256**, with identical
section sizes. A `--scratch-path` build differs far more — in size and in 17 664 bytes — because the
module metadata follows the build directory, which is why `scripts/release.sh` builds in the
canonical location and publishes the **committed** binary.

The consequence is worth stating plainly: the checksum pins *the file*, not the sources. The
published artifact is the same bytes as `v1.0`'s; a rebuild of the same sources will not reproduce
that hash. Verified with `cmp -l`, `otool -l LC_UUID` and `codesign -dvvv` on both files.

## Checks that did not run

- **CodeQL's Swift analysis is still switched off** (#0160). GitHub's default-setup runner
  autobuilds with Swift 6.3.3, which cannot parse this package's Swift 6.4 manifest, so the Swift
  language is disabled rather than left silently analysing nothing. Re-check by 2026-10-15. A green
  CodeQL check on this repository therefore does **not** mean Swift was scanned; the repository's own
  `gitleaks`, `semgrep`, `cppcheck` and `clang-tidy` gates carry that.
- **The manual smoke test on real media was not run.** It needs non-private source material and an
  operator; `docs/RELEASE_CHECKLIST.md` keeps it as an owner step.
- **The clean-machine auto-install path was not run** (`CONVERTER_AUTO_INSTALL_DEPS=1`), for the same
  reason.
- **The GitHub Actions jobs on the release commit had not run.** Every job that needs the
  `xcode-27` image was still queued when this release was cut — jobs on that image have been
  waiting for hours, which is a runner-capacity problem on GitHub's side, not a failure. **Not
  checked, therefore**, and no CI result is claimed. Every check those jobs perform was run
  locally on the release commit instead and is reported above: the formatter, the lint budget, the
  Python checks, the version gate, the checksum, `gitleaks` over all 343 commits, `semgrep`,
  `cppcheck`, `clang-tidy`, the `-warnings-as-errors` debug build, the strict release build, the
  serial suite (278 tests) and the `lipo -archs` assertion. The only jobs that did run were the
  `ubuntu-latest` CodeQL analyses, which passed.

## Checksums

- File: `converter`
- SHA-256: `SHA256_PENDING`
- Bytes: `ARCHIVE_BYTES_PENDING`

```bash
shasum -a 256 -c converter.sha256
```
