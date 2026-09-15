# Release and build rules — Converter

The release and build standard for this repository.

**Part 1 is generic** and identical in every Pummelchen repository. **Part 2 is this
repository's own section**, and it wins wherever the two disagree.

This file is a **generated copy** — do not edit it here. *For maintainers:* the
master is `docs/release-rules.md` in the `TinyTitan` repository, which holds Part 1
once and every repository's Part 2 side by side; edit that and run
`tools/sync-release-rules.py --apply`. An agent working in this repository should
treat this file as authoritative and does not need to leave the repository.

---

# Part 1 — Generic rules

## 1.1 Scope

These apply to any repository that produces a **runnable artifact**: a binary, a
library, an image, a package. Repositories that only hold documents, data or
configuration are out of scope, and should say so in their Part 2 section rather
than adopting a release process they cannot use.

## 1.2 Non-negotiable

1. **Apple Silicon only.** Build native `arm64`. This covers M1–M6. Never
   `--arch x86_64`, never `ARCHS=arm64 x86_64`, and never `lipo -create` — that
   is how a universal binary gets made, and there is no x86_64 build.
2. **Assert it, do not assume it.** After building, check the artifact:
   `lipo -archs <binary>` must be exactly `arm64`. A build that silently produced
   a fat binary is a release defect, not a build option.
3. **Every release carries the artifacts.** A tag alone is not a release. If the
   Release page has no binaries attached, the release did not happen.
4. **No hardcoded build-toolchain triple in a path.** `.build/release` is the
   stable spelling. `.build/arm64-apple-macosx/release` points at nothing on a
   newer toolchain and at a stale binary on this one. The one exception is a build
   that explicitly passes `--arch arm64`: then the triple directory really is
   where SwiftPM writes, and that build must also assert the arch (§1.2.2).
5. **One checksummed artifact per target, or one checksum file covering all of
   them.** Never publish a binary without a digest beside it.
6. **Dry run by default; publish only on an explicit flag.**
7. **Never fetch a model, dataset or dependency to make a gate pass.** A check
   that cannot run is reported *not checked* — and the release notes must name it.
   "Not checked, no input" and "checked and identical" are different sentences.

## 1.3 Identity

The version or build number is **single-sourced and enforced**, not maintained by
hope.

- **One authoritative value.** A file at the repository root — `VERSION` for a
  semantic version, `BUILD_NUMBER` for a build number. Anywhere else it appears
  is a **mirror**, and the build or CI must fail when a mirror disagrees.
- **Pick one scheme and state it.** Semantic versions (`vX.Y.Z`) or build numbers
  (`b1`, `b2`). Do not mix them, and do not "helpfully" introduce versions into a
  project that uses build numbers.
- **The build refuses a malformed or inconsistent identity.** Fail at configure
  or compile time, not at release time.
- **Identity is observable.** A user must be able to say what they are running
  from the artifact alone: the archive filename, or the program's own answer, or
  both.
- **Bump once, propagate mechanically.** Provide a command that writes the mirrors
  from the authoritative value. A release is one edit plus one command.
- **A second declaration in a test is a defect.** Derive the expected value from
  the source of truth; a literal in a test means every bump fails a test that is
  not about the version, and the tempting fix — editing the test — is how a wrong
  version ships.
- **Multi-library projects version in lockstep.** Libraries that ship together and
  interoperate carry the **same** version, because a caller pairing them has no
  other way to know the pair is compatible. A library with no code change is
  recompiled and republished at the new number rather than left behind.
  Lockstep applies to the **library version only** — an ABI version, protocol
  draft, or schema version is a separate axis and must not be dragged along.

## 1.4 Preconditions

Before starting, confirm and record: the OS floor and toolchain floor are met
(`sw_vers`, `swift --version`); there is disk for a clean scratch build plus the
staged archive; `memory_pressure -Q` is acceptable; **no competing build or model
process is running**; `gh auth status` is the repository owner's account; the tree
is clean; and `HEAD` **is** the tag.

**Never terminate a process you did not start.** If one is blocking, name it with
its parent and age, and stop.

## 1.5 Gates

Run these in order, and make each one **able to fail**:

1. **Lint** — the project's own lint gates.
2. **Full test suite**, serially, and it must report the count that passed.
3. **Parity or golden checks** — real inference, real rendering, real protocol
   frames; whatever "the output is unchanged" means for this project.
4. **A clean scratch build** with the log scanned for warnings.

