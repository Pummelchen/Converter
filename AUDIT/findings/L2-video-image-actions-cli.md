# Reviewer report: VideoPipeline, ImagePipeline, Actions, CLI — raw, 2026-09-13

Local ids X-n; ledger ids assigned in ledger.json.

### X-1 | S0 | Actions.swift:563-569 | -full with an MP3 source overwrites the user's source with a transcode of itself
- evidence: ensureStandardMP3Output throws for any non-48 kHz MP3 (most user MP3s are 44.1 kHz); fallback convertAudioToMP3(wav) names its output outDir/<wav.stem>.mp3 = 1.mp3 = the (renamed) source; publishTemp moves the LAME re-encode over it and deletes the backup. Original lost, second lossy generation.
- fix: every convertAudioTo*/publish path refuses when output.standardizedFileURL == source.standardizedFileURL; the full-run MP3 branch must route the rebuilt MP3 to a distinct path or refuse clearly. (Design decision needed: keep source untouched; standard MP3 written as a deliverable under a distinct name.)
- test: 44.1 kHz MP3 + landscape PNG → stepFull(); CRC32 of the original file unchanged (fails today).

### X-2 | S0 | VideoPipeline.swift:314 (+ AudioPipeline.swift:1986) | -album --output-file X publishes the main MP4 over the album WAV (both album build and renderM4AToMP4 consume cli.outputFile in one run)
- fix: renderM4AToMP4 takes an explicit output override passed only by stepM4AToMP4; validate --output-file only for single-output actions.
- test: stepAlbum with outputFile "X.wav" → X.wav still RF64 WAV and the MP4 exists under its own name.

### X-3 | S1 | Actions.swift:209-218 | normalizedFullRunSource renames only the winning family member: song.flac+song.wav → 1.flac + song.wav → rerun "found 3"; song.flac+song_RF64.flac → rerun treats song_RF64 as a candidate → fails; fileExists fallback silently proceeds un-renamed; rename precedes preflight (corrupt source loses its name)
- fix: rename the whole family (same-stem candidates and _RF64/_BW64 companions) refusing if any target exists; replace the silent fallback with an error; rename after preflight of the chosen source.
- test: song.flac + song_RF64.flac (and song.flac + song.wav): resolveFullAudio() twice → second returns 1.flac (throws today).

### X-4 | S1 | Actions.swift:576-600 | Non-standard WAV source is rewritten in place (normalizeWAVInPlace) and the only untouched copy is a temp deleted in defer; archival variants are resampled → no bit-exact original survives; README says only -master/-loudness alter audio
- fix: never modify the source; produce the standard WAV as a distinct deliverable (keep original, e.g. 1_source.wav, or write standard as 1.wav only when the source is not itself 1.wav).
- test: full run with 16-bit/44.1 kHz WAV → source CRC32 unchanged.

### X-5 | S1 | Actions.swift:717-723,677-686 (stepPNGToJPG too) | -aipix/-run_pix (and -pngtojpg) re-ingest portrait stills (1_Short_8K.png) and overwrite them with letterboxed landscape renders; every other _8K discovery path filters isPortraitShortStill
- fix: a single isFullRunDerivedImage predicate applied in every batch discovery.
- test: 4320x7680 art_Short_8K.png → stepAIPix() leaves dimensions unchanged.

### X-6 | S1 | VideoPipeline.swift:159-171 | Encoder ladder falls through on publishTemp errors and on encoder-independent verifications (ALAC audio, duration, source loudness) — only verifyAudioQC sets isEncoderIndependent → hours of re-renders before the same error
- fix: rethrow publish errors as encoder-independent; split verification into encoder-dependent (video stream) vs independent (audio/duration/loudness) and flag the latter.
- test: two-rung ladder + unwritable destination → ffmpeg invoked once.

### X-7 | S1 | CLI.swift:271-272 | Unknown --options silently become positional args (`-full --overwite` runs without overwrite); actions that take no positionals ignore them
- fix: reject arguments starting with "-" that are not known flags and not numeric; reject non-empty actionArgs for actions that consume none.
- test: parse(["-full","--overwite"]) throws.

### X-8 | S2 | Support.swift:308 (CLI.swift:284-339) | M:SS parsing splits with omittingEmptySubsequences → ":30", "1::30", "1:30:" accepted; "Empty time component" guard unreachable
- fix: split(omittingEmptySubsequences: false).
- test: parseFlexibleTimecode("1::30") throws.

