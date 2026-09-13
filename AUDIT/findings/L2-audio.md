# Reviewer report: AudioPipeline.swift, LosslessAudioPipeline.swift — raw, 2026-09-13

Local ids A-n; ledger ids assigned in ledger.json. Context: default SRC_DIR == OUT_DIR (CLI.swift:94-99), so every "rerun in same directory" scenario is the default layout. All paths reach ffmpeg as absolute argv entries; no concat demuxer list files exist (concat via -filter_complex with -i inputs).

### A-1 | S1 | AudioPipeline.swift:1910-1913 (1866-1908) | -album includes the same track once per format (01.flac, 01.wav, 01.mp3 all concatenated) and does not exclude _mastered/_silence_/_noise_ outputs; only header + summed duration verified (self-consistent)
- fix: collapse by stem via existing rankedFamily(rank: extensionRank) before sorting; extend isAlbumDerivedAudio with silence/noise/_mastered predicates.
- test: 01.flac, 01.wav, 02.mp3, 02_mastered.mp3, 03_noise_30s.flac → albumAudioCandidates() == [01.flac, 02.mp3] (returns 5 today).

### A-2 | S1 | AudioPipeline.swift:2076-2085 | album.txt builds silently skip missing/invalid tracks (warn + continue) and publish a shorter album with exit 0, contradicting the stated fail-closed policy at 1830-1831
- fix: throw unless --continue-on-error; under the flag collect failures and throw a summary after the loop.
- test: album.txt lists a, missing; only a.wav exists → buildAlbumFromAlbumFile throws, no album.rf64.wav.

### A-3 | S1 | AudioPipeline.swift:1562-1583 | -mp3clean overwrites the user's source MP3 in place with a LAME re-encode (decode→96k PCM→encode, forced 48 kHz/320k) although help says "artwork, junk streams, metadata removed" and the test is named "StreamCopyCleanup"; no equivalence verification
- fix: single ffmpeg stream copy (-map 0:a:0 -c:a copy -map_metadata -1 -id3v2_version 0 -vn -sn -dn), verifyMP3File + verifyDurationMatch + verifyCanonicalPCMSampleEquivalence before publish.
- test: cleaned MP3 is sample-equivalent to the original and keeps its sample rate (44100 stays 44100).
- confidence: medium (help says "rewritten"; but README:59 "loudness preserved, never silently changed" and the test name say stream copy).

### A-4 | S1 | AudioPipeline.swift:1316-1340 | ensureStandardMP3Output publishes without verifyDurationMatch/verifySourceLoudnessPreserved (unlike convertAudioToMP3:1503-1505); an already-standard MP3 outside OUT_DIR is re-encoded (generation loss) while inside OUT_DIR it is returned untouched; reuse verifier accepts any same-named standard MP3
- fix: if preflight + verifyMP3Standard(source) pass → copyFileIntoTemp, verify, publish; else convertAudioToMP3; add duration/loudness verification to the reuse verifier.
- test: standard MP3 in SRC_DIR ≠ OUT_DIR → crc32(output) == crc32(source).

### A-5 | S1 | AudioPipeline.swift:492-530,487-490 | -bass (+5 dB default below 80 Hz) can clip the pcm_s24le staging WAV; verifyBassOutput checks type + duration only, never true peak / clipped samples; CLI accepts any finite gain
- fix: QC the processed WAV (clippedSamples ≤ config max, true peak ≤ ceiling) and fail with a "reduce gain" error, or stage through pcm_f32le until the final encode.
- test: −1 dBTP fixture with strong sub-100 Hz content + 80 Hz/+5 dB → must throw (publishes clipped today).
- confidence: medium-high.

### A-6 | S1 | AudioPipeline.swift:1070-1082 | encodeDurationPaddedMP4 ad-hoc encoder ladder: no isEncoderIndependent handling (a verifyDuration mismatch is retried on every rung with a full 8K encode) and only the last error reported (CONFIRMED). No-video branch skipping verifyDuration: NOT A BUG at publish (callers verify before publishTemp).
- fix: extract a shared withEncoderLadder(encoders:label:attempt:) from renderVideoWithEncoderLadder; mark duration mismatch isEncoderIndependent; share verifyDuration across both branches.
- test: stub runner writing wrong-duration output for a two-rung ladder → exactly one invocation, error names the first rung.

### A-7 | S2 | AudioPipeline.swift:94-97 (Actions.swift:1071) | -master not idempotent: rerun re-masters its own _mastered outputs (X_mastered_mastered.flac); siblings all have exclusion predicates
- fix: isMasterDerivedAudio + audioMasterCandidates(); also used by A-1.
- test: song.flac + song_mastered.flac → candidates == [song.flac].