Two traps, both of which have shipped broken gates in this organisation:

- **A gate that cannot fail is not a gate.** A guard that looks for a file the
  build never produces passes for every input. A warning scan over an *incremental*
  build compiles nothing and passes vacuously — always use a fresh scratch path.
  Before trusting a new gate, break its input and watch it fail.
- **Guard the plan, not the byproduct.** Ask the build system what it resolved
  (`swift package describe --type json`, `cmake --build ... -t help`) rather than
  checking for artifacts after the fact.

## 1.6 Packaging

The archive contains, at minimum:

- the **executables or libraries**, built for arm64;
- **resource bundles** — a Swift binary without its `.bundle` cannot load its
  Metal kernels, and this fails at runtime rather than at build time;
- `LICENSE`, and `NOTICE` / `THIRD_PARTY_NOTICES.md` where third-party code is
  redistributed;
- a **`README-binaries.txt`** stating the platform floor, that the build is
  Apple-Silicon-only, and that the binaries are **not code-signed or notarized** —
  with the quarantine command (`xattr -dr com.apple.quarantine <path>`) so a user
  who verified the checksum can run them. Do not imply a notarized build.

Name the archive `<project>[-<library>]-<version>-macos-arm64.tar.gz`; the
library segment is required only for a multi-library project, and exists so two
artifacts of the same release are distinguishable.

## 1.7 Publishing

```bash
gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sha256" \
  --repo <owner>/<repo> --title "<Project> $VERSION" \
  --notes-file "$NOTES" --latest
```

**Pin `--repo` on every `gh` call.** In a fork `gh` defaults to the *parent*
repository, so `gh release list` shows another project's releases and
`gh release create` fails with a misleading "tag has not been pushed".

## 1.8 Release notes

