# Converter

Swift-based media converter and production pipeline for YouTube studio workflows.

## Layout
- `Sources/` Swift package, tests, bundled third-party code, and native helper source
- `Output/` working directory for source inputs and generated outputs
- `config.txt` centralized quality and policy settings
- `album.txt` album ordering input for album build actions

## Build
```bash
swift build --package-path Sources -c release
cp Sources/.build/arm64-apple-macosx/release/converter ./converter
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
- Generated binaries and local build products are intentionally ignored by Git.
- `Output/` is kept in the repo only as an empty working directory placeholder.
