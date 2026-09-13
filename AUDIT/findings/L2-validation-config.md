# Reviewer report: ValidationPipeline, QualityReporting, Config, config.txt — raw, 2026-09-13

Local ids V-n; ledger ids assigned in ledger.json. Scope note: there is no Swift RIFF/ds64 chunk walker; Swift only checks the 12-byte header (verifyWAVHeader) and does a 64 KiB substring scan (containsChunk). Truncation is caught downstream by ffmpeg -xerror, duration match and canonical PCM size check (fail-closed).

### V-1 | S1 | ValidationPipeline.swift:93,98 | Stereo-imbalance check fail-open when one channel is digitally silent: parseAudioDB("-inf") → nil → compactMap drops the channel → count 1 → imbalance reported 0
- fix: parse "-inf" as -Double.infinity for RMS; imbalance becomes +inf > ceiling; also fail when parsed channel blocks < probed channel count.
- test: astats stderr with Channel 2 `RMS level dB: -inf` through the metric derivation (extract to a pure function) → issue "stereo imbalance".

### V-2 | S1 | ValidationPipeline.swift:92-99,111-121 | astats metrics fail-open: empty/unparseable astats → DC 0, imbalance 0, clipped 0 → QC passes (contrast parseLoudnormJSON which throws)
- fix: guard channelMetrics.count == channels, required keys present ("Peak level dB", "Peak count", per-channel "DC offset", "RMS level dB") else throw AppError naming the file.
- test: stub runner returning only volumedetect lines → audioQCResult throws (returns passed==true today).

### V-3 | S1 | ValidationPipeline.swift:18-32,97,197-201 | Clipped-samples rebase not sample-rate invariant: the long-source clip is measured after resampling to 96 kHz, a short source raw; render measured at its own rate → ceiling ~2× too loose or spurious failures on clipped masters
- fix: decode the comparison clip with the render's rate/channels; rebase clipped ceiling with proportional allowance rather than exact equality.
- test: 30 s 48 kHz hard-clipped source (aevalsrc square 0 dBFS) → short MP4 with short-form policy passes.
- confidence: medium.

### V-4 | S2 | ValidationPipeline.swift:683-691,1013-1018,1025-1028 | containsChunk is a 64 KiB substring scan, not a chunk walk: "bext"/"ds64" inside LIST/INFO/iXML/PCM counts as present; a bext after 64 KiB reads absent; ds64 position/size unverified; canReuseOutput applies this to pre-existing files of unknown origin
- fix: bounds-checked RIFFChunkWalker from offset 12 (id, u32 LE size, pad byte, ds64 substitution for 0xFFFFFFFF, overflow-checked arithmetic); require ds64 first for RF64/BW64.
- test: WAV whose LIST/INFO comment contains "bext" and no bext chunk → verifyExternalWAVStructure(expectBext:false) must pass (fails today).

### V-5 | S2 | Config.swift:203-205 | `archive` profile is a no-op placeholder (sets values equal to defaults; MP3_BITRATE cannot be anything else)
- fix: remove `.archive` from RunProfile + docs, or give it real semantics.
- test: ProjectConfig with archive != default (fails today).

### V-6 | S2 | Config.swift:197-200 vs config.txt:69-71 | youtube_short overlay puts h264_videotoolbox first at 4320x7680 where it always fails → guaranteed wasted rung + warning per variant
- fix: keep libx264 primary in .youtubeShort; add validate() rule rejecting h264_videotoolbox primary above the VT session limit.
- test: shortVideoEncoderLadder.first == "libx264" when shortMP4ScaleH == 7680.

### V-7 | S2 | Config.swift:159-161 | Unknown/typo'd config keys dropped at debug level only; UTF-8 BOM before first key not stripped
- fix: warn-level log naming key and file; strip \u{FEFF}.
- test: logger capture shows warn entry for unknown key.

### V-8 | S2 | ValidationPipeline.swift:16-32,59-63 | Source clip re-rendered and re-analysed for every short variant (unique temp path defeats the cache): up to 4 clip renders + 8 analyses of the identical segment per song
- fix: ProbeCache map keyed on (source fingerprint, limitDuration ms, policy).
- test: counting stub runner: 1 clip render across two identical calls.

### V-9 | S3 | ValidationPipeline.swift:203-210 | LUFS rebase widens tolerance symmetrically (raises the upper bound the source did not breach); masked by verifySourceLoudnessPreserved
- fix: explicit min/max LUFS in AudioQCPolicy; move only the breached bound.
- test: -25 LUFS source → rebased maximum still -4.

### V-10 | S3 | Config.swift:447-452 | parseInt rejects negatives with "must be an integer"
- fix: distinct "must be a non-negative integer" message.

### V-11 | S3 | Config.swift:319-437 | Validation gaps: WAV_WRITE_BEXT (0/1), FLAC_COMPRESSION_LEVEL (0–12), PNG compression levels (0–9), *_TARGET_BYTES (0 accepted → every JPEG fails later), IMAGE_AIPIX_FILTER / IMAGE_JPEG_SAMPLING_FACTOR (empty accepted), CRFs (0–51), VT_QUALITY (1–100, negatives pass), CRC_CHUNK_BYTES (no upper bound)
- fix: requireRange / requireNonEmpty helpers; cap CRC_CHUNK_BYTES.
- test: table-driven load test per key.

### V-12 | S3 | Config.swift:400 vs VideoPipeline.swift:269 | SHORT_MP4_CLIP_SECONDS validated with Double() but consumed via parseFlexibleTimecode (MM:SS) — inconsistent (see also T-11)
- fix: validate() calls parseFlexibleTimecode.

### V-13 | S3 | ValidationPipeline.swift:96 | `Int(Double(...))` on "Peak count" traps on nan/out-of-range
- fix: Int(exactly:) with throw (ties into V-2).

### V-14 | S3 | config.txt / wiki Configuration | PREFLIGHT_SECONDS, DURATION_TOLERANCE_SEC, CRC_CHUNK_BYTES supported but undocumented
- fix: add to config.txt (commented, defaults) and wiki; test asserting config.txt keys == supportedKeys.

## Verdicts
(a) verifyWAVHeader bounds correct; no ds64 parser exists; containsChunk weakness CONFIRMED (V-4). (b) rebase cannot raise above source+allowance nor touch unbreached metric: NOT A BUG; LUFS symmetric widening minor (V-9); segment logic when limit ≥ duration: NOT A BUG; clipped-sample cross-rate: CONFIRMED (V-3). (c) canonical PCM: NOT A BUG (size mismatch throws, channels equalised, whole file, bounded memory, s24 sign-extension correct). (d) ProbeCache: NOT A BUG in practice. (e) Config parsing locale-independent; MP3_BITRATE string-compared; PROFILE precedence matches wiki; unknown keys CONFIRMED (V-7). (f) astats parser order-tolerant; clipped samples is a derived "full-scale hits" proxy; fail-open on parse failure (V-2), silent-channel blind (V-1).

## Config key diff
All 77 config.txt keys are in supportedKeys with apply cases and matching defaults; three supported keys missing from config.txt (V-14). Range validation gaps listed in V-11.

## Placeholder sweep result
2 no-op sites (archive profile V-5; youtubeShort assigns default shortAudioQCTargetLUFS), 0 TODO/FIXME markers.
