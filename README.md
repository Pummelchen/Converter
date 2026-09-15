# Converter

[![Stars](https://img.shields.io/github/stars/Pummelchen/Converter?style=flat-square&logo=github&label=Stars&color=e3b341)](https://github.com/Pummelchen/Converter/stargazers)
[![Views (14d)](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/Pummelchen/Converter/main/.github/traffic.json)](https://github.com/Pummelchen/Converter)
[![Last Commit](https://img.shields.io/github/last-commit/Pummelchen/Converter?style=flat-square&logo=git&label=Last%20Commit&color=2ea44f)](https://github.com/Pummelchen/Converter/commits/main)
[![Contact](https://img.shields.io/badge/Contact-0xa0b1%40gmail.com-blue?style=flat-square&logo=gmail&logoColor=white)](mailto:0xa0b1@gmail.com)

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

The full run renames its single source audio to `1_source.<ext>` — and moves the whole companion
family (`*_RF64`, `*_BW64`) with it — so every deliverable is named after the release (`1.wav`,
`1.mp3`, `1_8K.mp4`, …) and the untouched original always sits beside them as `1_source.<ext>`.
Batch actions name each output after its own source file instead.

`Output/` is both the input and output directory. Discovery is non-recursive, and the directory is meant to be cleared between runs.

## What a full run produces

| | |
|---|---|
| Images | 8K/4K PNG, NFT squares (8K/3K/2K), 3K/2K PNG, sized JPG exports |
| Portrait stills | both short framings as `_Short_8K.png` / `_Short_CenterCut_8K.png` plus `_1MB.jpg` / `_2MB.jpg` |
| Audio | RF64 WAV (24-bit/96 kHz), ALAC M4A, 320 kbps MP3 |
| Archival | `*_RF64.flac`, `*_RF64.wav`, `*_BW64.wav` |
| Video | main MP4 (7680×4320) + four portrait shorts (4320×7680) |

The four shorts give you both framings, each with a full-length companion when the song runs past
the cap — `min(SHORT_MP4_CLIP_SECONDS, 58)` seconds, so lowering the configured cap also lowers the
companion threshold:

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

- **Loudness is preserved unless you ask for a change.** Only `-master`, `-loudness` and `-album`
  (per-track normalization) change loudness. The processing actions (`-bass`, `-fade`, `-fadecut`,
  `-fadeout`, `-fadewav`, `-noise`, `-silence`, `-mp3clean`) change the audio only in the way their
  name says.
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

Requires Swift tools 6.4+ (Xcode 27) and macOS 15+. The package lives in `Sources/`, so every SwiftPM command needs `--package-path Sources`.

```bash
swift build --package-path Sources -c release
# The product path moved with the Swift 6.4 build system, so ask SwiftPM for it instead of hardcoding it.
cp "$(swift build --package-path Sources -c release --show-bin-path)/converter" ./converter && chmod +x ./converter
swift test --package-path Sources     # 263 tests, ~11 min
```

A prebuilt `converter` binary ships at the repository root. CI runs the build and full suite on every push and PR to `main` ([ci.yml](./.github/workflows/ci.yml)).

## Runtime dependencies

Homebrew `ffmpeg` (provides `ffmpeg` + `ffprobe`) and `imagemagick` (`magick`), plus system `awk` and `sed`.

Auto-install is **off by default**; a missing formula produces an error telling you what to install. Setting `CONVERTER_AUTO_INSTALL_DEPS=1` opts into `brew install` — and, if Homebrew itself is absent, into **downloading and executing the official Homebrew install script (`curl … | bash`), which runs remote code on your machine**. Leave it unset where that is unacceptable.

## Layout

- `Sources/` — Swift package, tests, vendored libbw64, in-process BW64 bridge
- `Output/` — working directory for inputs and generated outputs
- `config.txt` — quality, render, loudness and profile settings ([reference](https://github.com/Pummelchen/Converter/wiki/Configuration))
- `album.example.txt` — template for `album.txt`, the track order for `-wavtoalbum` / `-mp3toalbum` (copy it to `album.txt`; the user file is git-ignored)
- `converter` — prebuilt Apple Silicon release binary

## License

MIT — see [LICENSE](LICENSE).

## Third-party code

`Sources/ThirdParty/libbw64/` vendors [libbw64](https://github.com/ebu/libbw64) 0.10.0 by the EBU,
licensed under the Apache License 2.0 (see `Sources/ThirdParty/libbw64/LICENSE` and `UPSTREAM.md`).
It is compiled into the `converter` binary, which therefore carries that notice.

## Contact

Questions, bug reports and suggestions are always welcome. You can contact André Borchert by email at [0xa0b1@gmail.com](mailto:0xa0b1@gmail.com).
