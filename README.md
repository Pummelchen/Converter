# Converter

Swift-based media converter and production pipeline for YouTube studio workflows.

## Layout
- `Sources/` Swift package, tests, bundled third-party code, and the in-process BW64 bridge source
- `Output/` working directory for source inputs and generated outputs
- `config.txt` centralized quality and policy settings
- `album.txt` album ordering input for album build actions
- `converter` prebuilt macOS Apple Silicon release binary

## Build
```bash
swift build --package-path Sources -c release
cp Sources/.build/arm64-apple-macosx/release/converter ./converter
chmod +x ./converter
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
- BW64 writing is integrated into `converter`; no external helper binary is required.
- The tool auto-discovers media inputs from `Output/` by default.
- The committed binary is a macOS Apple Silicon release build.
- `Output/` is kept in the repo only as an empty working directory placeholder.
- `Sources/.build/` remains ignored by Git.
