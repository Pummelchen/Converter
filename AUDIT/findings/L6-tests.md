# Reviewer report: L6 tests (raw, 2026-09-13)

Reviewer scope: converterTests.swift, PipelineIntegrationTests.swift, IntegrationTestSupport.swift, cross-checked against Sources/converter. Finding ids here are local (T-n); ledger ids are assigned in ledger.json.

### T-1 | S1 | IntegrationTestSupport.swift:25,133-143 | Integration workspace inherits OUTPUT_DIR/SRC_DIR/OUT_DIR/CONFIG_FILE/DEBUG from the developer's shell
- evidence: `environment = ProcessInfo.processInfo.environment`; makeTool never passes `--output-dir`/`--config`; CLI.swift:91-97 reads OUTPUT_DIR/SRC_DIR/CONFIG_FILE from env. Exported vars redirect every integration test to real user dirs. Unit makeTool passes --output-dir but inherits CONFIG_FILE.
- fix: strip OUTPUT_DIR, SRC_DIR, OUT_DIR, CONFIG_FILE, DEBUG from the workspace environment; makeTool always prepends `--output-dir <workspace>` and `--config <workspace>/config.txt`. Test: env OUTPUT_DIR=/nonexistent → makeTool(["-help"]).cli.outDir == workspace.output.

### T-2 | S1 | converterTests.swift:1259-1278 | publishTemp backup/restore-on-failure branch (PipelineCore.swift:487-505) has no test
- fix: testPublishTempRestoresPreviousVersionWhenMoveFails (remove temp before publish so move fails; assert old content restored, no .publish-backup, error propagates, cleanupTemps ok); second test with read-only parent for the "preserved at" path.

### T-3 | S1 | converterTests.swift:893-905 | requireDirectChild never exercised with `..`, symlinks, or absolute paths
- fix: test rejects "../x.wav", "escape/x.wav" (symlink to elsewhere), absolute path outside outDir; accepts absolute path inside outDir; outDir itself a symlink passes.

### T-4 | S1 | PipelineIntegrationTests.swift:65-81 + ProcessRunner.swift:139-149 | Timeout kill path untested; terminate() is SIGTERM-only, a child ignoring SIGTERM hangs waitUntilExit forever
- fix: production: escalate to SIGKILL after a grace period. Tests: sleep 30 with 0.3 s timeout → throws "timed out" < 3 s; `sh -c "trap '' TERM; sleep 30"` → must also return promptly.

### T-5 | S1 | PipelineIntegrationTests.swift:63-81 | "Drains output beyond the capture cap" test never reaches the 64 MiB cap (168 KB emitted); exceededCap branch unexecuted
- fix: test with `head -c 70000000 /dev/zero | tr '\0' a`; assert stdout.utf8.count == 64 MiB, exit 0, no deadlock.

### T-6 | S1 | Actions.swift:126-154 | `--continue-on-error` batch semantics and failure summary untested (0 test hits)
- fix: a.wav valid, b.wav garbage, c.wav valid; with flag: throws "1 operation(s) failed", a.mp3 and c.mp3 exist; without: c.mp3 absent. Repeat for -loudness (different summary format).

### T-7 | S1 | PipelineCore.swift:842-856 | `-clean` has no test guarding "never deletes user files"
- fix: fixtures `.x.normalized.wav`, `.x.normalized`, `song.normalized.wav`, `.song.wav.publish-backup`, `.converter-tmp.1.foo`, `song.wav`, `notes.log`, `mix.w64`; only the first two removed.

### T-8 | S1 | PipelineIntegrationTests.swift:1969-2025 | Encoder ladder: all-rungs error report and isEncoderIndependent short-circuit untested
- fix: ladder missing_a,missing_b → message contains "All main MP4 encoders failed", both rung names; QC failure with ladder libx264,libx265 → only libx264 attempted.

### T-9 | S1 | PipelineIntegrationTests.swift:1138-1167 | loudnessPreservingQCPolicy has no direct test; the "hot" integration fixture is a plain sine (createAudio not createHotAudio), rebase branch may never fire
- fix: unit test on createHotAudio(gainDB:18): TP ceiling rebased to measured+allowance, untouched ceilings unchanged, name suffix "-source-relative"; segment test with limitDuration:1; change line 1147 to createHotAudio and assert source TP > -1.

### T-10 | S1 | PipelineIntegrationTests.swift:126-146 | Orphan temp cleanup never tested against a live foreign PID / EPERM path
- fix: add temps for getppid() and PID 1 → retained; spawned sleep child → retained while alive, removed after exit.

### T-11 | S2 | converterTests.swift:128-140 | Test sets shortMP4ClipSeconds="0:30" directly, a value Config.validate() rejects; MM:SS form unreachable in production
- fix: decide contract; either accept timecode in requirePositiveDurationString (+load-level test) or test with "30" and add rejection test.

### T-12 | S2 | PipelineIntegrationTests.swift:1860-1900 | Scheduler-limit test can pass vacuously (Thread.sleep on pool threads, only <= assertions)
- fix: Task.sleep, 16 tasks, assert peak == min(profile.image, profile.total), control run with wide profile proves observability.