### X-9 | S2 | Actions.swift:1254 | -mp4toshort filter hasSuffix("_Short") misses _Short_CenterCut / _Short_FullSong(_CenterCut) → re-ingests own shorts
- fix: isShortMP4Deliverable predicate (contains "_Short").
- test: x_8K.mp4 + x_8K_Short_CenterCut.mp4 → no x_8K_Short_CenterCut_Short.mp4.

### X-10 | S2 | ImagePipeline.swift:329-336 | Fitted portrait still sharpens an already-sharpened NFT8K master (double sharpen) and a user Vertical_8K.png that help says is used "as-is"
- fix: sharpen parameter true only for the raw discovered portrait.
- test: argument builder emits -sharpen only for raw sources.

### X-11 | S2 | VideoPipeline.swift:399-404 | shortenMP4 upscales (2430x4320 → 4320x7680) with ffmpeg's default bicubic; other paths use flags=<scaleQualityFlags>
- fix: add flags to the scale filter.
- test: -vf string contains flags=lanczos+accurate_rnd.

### X-12 | S2 | Actions.swift:278-286 | Orientation by stored dimensions ignores EXIF orientation (rotated phone JPEG misclassified, then "Image width mismatch"); square images silently treated as landscape
- fix: probe %[orientation] and swap for 5-8; reject or document squares.
- test: 300x200 JPEG with Orientation=6 → portrait.

### X-13 | S2 | ImagePipeline (all preflightPNGInput sites) | Full-decode preflight (magick -resize 1x1! null:) of the same 8K master ~10× per run, never cached
- fix: cache decode result in probeCache by fingerprint.
- test: counting runner → 1 decode for the master.

### X-14 | S2 | Actions.swift:615-619,461-490 | async-let partial failure does not stop sibling external processes (waitUntilExit ignores cancellation) → minutes of wasted work before the error surfaces; no output collision (all names distinct)
- fix: ProcessRunner registers the Process with withTaskCancellationHandler → terminate on cancel; map to CancellationError.
- test: two permits, one throws immediately, other runs sleep 30 → outer await returns well under 30 s.

### X-15 | S1 (docs) | README.md:25, CLI.swift:461-481,664-665, wiki | Docs contradict behaviour: source rename; "only -master/-loudness alter audio" (X-1/X-4); help omits optional portrait; help says short falls back to NFT8K when Vertical absent but discovered portrait wins; "Vertical_8K.png used as-is" false (X-10); --keep-full-name text inverted; "58 seconds" hard-coded while cap is min(config,58); --output-file accepted by -full/-album undocumented
- fix: README, help lines, wiki; help-text test for the corrected contract.

### X-16 | S3 | Actions.swift:114-123 | rankedFullRunImageCandidates dead (periphery confirms)
### X-17 | S3 | Actions.swift:105-110,794-796,803-808 | unreachable preference fallback; redundant emptiness/dimension guards in stepNFTToShort
### X-18 | S3 | CLI.swift:256-260,231-235 | --seed 0 accepted vs "positive integer" message; --sharpness unbounded (100 → minutes per image); repeated action flags last-wins silently; option value "--overwrite" stored as filename
### X-19 | S3 | VideoPipeline.swift:284-300,456-458 | Inconsistent short-duration thresholds between the two short paths (±0.5 vs hard 58.1); -t placement and FullSong epsilon otherwise correct
### X-20 | S3 | VideoPipeline.swift:230,240,244 | Config colour/scale-filter values spliced into the filter graph with non-empty validation only (local misconfiguration could inject filters; verification would catch garbage) — validate charset/enumerations
### X-21 | S3 | VideoPipeline.swift:334,386,467 | ALAC M4A decoded to 96 kHz WAV and re-encoded for every video (5 per run) although -c:a copy is bit-transparent

## Verdicts
(a) CONFIRMED (X-6). (b) wrong-file processing NOT A BUG (existing 1.<ext> becomes a second candidate → error); rerun breakage CONFIRMED (X-3); moveItem atomic on APFS. (c) 1.flac+1.wav+song.mp3 → "found 3", NOT A BUG. (d) fullRunImageBaseName terminates; marker order irrelevant. (e) CONFIRMED (X-12). (f) cap correct; threshold inconsistency X-19. (g) X-7, X-8, X-18. (h) stills derive from correct images; double sharpen X-10.

## Checked and OK
Temps cleaned in every catch; distinct async-let outputs; --output-file containment; negative numeric positionals parse; crop escaping; verifyCodec mapping; archival sibling rule; exit codes.

## Placeholder sweep result
0 in the four files.
