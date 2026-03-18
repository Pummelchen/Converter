# Converter

Swift-based media converter and production pipeline for YouTube studio workflows.

## Layout
- `Sources/` Swift package, tests, bundled third-party code, and native helper source
- `Output/` working directory for source inputs and generated outputs
- `config.txt` centralized quality and policy settings
- `album.txt` album ordering input for album build actions
- `converter` prebuilt macOS Apple Silicon release binary
- `.converter_bw64_writer` prebuilt BW64 helper binary required for true BW64 output

## Build
```bash
swift build --package-path Sources -c release
cp Sources/.build/arm64-apple-macosx/release/converter ./converter
cp Sources/.build/arm64-apple-macosx/release/bw64_writer ./.converter_bw64_writer
chmod +x ./converter ./.converter_bw64_writer
```

## Run
```bash
./converter -help
./converter
./converter -matrix
./converter -mp3clean
./converter -m4atomp4
```

## Full Run Contract
Place these inputs in `Output/`:
- exactly 1 source image: `.png` preferred, `.jpg` and `.jpeg` also accepted
- exactly 1 source audio file: `.flac`, `.wav`, or `.mp3`

Then run:
```bash
./converter
```

## Notes
- The tool auto-discovers media inputs from `Output/` by default.
- The committed binaries are macOS Apple Silicon release builds.
- `Output/` is kept in the repo only as an empty working directory placeholder.
- `Sources/.build/` remains ignored by Git.