### T-13 | S2 | converterTests.swift:1473-1550 | AsyncSemaphore tests rely on 80 ms sleeps for ordering; a leaked permit hangs the suite instead of failing
- fix: test-visible waiterCount, spin-wait; wrap final waits in a 1 s timeout helper.

### T-14 | S2 | PipelineIntegrationTests.swift:1627-1637,1738-1748 | Full-pipeline assertions require hevc_videotoolbox; fall back to libx264 makes post-hoc verify(codec: hevc) fail on hosts without HW HEVC
- fix: defaultConfig uses libx264/h264/avc1 for main video in tests; one XCTSkipUnless test for HEVC VT.

### T-15 | S2 | PipelineIntegrationTests.swift:473-491 | "Does not enforce delivery QC" fade-out test never proves the fixture would fail delivery QC
- fix: add XCTAssertThrowsError(verifyMP3Standard(output, qcPolicy: deliveryAudioQCPolicy)).

### T-16 | S2 | PipelineIntegrationTests.swift:1933-1948 | Mastering "fallback" test does not observe which path ran
- fix: expose a MasteringOutcome (or logger sink) and assert .fallback.

### T-17 | S2 | PipelineIntegrationTests.swift:387-392 | Bare XCTAssertThrowsError(convertAudioToMP3(garbage)) accepts any error
- fix: assert message names the preflight failure and broken.mp3 absent.

### T-18 | S2 | ValidationPipeline.swift:658-683,898-975 | Canonical PCM and RIFF/RF64/BW64 parsers lack boundary tests; containsChunk is a naive 64 KiB substring scan (would match "ds64" inside a bext string)
- fix: length-mismatch, channel-mismatch, truncated 8-byte file, WAVX, RIFF-vs-RF64 mismatch tests; BW64 test with "ds64" bytes inside bext but no ds64 chunk must fail → production walks chunks.

### T-19 | S2 | converterTests.swift:737-749 | LoudnormArgument clamping tested past the bounds but not at them
- fix: exact boundaries -70,-5,-9,0,1,50 and rounding-edge cases.

### T-20 | S2 | Config.swift:312-315,447-452 | Config validation: 3 of ~80 keys tested; unknown keys silently ignored; parseInt rejects -1 with "must be an integer"
- fix: table-driven invalid-value test over every rule; decide unknown-key behaviour (recommend reject) and test it.

### T-21 | S2 | CLI.swift:276-279 | Unknown `--flags` silently become positional args; negative option values untested (--sharpness -1 accepted, --seed -1, --num-dots -3, -fade -5 generic message)
- fix: production rejects any actionArg starting with "--"; tests for negative option values with flag-naming messages.

### T-22 | S2 | Actions.swift:875-876 | Short-cap boundary (58.0 / 58.005 / 58.02) and FullSong epsilon untested
- fix: unit boundary tests; integration 58.0 → no FullSong, 58.05 → FullSong.

### T-23 | S3 | Actions.swift:209-218 | normalizedFullRunSource "1.<ext> exists" guard effectively unreachable (rankedFamily throws "found 2" first) and untested
- fix: test Mirage.flac + 1.flac → throws found 2, Mirage.flac untouched; document case-variant behaviour.

### T-24 | S3 | PipelineIntegrationTests.swift:30-50 | 10 s wall-clock budget on a 40 000-iteration shell loop (flaky under load)
- fix: raise to 60 s or generate payload cheaply.

### T-25 | S3 | converterTests.swift:189-230,1297-1309 | Help-text tests couple to prose sentences
- fix: assert flag names and output names only.

### T-26 | S3 | PipelineIntegrationTests.swift:613-619 | Progress-event count pinned to implementation (== 6)
- fix: assert monotone processedFiles, last == total.

### T-27 | S3 | converterTests.swift:108-115 | SchedulerProfile tested via its summary string
- fix: assert fields.

### T-28 | S3 | PipelineIntegrationTests.swift:1902-1911 | -doctor has only a no-throw happy path
- fix: PATH=/nonexistent → names ffmpeg; unwritable output dir → names directory.

### T-29 | S3 | PipelineIntegrationTests.swift:529,534 | Exact ffmpeg bass filter string pinned
- fix: keep as deliberate pin with comment, or assert f=/g= fragments only.

## Checked and OK (reviewer)
No test-only hooks in production sources (grep XCTestConfigurationFilePath|CONVERTER_TEST|XCTest|isRunningTests|UNDER_TEST|SWIFT_TESTING: none). Temp roots UUID-scoped and torn down. Silent fixture is anullsrc. Hot fixture (gain 18/24 dB) exceeds -1 dBTP (asserted at PipelineIntegrationTests.swift:440). Dead-PID fixture 999999 > PID_MAX. VisualSubs seeded generator deterministic. Probe-cache invalidation test changes size. 400-launch fd test above 256 soft limit. CRC vectors external. Canonical PCM scan test places the failing sample last.
