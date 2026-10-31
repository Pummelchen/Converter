# Converter v1.3 — release notes

Released 2026-10-31. Previous release: `v1.2`.

`-bass` is raw again: the requested cut or boost is applied literally, with no automatic headroom,
limiter or refusal. This release also carries the fixes from the post-`v1.2` code audit.

## Changed — `-bass` applies the requested gain literally

`v1.2` rendered the boost into float, measured the overshoot and attenuated the file so it could not
clip. That was correct, but not what the operator asked for. `v1.3` removes the attenuation and the
encoded-peak check entirely:

- `converter -bass 80 4` boosts exactly 4 dB below 80 Hz, even when the result reaches full scale.
- No limiter, no compression, no level correction of any kind. What you request is what is written.
- ffmpeg's own bounds are still enforced up front: frequency above 0 and at most 999999 Hz, gain
  within ±900 dB.
- The output is still verified for codec, sample rate, channels, audibility and duration; it is not
  rejected for clipping.
- **Backed by:** `testBassBoostAppliesRequestedGainWithoutAttenuation`, which proves on a deliberately
  hot source that the published file reaches full scale and keeps full-scale samples (so no hidden
  attenuation happened), and that the MP3 rendition is no longer pulled down to the old -1 dBTP
  target. A quiet source with headroom still renders normally.

## Fixed — post-`v1.2` audit

- **`-run_pix` on a JPEG.** A `.jpg`/`.jpeg` source is staged through a run-scoped temp PNG; the
  deliverables inherited that temp stem, so they were hidden and the run cleanup deleted them. They
  are named from the supplied source again. **Backed by:**
  `testRunPixOnJPEGPublishesVisibleDeliverables`, which asserts every visible deliverable exists and
  that nothing is left in the `.converter-tmp.` namespace.
- **JPEG portrait artwork.** The full run accepts a discovered portrait as `.png`/`.jpg`/`.jpeg` and
  classifies it by displayed orientation, but the still step demanded PNG. It now uses the general
  image preflight. **Backed by:** `testPortraitShortStillsAcceptJPEGSource`.
- **Output collisions.** `--output-file` for `-m4atomp4` and `-short`, and the album output, are now
  refused when they resolve to a render input; the distinct-path guard also resolves symlink aliases,
  so a linked source/output directory cannot overwrite its own source. **Backed by:**
  `testAlbumRefusesOutputOverAnInputTrack` and
  `testRequireDistinctOutputResolvesSymlinkAliases`.
- **Mixed encoder ladders.** Each rung is tagged for its own codec (`avc1` for H.264, `hvc1`/`hev1`
  for HEVC); `-tag:v hvc1` on an H.264 fallback is rejected by ffmpeg and made the fallback
  unusable. **Backed by:** `testVideoTagFollowsEncoderFamily`.
- **Video colour.** RGB→YUV conversion now names the tagged matrix and range
  (`out_color_matrix=bt709:out_range=tv`) on the scale filter. `setparams` only writes metadata, so
  the pixels used to be converted with swscale's BT.601 default while the file was tagged BT.709.
- **Colour range and case-sensitive tokens.** `VIDEO_COLOR_RANGE=limited`/`full` is stored as the
  `tv`/`pc` value ffprobe reports, and `WAV_CODEC`, `VIDEO_MP4_SCALE_FILTER` and
  `VIDEO_MP4_PIXEL_FORMAT` are lowercased so a case-insensitive validation cannot pass a value the
  encoder rejects. **Backed by:** `testConfigCanonicalisesCaseAndRangeAliases`.
- **Duration hardening.** A non-finite duration no longer traps a `UInt64` estimate or passes a
  `NaN > tolerance` comparison; it is rejected as an unreadable duration.
- **Capture and launch hardening.** A truncated pipe capture is trimmed to a UTF-8 scalar boundary so
  its diagnostic survives, and an executable lookup now requires a regular file (a searchable
  directory in `PATH` no longer passes as a tool).
- **Loudness QC.** A render whose integrated loudness cannot be measured (`-inf` or a missing
  loudnorm field) now fails the floor instead of skipping it, and the preservation comparison no
  longer substitutes a peak comparison when only the output lost its loudness measurement.
- **`-clean`.** Cleaning no longer requires ffmpeg/ffprobe/magick; it needs only the output
  directory. **Backed by:** `testCleanDoesNotRequireRuntimeDependencyBootstrap`.
- The committed `converter` binary was regenerated for these changes.

## Note — the build is still not bit-reproducible

The linker's `LC_UUID` and the ad-hoc signature over it are regenerated on every link, so a rebuild
of the same sources does not reproduce the committed hash. `scripts/release.sh` builds in the
canonical location and publishes the **committed** binary; `docs/converter.sha256` pins the file and
`docs/BINARY_PROVENANCE.md` records its source, toolchain and build command.

## Checks that did not run

- **The manual smoke test on real media was not run** (`-full` on a production master). It needs
  non-private source material and an operator; `docs/RELEASE_CHECKLIST.md` keeps it as an owner step.
- **The clean-machine auto-install path was not run** (`CONVERTER_AUTO_INSTALL_DEPS=1`), for the same
  reason.
- **The static-analysis scanners were not run locally** — `gitleaks`, `semgrep`, `cppcheck` and
  `clang-tidy` are CI jobs; no result is claimed for them here.
- **The GitHub Actions jobs on the release commit had not run when these notes were written.** The
  `xcode-27` jobs are reported separately once they complete; every check they perform that could be
  reproduced locally was run and is listed above.
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
