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
./converter -matrix
./converter -fade 10
./converter -fadecut 5 10
./converter -fadeout 1:30 10
./converter -mp3toshort
./converter -mp3clean
./converter -m4atomp4
```

Short outputs are hard-capped at 58 seconds.
For `-mp3toshort`, a portrait `*_8K.png` is rendered directly to the short output; a landscape `*_8K.png` still follows the main-video-plus-short path.
Conversions preserve source loudness by default instead of remastering it down during normal pipeline work, including `-mp3toshort`.

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
