# Supported Input and Output Formats by Command

Reference for converter inputs/outputs, aligned with the CLI help (`./converter -help`) and the conversion matrix (`./converter -matrix`). Source discovery is non-recursive over `SRC_DIR` (default `Output/`); hidden files are skipped.

## Audio format matrix

Formats: `flac`, `wav`, `mp3`, `m4a`

| From \ To | flac | wav | mp3 | m4a |
|---|---|---|---|---|
| flac | — | `-flactowav` | `-flactomp3` | `-flactom4a` |
| wav | `-wavtoflac` | — | `-wavtomp3` | `-wavtom4a` |
| mp3 | `-mp3toflac` | `-mp3towav` | — | `-mp3tom4a` |
| m4a | `-m4atoflac` | `-m4atowav` | `-m4atomp3` | — |

- WAV outputs use the project standard: RF64 `pcm_f32le`, 192 kHz, stereo.
- M4A outputs are ALAC (24-bit, 48 kHz, stereo); MP3 outputs are 320 kbps, 48 kHz, stereo.
- Audio conversions reject silent inputs, mismatched container/codec payloads, and files with video streams (except where noted).

## Image format matrix

Formats: `png`, `jpg`/`jpeg`

| Command | Input | Output |
|---|---|---|
| `-jpgtopng` | `.jpg`/`.jpeg` | `.png` |
| `-pngtojpg` | `.png` | `.jpg` |
| `-aipix` | `.png` | `_8K.png`, `_4K.png` |
| `-pngtonft` | `*_8K.png` | `_NFT8K.png`, `_NFT3K.png`, `_NFT2K.png` |
| `-pngto3k` / `-pngto2k` | `*_8K.png` | `_3K.png` / `_2K.png` (square) |
| `-pngto3k1mb` / `-pngto3k5mb` | `*_3K.png` | `_1MB.jpg` / `_5MB.jpg` |
| `-pngtojpg1mb` / `-pngtojpg2mb` / `-pngtojpg20mb` | `*_8K.png` | `_1MB.jpg` / `_2MB.jpg` / `_20MB.jpg` |
| `-run_pix` | `.png`/`.jpg`/`.jpeg` | full image deliverable set per source |
| `-visualsubs` | none (dot count via `--num-dots` or positional) | generated `.png` |

JPEG scanning accepts both `.jpg` and `.jpeg`; JPEG outputs are written with `.jpg`. Extension/payload mismatches are rejected.

## Video transforms

| Command | Input | Output |
|---|---|---|
| `-m4atomp4` | exactly 1 `*_8K.png` + exactly 1 `.m4a` | main MP4 (HEVC ladder, 7680x4320, ALAC audio) |
| `-short` | exactly 1 image (`.png`/`.jpg`/`.jpeg`) + exactly 1 audio-only file supported by ffmpeg | `_8K_Short.mp4` portrait clip (H264 ladder, 4320x7680), capped at 58 s, image fitted with black padding; plus `_8K_Short_FullSong.mp4` full-length variant when the audio is longer than 58 s |
| `-nfttoshort` | any single audio-only file supported by ffmpeg + `Vertical_8K.png` or existing/derived `*_NFT8K.png` (or any single image as fallback) | `_8K_Short.mp4` portrait clip, capped at 58 s, source loudness preserved; plus `_8K_Short_FullSong.mp4` full-length variant when the audio is longer than 58 s |
| `-mp4toshort` | one or more `.mp4` | `_Short.mp4` portrait clips, capped at 58 s |

`-mp3toshort` was renamed to `-nfttoshort`; the old flag is rejected with an actionable error.

## Album and full production

| Command | Input discovery | Output |
|---|---|---|
| `-full` / `-run` | exactly 1 source audio (`.flac`/`.wav`/`.mp3`) + 1 source image or direct 8K PNGs in `SRC_DIR` | image deliverables, WAV/M4A/MP3, `*_RF64`/`*_BW64` `.wav`/`.flac` archival companions, main MP4, short MP4, full-song short MP4 (when audio exceeds the short clip cap) |
| `-album` | 2+ `.mp3`/`.wav`/`.flac` in `SRC_DIR`, natural numeric order | normalized (-12 LUFS per track) RF64 `album.wav`, then full-run deliverables |
| `-wavtoalbum` | `album.txt` (project root) listing `.wav` tracks resolved in `SRC_DIR` | RF64 `album.rf64.wav` (listed order, no normalization) |
| `-mp3toalbum` | `album.txt` listing `.mp3` tracks | RF64 `album_from_mp3.rf64.wav` (listed order, no normalization) |
| `-flactoalbum` | all `.flac` in `SRC_DIR`, natural numeric order | RF64 `album.wav` (no normalization) |

`album.txt` supports `#` comments and blank lines; entries may omit the extension; missing tracks are skipped with a warning. Archival companions (`*_RF64.*`, `*_BW64.*`) are delivery-only and excluded from source selection in full runs.

## Audio processing actions (batch over SRC_DIR)

| Command | Accepts | Output naming |
|---|---|---|
| `--hash` | `.wav`, `.flac`, `.mp3`, `.mp4` | CRC32-based filenames |
| `-bass [FREQ GAIN]` | `.flac`, `.wav`, `.mp3`, `.m4a`, `.mp4` | `_bass` or settings-specific suffix (e.g. `_bass_80Hz_m5dB`) |
| `-loudscan` | `.flac`, `.wav`, `.mp3`, `.m4a`, `.mp4` | terminal report only |
| `-loudness [LUFS]` | `.flac`, `.wav`, `.mp3`, `.m4a`, `.mp4` | `_loudness_m12LUFS`-style suffix |
| `-fade [S]`, `-fadecut C F`, `-fadeout START DUR` | `.flac`, `.wav`, `.mp3` (`.m4a` for `-fadeout`) | `_faded` / `_fadecut` |
| `-fadewav` | `.wav` | faded RF64 WAV |
| `-noise [S]` | `.flac`, `.wav`, `.mp3`, `.m4a`, `.mp4` | `_noise_<S>s` |
| `-silence [S]` | `.wav`, `.flac`, `.mp4` | `_silence_<S>s` |
| `-mp3clean` | `.mp3` | same name, artwork/junk streams/metadata removed |
| Format hash actions | `-flactohash`, `-mp3tohash`, `-wavtohash` | CRC32-based filenames |

Previously generated `_silence_*`/`_noise_*` outputs and archival companions are excluded from re-processing where applicable.

## Explicit output paths

`--output-file FILE` must resolve directly inside `OUT_DIR`; subfolders are rejected. Same direct-child rule applies to album entries in `album.txt`.
