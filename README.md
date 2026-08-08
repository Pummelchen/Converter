# Converter

Swift-based media converter and YouTube studio production pipeline for macOS Apple Silicon.

## Quick start

```bash
git clone https://github.com/Pummelchen/Converter.git
cd Converter
brew install ffmpeg imagemagick            # runtime media tools
swift build --package-path Sources         # build
swift test --package-path Sources          # full test suite (129 tests, ~9 min)

CONVERTER_AUTO_INSTALL_DEPS=0 ./converter -doctor   # dependency check without install side effects
./converter -help                                    # command reference
```

First media run: place exactly 1 source audio (`.flac`/`.wav`/`.mp3`) and 1 source image in `Output/`, then run `./converter -full`. `Output/` is both the default input and output directory — discovery is non-recursive, files in subfolders are ignored, and the directory is meant to be cleaned manually between runs. See [CONTRIBUTING.md](./CONTRIBUTING.md) for contribution guidance and [docs/](./docs/) for format reference, known-good toolchain versions, and the release checklist.

## Layout
- `Sources/` Swift package, tests, bundled third-party code, and the in-process BW64 bridge
- `Sources/converter/PipelineCore.swift` base runtime, temp/publish, probes, caching, scheduling
- `Sources/converter/ValidationPipeline.swift` media identity, QC, preflight, verification
- `Sources/converter/ImagePipeline.swift` image conversions and derivative generation
- `Sources/converter/AudioPipeline.swift` audio conversions, mastering, archives, hashing, album builds
- `Sources/converter/LosslessAudioPipeline.swift` internal RF64 WAV staging and lossless/archive encodes
- `Sources/converter/QualityReporting.swift` audio QC policy, metrics, and result types
- `Sources/converter/Diagnostics.swift` ffmpeg encoder/filter capability checks
- `Sources/converter/VideoPipeline.swift` MP4 render and short-video render with encoder fallback
- `Output/` working directory for source inputs and generated outputs
- `config.txt` centralized quality, profile, mastering, and render policy settings
- `album.txt` album ordering input read by `-wavtoalbum` and `-mp3toalbum`
- `converter` prebuilt macOS Apple Silicon release binary

## Build
Requires Swift tools 6.3.3 or newer compatible Xcode command line tools. The package declares Swift language mode 6 and macOS 14+.

```bash
swift build --package-path Sources -c release
cp Sources/.build/arm64-apple-macosx/release/converter ./converter
chmod +x ./converter
```

## Test
```bash
swift test --package-path Sources
```

## Continuous Integration
Pushes and pull requests to `main` run the Swift build and the full test suite on GitHub Actions (`macos-26` with Swift 6.3.3, installing `ffmpeg` and `imagemagick` first). See [`.github/workflows/ci.yml`](./.github/workflows/ci.yml).

## Runtime Dependencies
On startup, operational commands auto-check the required external tools and silently install missing Homebrew formulae before media processing starts.

Homebrew formulae:
- `ffmpeg`, which provides `ffmpeg` and `ffprobe`
- `imagemagick`, which provides `magick`

macOS system commands:
- `awk`
- `sed`

Python packages:
- none

If Homebrew itself is missing and a required formula must be installed, converter attempts a non-interactive Homebrew install first. Set `CONVERTER_AUTO_INSTALL_DEPS=0` to disable auto-install and fail fast instead.

## Core Commands
```bash
./converter -help
./converter -doctor
./converter
./converter -full
./converter -album
./converter -matrix
./converter -bass
./converter -bass 80 5
./converter -bass 80 -5
./converter -loudscan
./converter -loudness
./converter -loudness -13
./converter -fade 10
./converter -fadecut 5 10
./converter -fadeout 1:30 10
./converter -noise
./converter -noise 45
./converter -silence
./converter -silence 45
./converter -short
./converter -nfttoshort
./converter -mp3clean
./converter -m4atomp4
./converter -mp4toshort
./converter -run_pix
./converter -visualsubs 9 --output-file dots.png
./converter -clean
./converter -list
```

Format-conversion commands (`-flactowav`, `-flactomp3`, `-flactom4a`, `-flactoalbum`, `-flactohash`, `-m4atowav`, `-m4atomp3`, `-m4atoflac`, `-mp3toflac`, `-mp3towav`, `-mp3tom4a`, `-mp3toalbum`, `-wavtoflac`, `-wavtomp3`, `-wavtom4a`) and the image-action matrix are listed in [docs/FORMATS.md](./docs/FORMATS.md).

