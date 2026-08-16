# Converter

Swift CLI that turns one song and one image into a complete, verified upload set for macOS Apple Silicon.

Every output is verified before it is published — wrong size, wrong codec, silent audio, or drifted loudness fails the run rather than producing a bad file.

## Quick start

```bash
brew install ffmpeg imagemagick     # runtime media tools
./converter -doctor                 # verify toolchain, encoders, filters
```

Put **one audio file** (`.flac`/`.wav`/`.mp3`) and **one landscape image** in `Output/`, then:

```bash
./converter -full
```

Source images are identified by orientation, not by filename:

- **one landscape image** — required, any size, upscaled to the 8K master
- **one portrait image** — optional, any size, used for the fitted shorts

Every generated file is named after the audio file, so one release keeps one prefix throughout. Your source files keep their own names.

`Output/` is both the input and output directory. Discovery is non-recursive, and the directory is meant to be cleared between runs.

## What a full run produces

| | |
|---|---|
| Images | 8K/4K PNG, NFT squares (8K/3K/2K), 3K/2K PNG, sized JPG exports |
| Portrait stills | both short framings as `_Short_8K.png` / `_Short_CenterCut_8K.png` plus `_1MB.jpg` / `_2MB.jpg` |
| Audio | RF64 WAV (24-bit/96 kHz), ALAC M4A, 320 kbps MP3 |
| Archival | `*_RF64.flac`, `*_RF64.wav`, `*_BW64.wav` |
| Video | main MP4 (7680×4320) + four portrait shorts (4320×7680) |

The four shorts give you both framings, each with a full-length companion when the song runs past the 58-second cap:

- `_8K_Short.mp4` — image fitted inside the frame, padded with black
- `_8K_Short_CenterCut.mp4` — centre of the 8K master cropped to fill the frame, no padding
- `_8K_Short_FullSong.mp4` and `_8K_Short_FullSong_CenterCut.mp4`

Both framings are also saved as stills, so the artwork is usable without pulling a frame out of a video: `<prefix>_Short_8K.png` and `<prefix>_Short_CenterCut_8K.png` at full portrait resolution, each with a `_1MB.jpg` and `_2MB.jpg` export.

## Documentation

| Where | What |
|---|---|
| [Wiki](https://github.com/Pummelchen/Converter/wiki) | Usage reference: recipes, commands, configuration, troubleshooting |
| `./converter -help` | Full command and option reference |
| [docs/FORMATS.md](./docs/FORMATS.md) | Input/output formats per command |
| [docs/KNOWN_GOOD_VERSIONS.md](./docs/KNOWN_GOOD_VERSIONS.md) | Verified toolchain versions and calibration measurements |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Development guide |

## Behaviour worth knowing

- **Loudness is preserved, never silently changed.** Only `-master` and `-loudness` alter audio.
- **Existing outputs are verified and reused.** Pass `--overwrite` to force a rebuild.
- **Nothing is installed behind your back.** Missing tools fail with an actionable error.

## Audio standards

All audio paths stage through an internal RF64 WAV at 24-bit, 96 kHz, stereo (`pcm_s24le`).

| Deliverable | Standard |
|---|---|
| MP4 / M4A | ALAC, 24-bit, 48 kHz, stereo (never AAC) |
| MP3 | 320 kbps, 48 kHz, stereo |

Project loudness target is `-12 LUFS` for delivery, short-form, and mastering defaults.

## Build and test

Requires Swift tools 6.3.3+ and macOS 15+. The package lives in `Sources/`, so every SwiftPM command needs `--package-path Sources`.

```bash
swift build --package-path Sources -c release
cp Sources/.build/arm64-apple-macosx/release/converter ./converter && chmod +x ./converter
swift test --package-path Sources     # 154 tests, ~7.5 min
```

A prebuilt `converter` binary ships at the repository root. CI runs the build and full suite on every push and PR to `main` ([ci.yml](./.github/workflows/ci.yml)).

## Runtime dependencies

Homebrew `ffmpeg` (provides `ffmpeg` + `ffprobe`) and `imagemagick` (`magick`), plus system `awk` and `sed`.

Auto-install is **off by default**; a missing formula produces an error telling you what to install. Setting `CONVERTER_AUTO_INSTALL_DEPS=1` opts into `brew install` — and, if Homebrew itself is absent, into **downloading and executing the official Homebrew install script (`curl … | bash`), which runs remote code on your machine**. Leave it unset where that is unacceptable.

## Layout

- `Sources/` — Swift package, tests, vendored libbw64, in-process BW64 bridge
- `Output/` — working directory for inputs and generated outputs
- `config.txt` — quality, render, loudness and profile settings ([reference](https://github.com/Pummelchen/Converter/wiki/Configuration))
- `album.txt` — track order for `-wavtoalbum` / `-mp3toalbum`
- `converter` — prebuilt Apple Silicon release binary