- Full notes in `docs/release-notes-vX.Y.md` (or the repository's equivalent),
  one section per user-visible change, each naming the check that backs it.
- End with a checksum block carrying `SHA256_PENDING` and
  `ARCHIVE_BYTES_PENDING`, substituted at publish time. **Never copy a size out
  of a dry run** — publish rebuilds, and the archive differs.
- `--publish` must **refuse** unless the notes carry the placeholder or quote the
  real value. A release quoting the wrong digest is worse than one quoting none.
- Name **every** check that did not run, and why.
- The README gets **no release callout**. It changes only when a fact it states
  changes. The changelog is the announcement.

## 1.9 After publishing

Verify the Release: the notes quote the digest in the `.sha256` beside it, the
assets are the archive and its checksum, and the changelog points at the same tag.
Leave previous releases' notes and performance tables alone.

## 1.10 Cross-repository

- **This file is the master; every repository's copy is generated from it.** The
  master is `docs/release-rules.md` in `TinyTitan`, and its
  `tools/sync-release-rules.py` splits it into Part 1 and each repository's Part 2
  and deploys the resulting `RELEASE.md` plus the `## Releasing` section of each
  `AGENTS.md`. Edit the master and run `--apply`; `--check` is the drift gate and
  exits non-zero when a committed copy no longer matches. **Never hand-edit a
  deployed copy** — the next run overwrites it.
- **Repository rules live in the master, not in shell-script comments.** A rule an
  agent cannot find is a rule that will be broken.
- **`AGENTS.md` is the one instruction file, and every harness must reach it.** This
  account works with Codex, Claude Code, DeepSeek Harness, OpenCode, Qwen Code,
  Qoder and Zed. Six read `AGENTS.md` directly; **Claude Code does not** — its
  documentation is explicit that it reads `CLAUDE.md`, not `AGENTS.md` — so every
  repository also carries a committed `CLAUDE.md` whose entire content is the
  `@AGENTS.md` import. Commit it: a symlink made on one machine is invisible to a
  fresh clone, to CI and to every other checkout, and on Windows it needs
  Administrator rights. Qwen Code reads `AGENTS.md` alongside its own `QWEN.md`, so
  there is nothing to duplicate for it.
- **Never add a file that shadows `AGENTS.md`.** Zed takes the *first match* from
  `.rules`, `.cursorrules`, `.windsurfrules`, `.clinerules`,
  `.github/copilot-instructions.md`, `AGENT.md`, and only then `AGENTS.md` — so any
  of those six silently replaces this file for every Zed user.
  `tools/sync-release-rules.py --check` fails when one appears.
- **An archived repository is read-only.** Nothing can be committed to it, so no
  release step may depend on one. Name the exclusion rather than leaving a gap.
- **A check that has never been seen to fail is not yet trusted.**

---

# Part 2 — This repository

## Converter — Swift, semantic version, 1 release

- **Identity** semantic version, `vX.Y`. `v1.0` is the only published release (`v1.0` →
  `d47025f`, 2026-09-15). The one authoritative value is the root **`VERSION`** file:
  `scripts/check-version-sync.sh` fails when the topmost `## [X.Y]` heading of
  `CHANGELOG.md` or the name of `docs/release-notes-vX.Y.md` disagrees with it, and CI
  runs that gate, so a half-done bump cannot land. The git tag `v<version>` is the third
  declaration: `scripts/release.sh` refuses to publish unless it points at `HEAD`. A
  bump is one edit to `VERSION` plus `scripts/check-version-sync.sh --write`.
- **Identity is not observable from the artifact**, which §1.3 asks for — there is no
  `--version` flag and no version constant in the Swift sources, and the asset is a bare
  `converter`. The tag and the Release page are the only way to say what is running;
  publishing the named archive below is what closes this.
- **Artifacts** a single executable `converter` plus `docs/converter.sha256`, both
  attached to the Release. This is the minimal shape and the one to bring the other
  single-binary projects to. The committed binary is **hash-gated**: a rebuild must update
  `docs/converter.sha256` *and* `docs/BINARY_PROVENANCE.md` in the same commit, or CI fails.
- **Mechanism** `scripts/release.sh` — dry run by default, `--publish` only on the flag.
  It builds in a **fresh scratch path** (so the warning scan cannot pass vacuously over an
  incremental build), asserts `lipo -archs` is exactly `arm64`, reports the digest and the
  byte count, and refuses to publish when the tree is dirty, `gh` is not the owner, the
  rebuilt binary is not the committed one, the Release already exists, an existing tag is
  not `HEAD`, or the notes carry neither the §1.8 placeholder nor the real digest and size.
- **Gates** `scripts/check-format.sh` (**the report is the gate** — `swift format
  lint` exits 0 even when it reports differences), `scripts/lint-budget.sh` (a
  ratchet against `scripts/lint-budget.json`: 151 violations, 21 error-level, pinned
  to `swiftlint` 0.65.1), `scripts/check-python.sh` (`ruff` plus `mypy --strict` over
  `AUDIT/tools`), `shasum -a 256 -c docs/converter.sha256`, the `Swift version 6.4`
  assertion, both `-warnings-as-errors` builds (the release one also carrying
  `-Xcc -Wall -Xcc -Wextra -Xcc -Werror`), and `swift test --package-path Sources` —
  **278 tests, around 11 minutes, doing real media processing**, so it is not a fast
  gate and two of them must not overlap on an 8 GB machine. `.github/workflows/ci.yml`
  runs these on the `xcode-27` image as `build-and-test` and `static-analysis`, the
  latter adding gitleaks over the full history, semgrep, cppcheck at
  `--check-level=exhaustive`, and clang-tidy requiring **zero** first-party findings.
- **Traps** a `swiftlint` version change is reported but does not fail the ratchet.
  Swift is **deliberately switched off** in this repository's CodeQL default setup
  (#0160, re-check by 2026-10-15), because the autobuild image ships Swift 6.3.3 and
  cannot parse the 6.4 manifest — do not read a green CodeQL check as Swift coverage.
  Swift 6.4's SwiftPM writes to `.build/out/Products/<config>/`, so ask
  `--show-bin-path` rather than spelling a path. The binary is thin `arm64`,
  ad-hoc/linker-signed and **not notarized**, so Gatekeeper quarantines it.
- **To bring into line** the artifact is published as a bare binary rather than a
  named archive, so it carries no `LICENSE`, no third-party notices and no
  `README-binaries.txt`. Publishing `converter-X.Y-macos-arm64.tar.gz` holding the
  binary, `LICENSE` and a `README-binaries.txt` would satisfy §1.6 without changing
  how it is used.
- **Landed for `v1.1`** the root `VERSION` file, `scripts/check-version-sync.sh` (wired
  into CI's `build-and-test`), `scripts/release.sh` and `docs/release-notes-vX.Y.md`.
  `v1.1` changed no conversion behaviour: its executable is byte-for-byte the `v1.0`
  build, so the release is the tooling and the corrected documentation. `v1.0` was cut by
  hand before any of this existed and is left as it is.