Short outputs are hard-capped at 58 seconds.
Use `-short` to render one portrait short MP4 from exactly 1 image (`.png`/`.jpg`/`.jpeg`) plus exactly 1 audio-only file supported by ffmpeg in `Output/`; the image is fitted into the portrait frame as large as possible with black padding.
For `-nfttoshort`, the short render accepts any single audio-only file supported by ffmpeg and uses `Vertical_8K.png` when present. Otherwise it uses or creates `*_NFT8K.png`, centers that square image in the portrait frame, and fills the remaining top and bottom space with black.
When the source audio is longer than the 58-second cap, `-short` and `-nfttoshort` additionally render a full-length companion with the same portrait graphics — `<stem>_8K_Short_FullSong.mp4` — so long-form uploads keep the entire song.
Conversions preserve source loudness by default instead of remastering it down during normal pipeline work, including `-short` and `-nfttoshort`.

Running `./converter` without parameters prints help and does not start media processing. Use `./converter -full` or `./converter -run` for the full production pipeline.

`./converter -album` is the album version of the full production run. It scans `Output/` for `.mp3`, `.wav`, and `.flac` tracks, sorts them in natural numeric filename order, loudness-normalizes each track to `-12 LUFS`, builds one RF64 `album.wav`, then continues through the same full-run image, MP4, and short-render pipeline.

Album commands differ in input discovery: `-album` and `-flactoalbum` scan `Output/` directly (natural numeric order), while `-wavtoalbum` and `-mp3toalbum` read the track list from `album.txt` in the project root (entries resolve directly inside `Output/`; `#` comments and missing tracks are skipped with a warning). Only `-album` loudness-normalizes tracks before joining; the `album.txt`-based commands concatenate in listed order without normalization. See [docs/FORMATS.md](./docs/FORMATS.md) for the full command-to-format reference.

## Audio Standards
All converter audio paths stage through an internal WAV before delivery encoding. The internal working WAV standard is fixed at 32-bit float, 192 kHz, stereo (`pcm_f32le`, RF64 WAV).

Delivery audio standards:
- MP4 audio: ALAC, 24-bit, 48 kHz, stereo
- M4A audio: ALAC, 24-bit, 48 kHz, stereo
- MP3 audio: 320 kbps, 48 kHz, stereo

MP4/M4A delivery paths do not stream-copy AAC and do not use AAC bitrate settings. The legacy bitrate keys in `config.txt` are kept for compatibility but are set to `lossless` and ignored by ALAC encodes.

## Hash Rename
Use `./converter --hash` to rename `.wav`, `.flac`, `.mp3`, and `.mp4` files in `Output/` to CRC32-based filenames after media preflight.

## Bass Adjustment
Use `./converter -bass` to create same-format `_bass` copies for `.flac`, `.wav`, `.mp3`, `.m4a`, and `.mp4` files in `Output/`. The default boosts bass around 80 Hz by 5 dB. Use `./converter -bass 80 5` to boost manually, or `./converter -bass 80 -5` to reduce the 0-80 Hz range by 5 dB. Non-default settings use a settings-specific suffix such as `_bass_60Hz_7_5dB` or `_bass_80Hz_m5dB`.

## Loudness
Use `./converter -loudscan` to measure supported audio media in `Output/`. Long scans stream progress as `current/total` files measured and reprint the current four-line report after each file: average loudness, lowest loudness, highest loudness, and the average of the three loudest files.

Project-wide delivery, short-form, and mastering/remediation defaults target `-12 LUFS` for modern music uploads, including audio-only outputs and audio streams inside MP4/M4A deliverables.

Use `./converter -loudness` to create same-format loudness-normalized copies for `.flac`, `.wav`, `.mp3`, `.m4a`, and `.mp4` files. Pass a value such as `./converter -loudness -13` for a more dynamic target. Targets must stay inside FFmpeg loudnorm's supported `-70` to `-5 LUFS` range. Outputs are tagged with the target, for example `_loudness_m12LUFS`, so livestream-ready files do not overwrite sources or collide with another target.

Loudness normalization targets whole-track integrated LUFS, not constant moment-to-moment volume. Rendering uses one static gain value only: no EQ, no limiter, no dynamic loudnorm render, and no compression. If a source has high peaks and a low integrated average, the converter caps positive gain at available peak headroom and may warn that the output is peak-constrained instead of damaging the musical dynamics to force the exact target.

## Noise Padding
Use `./converter -noise [SECONDS]` to add random-noise lead-in and tail padding to `.flac`, `.wav`, `.mp3`, `.m4a`, and `.mp4` files in `Output/`. When `SECONDS` is omitted, the default is 30 seconds. The generated noise sections are normalized to `-12 LUFS`, with a fixed 2-second silence gap before and after the original media.

Example:
```bash
./converter -noise
./converter -noise 45
```