### A-8 | S2 | AudioPipeline.swift:2104-2113 | -flactoalbum concatenates every .flac including _RF64, _loudness_, _bass, _faded outputs
- fix: filter with isAlbumDerivedAudio before sortNatural.
- test: 01.flac, 01_RF64.flac, 02_loudness_m12LUFS.flac → [01.flac].

### A-9 | S2 | AudioPipeline.swift:327-336,367-387,591-600 | maxSafeBoost uses max(maxVolume, peakLevel, truePeak) → NOT A BUG; but fallback publishes any true-peak breach (loudnessCandidateIsPublishableFallback discards all TP issues) with no lossy-codec headroom and a misleading "closest-safe" label
- fix: accept TP issue only when inherent (≤ sourcePeak + appliedGain + 0.1); MP3 headroom 0.3 dB; choose the log reason from the actual issue set.
- test: metrics fixture TP −0.4, sourcePeak −1.5, gain +0.5 → predicate false (true today).
- confidence: medium.

### A-10 | S2 | AudioPipeline.swift:992&1170,1029,508 | Redundant expensive probes: verifyNoisePadding (up to 8 ffmpeg decodes) runs on staging WAV and again on the deliverable; ffmpeg -filters spawned per file (encoders cached, filters not); encoder ladder resolved + logged per file
- fix: verify padding once on the deliverable; cachedFFmpegFilterSet(); hoist ladder resolution.
- test: counting runner: ≥ 8 fewer ffmpeg invocations per addNoiseToMedia.

### A-11 | S3 | AudioPipeline.swift:905 | Noise seed Int.random → reruns not reproducible; verifier does check the documented contract but not that the middle segment is audible
- fix: seed from crc32(source) XOR per-segment constant; audibility probe of the middle segment.
- test: two runs with --overwrite → identical crc32.

### A-12 | S3 | AudioPipeline.swift:53-64,66-77 | Derived-media predicates use the FIRST "_silence_"/"_noise_" occurrence → a_silence_2s_silence_3s treated as fresh source
- fix: range(of:options:.backwards).
- test: isSilenceDerivedMedia("a_silence_2s_silence_3s.wav") == true.

### A-13 | S3 | AudioPipeline.swift:1850-1854 | Track-number parse uses Unicode isNumber ("3½" → nil → sorted as unnumbered); >19 digits overflow to nil
- fix: isASCII && isWholeNumber, cap digits.
- test: ["3½ x", "10 y", "2 z"] sorts 2, 3½, 10.

### A-14 | S3 | AudioPipeline.swift:1378,1694-1706 | Magic byte width 3 assumes pcm_s24le while wavCodec is configurable; BW64 path writes full-length f32le with no free-space check
- fix: bytes/sample derived from wavCodec; availableBytes check before the raw PCM temp.

### A-15 | S3 | LosslessAudioPipeline.swift:9,30,173-174; AudioPipeline.swift:160-162,264,1955/1962,2049-2051 | Dead parameters (writeBext, encodeInternalWAVToFLAC sampleRate/channels), tautological guard in case "m4a", "Unsupported bass source type" message used by loudness/master/loudscan, double discard, album duration tolerance (2.0) equal to the gap it should detect (albumSilenceSecs 2 → dropped gap passes)
- fix: remove dead params/guard, parameterise label, drop pre-throw discard, tolerance min(durationToleranceSec, albumSilenceSecs/2).
- test: stub duration expected−2.0 → buildAlbum throws.

## Verdicts
(a) CONFIRMED (A-6). (b) NOT A BUG (A-9 adjacent). (c) N/A no concat list files. (d) CRC-32 slice-by-8 NOT A BUG (unaligned load + littleEndian, swift_once tables, correct derivation, byte-loop remainder, tests cover mod-8 lengths). (e) every publishTemp has a preceding verifier; weak: A-4, A-3. (f) numeric sort correct; duplicates CONFIRMED (A-1); missing tracks CONFIRMED (A-2); duplicate album.txt lines included twice (plausibly intentional). (g) seed CONFIRMED non-deterministic (A-11).

## Checked and OK
publishTemp backup/restore + unregister on every catch path; temps discarded on error; SilenceSpec/adelay math mirrored; probe windows inside padded regions; -t before -i valid; noiseGenerationSampleRate prevents LUFS loss; LoudnormArgument on all loudnorm strings; BW64 bridge call buffer/size handling correct; hashRename fails closed; same-path guards present.

## Placeholder sweep result
0 in both files.
