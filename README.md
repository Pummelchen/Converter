# Converter

Swift-based media converter and YouTube studio production pipeline for macOS Apple Silicon.

## Layout
- `Sources/` Swift package, tests, bundled third-party code, and the in-process BW64 bridge
- `Sources/converter/PipelineCore.swift` base runtime, temp/publish, probes, caching, scheduling
- `Sources/converter/ValidationPipeline.swift` media identity, QC, preflight, verification
- `Sources/converter/ImagePipeline.swift` image conversions and derivative generation
- `Sources/converter/AudioPipeline.swift` audio conversions, mastering, archives, hashing, album builds
- `Sources/converter/VideoPipeline.swift` MP4 render and short-video render with encoder fallback
- `Output/` working directory for source inputs and generated outputs
- `config.txt` centralized quality, profile, mastering, and render policy settings
- `album.txt` album ordering input for album build actions
- `converter` prebuilt macOS Apple Silicon release binary

## Build
```bash
swift build --package-path Sources -c release
cp Sources/.build/arm64-apple-macosx/release/converter ./converter
chmod +x ./converter
```

## Test
```bash
swift test --package-path Sources
```

## Core Commands
```bash
./converter -help
./converter -doctor
./converter
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
./converter -silence 30
./converter -mp3toshort
./converter -mp3clean
./converter -m4atomp4
```

Short outputs are hard-capped at 58 seconds.
For `-mp3toshort`, a portrait `*_8K.png` is rendered directly to the short output; a landscape `*_8K.png` still follows the main-video-plus-short path.
Conversions preserve source loudness by default instead of remastering it down during normal pipeline work, including `-mp3toshort`.

`./converter -album` is the album version of the full production run. It scans `Output/` for `.mp3`, `.wav`, and `.flac` tracks, sorts them in natural numeric filename order, loudness-normalizes each track to `-12 LUFS`, builds one RF64 `album.wav`, then continues through the same full-run image, MP4, and short-render pipeline.

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

## Silence Padding
Use `./converter -silence SECONDS` to add silent lead-in and tail padding to `.wav`, `.flac`, and `.mp4` files in `Output/`.

Example:
```bash
./converter -silence 30
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
./converter
```

When both `Horizontal_8K.png` and `Vertical_8K.png` are present, full run renders the main MP4 first from `Horizontal_8K.png`, then renders the short MP4 directly from `Vertical_8K.png`. Direct 8K PNG inputs are used as-is and skip source-image derivative generation.

Full run produces:
- image deliverables: 8K/4K PNG, NFT PNGs, 3K/2K PNG, JPG exports
- audio deliverables: WAV, M4A, MP3
- archival deliverables: `*_RF64.flac`, `*_RF64.wav`, `*_BW64.flac`, `*_BW64.wav`
- video deliverables: main MP4 and short MP4

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