That writes same-format files such as `song_noise_30s.flac`, `song_noise_30s.wav`, `song_noise_30s.mp3`, `song_noise_30s.m4a`, or `video_noise_30s.mp4`. The audio layout is `noise -> 2s silence -> original media -> 2s silence -> noise`. WAV outputs remain RF64 `pcm_f32le`; compressed/lossless outputs are re-encoded to the project quality settings. MP4 outputs keep video present by extending first and last frames while the audio receives matching leading and trailing noise plus the silent transitions.

## Silence Padding
Use `./converter -silence [SECONDS]` to add silent lead-in and tail padding to `.wav`, `.flac`, and `.mp4` files in `Output/`. When `SECONDS` is omitted, the default is 30 seconds.

Example:
```bash
./converter -silence
./converter -silence 45
```

That writes same-format files such as `song_silence_30s.wav`, `song_silence_30s.flac`, or `video_silence_30s.mp4`. WAV outputs remain RF64 `pcm_f32le`; FLAC and MP4 outputs are re-encoded to the project quality settings. MP4 outputs keep video present by extending first and last frames while the audio receives matching leading and trailing silence.

## Profiles
Built-in profiles:
- `youtube_master`
- `youtube_short`
- `archive`
- `fast_preview`

Use them with:
```bash
./converter --profile youtube_master
./converter --profile fast_preview -doctor
```

`PROFILE=` in `config.txt` sets the default profile. File and environment overrides still apply after the profile overlay.

## Full Run Contract
Place these inputs in `Output/`:
- either exactly 1 source image: `.png` preferred, `.jpg` and `.jpeg` also accepted
- or direct 8K PNG inputs: `Horizontal_8K.png` for the main MP4 and optional `Vertical_8K.png` for the short MP4
- exactly 1 source audio file: `.flac`, `.wav`, or `.mp3`

Then run:
```bash
./converter -full
```

When both `Horizontal_8K.png` and `Vertical_8K.png` are present, full run renders the main MP4 first from `Horizontal_8K.png`, then renders the short MP4 directly from `Vertical_8K.png`. When `Vertical_8K.png` is absent, the short MP4 uses or creates `*_NFT8K.png`, centers it in the portrait frame, and pads the top and bottom with black.

Full run produces:
- image deliverables: 8K/4K PNG, NFT PNGs, 3K/2K PNG, JPG exports
- audio deliverables: WAV, M4A, MP3
- archival deliverables: `*_RF64.flac`, `*_RF64.wav`, `*_BW64.flac`, `*_BW64.wav`
- video deliverables: main MP4, short MP4, and full-song short MP4 (same portrait graphics as the short MP4; rendered only when the source audio is longer than the short clip cap)

## Reliability Features
- deep media identity checks for PNG/JPG/JPEG/WAV/FLAC/MP3/M4A/MP4
- canonical PCM equivalence verification for lossless/archive outputs
- optional mastering/remediation on the canonical WAV before delivery encodes
- encoder fallback ladders for main and short video rendering
- run-local probe/QC caching to avoid redundant ffprobe/magick/audio analysis work
- bounded scheduler with separate image/audio/video limits
- integrated BW64 writing inside the main binary

## Fadeout
Use `-fade [SECONDS]` to create full-length same-format tail-faded files from `.flac`, `.wav`, and `.mp3` sources in `Output/`.
When `SECONDS` is omitted, the converter fades the final 10 seconds. `-fadeflac` is accepted as a compatibility alias for `-fade` so old calls no longer fall through to the full pipeline.

Example:
```bash
./converter -fade 5
```

That uses a normal fade over the final 5 seconds and writes new files with the `_faded` suffix:
- `.flac -> *_faded.flac`
- `.wav -> *_faded.wav`
- `.mp3 -> *_faded.mp3`

Use `-fadecut CUT_SECONDS FADE_SECONDS` to remove time from the end first, then apply a normal fade to the new tail.

Example:
```bash
./converter -fadecut 5 10
```

That removes the final 5 seconds, fades the final 10 seconds of the shortened file, and writes:
- `.flac -> *_fadecut.flac`
- `.wav -> *_fadecut.wav`
- `.mp3 -> *_fadecut.mp3`

Use `-fadeout START DURATION` to create truncated same-format fadeout files from supported audio sources in `Output/`.

Example:
```bash
./converter -fadeout 1:30 10
```

That starts fading at `1:30`, reaches silence at `1:40`, truncates there, and writes new files with the `_faded` suffix:
- `.flac -> *_faded.flac`
- `.wav -> *_faded.wav`
- `.mp3 -> *_faded.mp3`
- `.m4a -> *_faded.m4a`

## Notes
- media inputs are auto-discovered from `Output/` by default
- source discovery is non-recursive; files inside subfolders of `Output/` are ignored
- explicit output names and album entries must also resolve directly inside `Output/`, not a subfolder
- `Output/` is intended as a manually cleaned working directory between runs
- `Sources/.build/` remains ignored by Git
