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
./converter -mp3clean
./converter -m4atomp4
```

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
- exactly 1 source image: `.png` preferred, `.jpg` and `.jpeg` also accepted
- exactly 1 source audio file: `.flac`, `.wav`, or `.mp3`

Then run:
```bash
./converter
```

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

## Notes
- media inputs are auto-discovered from `Output/` by default
- `Output/` is intended as a manually cleaned working directory between runs
- `Sources/.build/` remains ignored by Git
