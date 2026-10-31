# Converter v1.2 — release notes

Released 2026-10-31. Previous release: `v1.1`.

`-bass` is no longer a trap: a boost that would drive the 24-bit staging WAV past full scale is
attenuated by exactly the overshoot instead of failing the run or baking clipping into the
deliverable. The toolchain standard is now Swift 6.4.2 / Xcode 27.2.

## Changed — `-bass` protects headroom

`converter -bass 80 4` on a master that already peaks near 0 dBFS used to render the boost, discover
that thousands of samples had been forced to full scale, and fail with an error that told the
operator to lower the source. The reverse is now the behaviour: the boost is rendered into a float
WAV (where it cannot clip), its sample peak is measured, and the file is attenuated by exactly the
overshoot before the 24-bit staging pass.

- **Lossless outputs** (`wav`, `flac`) land at **-0.1 dBFS** sample peak.
- **Lossy outputs** (`mp3`, `m4a`, `mp4`) target **-1 dBTP**, because those encoders can overshoot
  between samples; the check is made on the true peak, not the sample peak.
- The boost curve is untouched. Only a linear gain moves, so nothing is limited or compressed and
  no pumping or colouration is introduced.
- One `[INFO]` line reports the measured peak and the applied attenuation; a boost that already
  fits is staged unchanged.
- **Backed by:** `testBassBoostAppliesHeadroomInsteadOfClipping`, which asserts **0 full-scale
  samples** on both a hot WAV and a hot MP3, a WAV peak at or below -0.05 dBFS, and an MP3 true peak
  at or below -0.5 dBTP. The full suite (278 tests) passes.

## Changed — one error line per failure

`processBatch` logged a failure and then rethrew it, and the top-level handler logged it again, so a
failed action printed the same `[ERROR]` twice. The fail-fast path now rethrows without logging and
lets the top-level handler report once; `--continue-on-error` still logs each failure as it happens
and ends with the familiar `n operation(s) failed.` summary. **Backed by:** the existing
`--continue-on-error` and fail-fast integration tests, both unchanged and passing.

## Changed — Swift 6.4.2 / Xcode 27.2

The recorded standard moves from Swift 6.4.0 / Xcode 27.0 to the 6.4.2 toolchain that ships with
Xcode 27.2. The package still declares `swift-tools-version: 6.4` and CI still gates the 6.4 line, so
a patch move inside 6.4 does not fail it.

The audit adopted the one supported upcoming feature that was still applicable:

- **`NonisolatedNonsendingByDefault`** (with explicit `@concurrent`). A `nonisolated` async function
  now runs on its caller's actor. The scheduler relies on blocking ffmpeg/magick work leaving the
  caller's executor, so `ConverterMain.run`, `ConverterTool.execute`, the full/album/runpix steps,
  the fan-out pipelines and `AsyncSemaphore.withPermit`'s operation are marked `@concurrent`.
  Without that, permitted work would serialise on the semaphore actor's executor.
- **Not adopted, with reasons recorded:** `InternalImportsByDefault` (an executable exports no API)
  and `StrictMemorySafety` (flags `String(format:)` calls rather than real memory unsafety). `Span`/
  `RawSpan`, `InlineArray` and `borrow`/`mutate` accessors were evaluated and have no better site in
  this code than the current code.

**Backed by:** the debug build with `-warnings-as-errors`, the strict release build
(`-Wall -Wextra -Werror`), and the full suite — 278 tests, 0 failures (792 s) on the recorded
toolchain. The environment and the audit are written up in `docs/KNOWN_GOOD_VERSIONS.md`.

## Note — the build is still not bit-reproducible

The linker's `LC_UUID` and the ad-hoc signature over it are regenerated on every link, so a rebuild
of the same sources does not reproduce the committed hash. `scripts/release.sh` therefore builds in
the canonical location and publishes the **committed** binary; `docs/converter.sha256` pins the file,
and `docs/BINARY_PROVENANCE.md` records its source, toolchain and build command.

Because `v1.2` changes behaviour, this is the first release since `v1.0` with a different executable.
`v1.1`'s artifact was byte-for-byte `v1.0`'s; this one is not.

## Checks that did not run

- **The manual smoke test on real media was not run** (`-full` on a production master). It needs
  non-private source material and an operator; `docs/RELEASE_CHECKLIST.md` keeps it as an owner step.
- **The clean-machine auto-install path was not run** (`CONVERTER_AUTO_INSTALL_DEPS=1`), for the same
  reason.
- **The static-analysis scanners were not run locally** — `gitleaks`, `semgrep`, `cppcheck` and
  `clang-tidy` are CI jobs; no result is claimed for them here.
- **The GitHub Actions jobs on the release commit had not run when these notes were written.** The
  `xcode-27` jobs are reported separately once they complete; every check they perform was run
  locally instead and is listed above, except those named in this section.
- **CodeQL's Swift analysis remains off** (#0160): GitHub's autobuild image ships Swift 6.3.3 and
  cannot parse this package's Swift 6.4 manifest, so a green CodeQL run does **not** mean Swift was
  scanned.

## Checksums

- File: `converter`
- SHA-256: `SHA256_PENDING`
- Bytes: `ARCHIVE_BYTES_PENDING`

```bash
shasum -a 256 -c converter.sha256
```
