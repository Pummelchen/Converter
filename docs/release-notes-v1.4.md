# Converter v1.4 — release notes

Released 2026-10-31. Previous release: `v1.3`.

Preserve-loudness renders now carry the operator's audio without re-applying a delivery policy, and
video audio is muxed untouched. This release also fixes audio truncation in rendered videos and
records the repository rule that agents no longer run the full test suite.

## Changed — preserve-loudness renders are not delivery-QC targets

The M4A, MP3, main MP4 and every portrait short are faithful copies of the supplied audio, so they
are no longer judged against delivery ceilings. The source-relative rebase and its
`Source already exceeds delivery QC` log are removed:

- Material that already peaks above `AUDIO_QC_MAX_TRUE_PEAK_DBTP` or contains full-scale samples
  publishes instead of failing an encode that changed nothing.
- Codec, sample rate, channels, audibility, duration and `verifySourceLoudnessPreserved` are still
  enforced. A silent render or a render whose loudness drifted still fails.
- `-master` and `-loudness` remain the only actions that alter the audio, and they keep their
  mastering/normalization policies.

**Backed by:** `testShortFromHotMP3IsNotRejectedForClippedSamplesItInherits` and
`testNFTToShortPreservesSourceLoudnessOnPortraitPath`, which publish from deliberately hot sources,
and the conversion-matrix test, which still verifies every M4A/MP3 output structurally and for
audibility, duration and loudness.

## Changed — video audio is muxed untouched

`-m4atomp4`, `-short`, `-nfttoshort` and `-mp4toshort` no longer detour through the internal 96 kHz
WAV:

- A project-standard ALAC stream (24-bit, 48 kHz, stereo) is stream-copied bit-for-bit.
- Any other source is decoded and encoded directly into ALAC at the delivery rate, with no
  intermediate resample round trip.
- `-shortest` is gone from the video render tail; every path caps explicitly with `-t`.

**Backed by:** `testVideoRenderStreamCopiesAnAlreadyStandardALACSource`, which now compares the
decoded canonical PCM of the source and the rendered MP4 sample-for-sample and requires them to be
identical.

## Fixed — truncated audio in rendered videos

`-shortest` combined with `-t` dropped whole compressed audio packets. A 12 s ALAC source produced
an 11.43 s audio track; a 1 s source produced 0.43 s. The video looked correct, so only a
sample-level check caught it. Each render path now caps with `-t` alone and the audio track matches
the source exactly.

**Backed by:** the canonical-PCM equivalence check above, plus the short/full-song duration tests
(`testShortBuildsLongSongFullSongVariant`, `testShortVideoHardCapsAt58SecondsEvenIfConfigRequestsMore`).

## Repository rule — full test-suite runs are prohibited for agents

A full `swift test --package-path Sources` run is no longer permitted for agents: it does not find
bugs and does not solve reported problems. Local validation uses the targeted `--filter` tests that
cover the change, plus `scripts/check-format.sh` and `scripts/lint-budget.sh`. CI may still run the
suite.

**Backed by:** the committed rule in `AGENTS.md`.

## Checks that ran

- `scripts/check-version-sync.sh` — version, changelog heading and release-notes filename agree.
- `scripts/check-format.sh` — clean.
- `scripts/lint-budget.sh` — 149 violations (21 error-level), within the recorded 151/21 budget.
- Clean canonical release build with `-warnings-as-errors` and C `-Wall -Wextra -Werror` — success,
  no compiler warnings.
- `lipo -archs` — exactly `arm64`.
- `shasum -a 256 -c docs/converter.sha256` — committed binary matches.
- Targeted tests covering the changed paths — 0 failures (video mux, stream-copy equivalence, hot
  source publishing, short/full-song durations, audio conversion matrix, loudness actions).
- `./converter -doctor` — pass.
- End-to-end hot-source run with the release binary: clipped ALAC → `-m4atomp4`, hot WAV →
  `-wavtom4a` and `-wavtomp3`; all succeeded with no source-relative QC line.

## Checks that did not run

- **The full test suite did not run.** `AGENTS.md` prohibits full-suite runs; only targeted tests
  were run. CI's `build-and-test` job may run the suite on the release commit.
- **The manual smoke test on production media did not run** (`-full` on a real master). It needs
  non-private source material and an operator; `docs/RELEASE_CHECKLIST.md` keeps it as an owner step.
- **The clean-machine auto-install path did not run** (`CONVERTER_AUTO_INSTALL_DEPS=1`).
- **The static-analysis scanners did not run locally** — `gitleaks`, `semgrep`, `cppcheck` and
  `clang-tidy` are CI jobs; no result is claimed for them here.
- **The GitHub Actions jobs on the release commit had not run when these notes were written.**
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
