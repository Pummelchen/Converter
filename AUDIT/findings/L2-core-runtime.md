# Reviewer report: core runtime (PipelineCore, Support, ProcessRunner, Main, Diagnostics, DependencyBootstrap) — raw, 2026-09-13

Local ids C-n; ledger ids assigned in ledger.json.

### C-1 | S1 | ProcessRunner.swift:139-152 | Timeout sends SIGTERM only; a child that ignores it (or a grandchild holding the pipe) hangs waitUntilExit / waitString forever
- evidence: watchdog calls `process.terminate()` (SIGTERM) then `process.waitUntilExit()`; on timeout `stdoutCapture.waitString()` blocks until pipe EOF. Same shape in DependencyBootstrap.isFunctionalTool:145-153.
- fix: escalate to SIGKILL after a grace period (asyncAfter 5 s, `kill(pid, SIGKILL)` if still running); close the pipe read ends on the timeout path so capture loops exit; consider a process group. Same for isFunctionalTool.
- test: `sh -c "trap '' TERM; sleep 60"` with timeout 1 → must throw "timed out" within ~6 s (hangs today); `sh -c "sleep 60 & wait"` timeout 1 → must not hang on waitString.

### C-2 | S1 | Support.swift:218, :295 | `Int(Double)` traps on large-but-finite user durations (`-silence 1e300`, `-noise`, `-fade`, `-fadeout`, `-fadecut` via ffmpegNumber)
- evidence: `Int((seconds * 1000).rounded())`, `String(Int(value))`; parseFlexibleTimecode accepts any finite non-negative Double; CLI only enforces minimum.
- fix: `Int(exactly:)` in ffmpegNumber and SilenceSpec.delayMilliseconds; add an upper bound in parseFlexibleTimecode (reject absurd durations with a clear AppError).
- test: parseFlexibleTimecode("1e300") throws; SilenceSpec(seconds: huge).delayMilliseconds does not trap.

### C-3 | S1 | DependencyBootstrap.swift:164-176 | Homebrew installer fetched from an unpinned URL (`HEAD`) piped into bash, no integrity check, no pipefail (curl failure → bash exits 0 → misleading "brew not found" error; mid-stream disconnect executes a truncated script)
- fix: download to temp with pinned commit URL, verify SHA-256 (CryptoKit) against embedded constant, then execute; or remove Homebrew self-install and keep only `brew install <formula>`.
- test: refactored installer builder asserts pinned 40-hex commit; mismatched hash → throws before execution (sentinel file absent).

### C-4 | S1 | PipelineCore.swift:711-714 | parseLoudnormJSON slices from the FIRST `{` in stderr; with `-v info` ffmpeg dumps input metadata first, so a tag containing `{` (title "Song {Remix}") corrupts the slice → "loudness probe JSON parsing failed" on a valid file (QC/master step fails)
- fix: locate the loudnorm block from the end: lastIndex of `}` then brace-depth walk backwards to its matching `{` (or the last line that is exactly `{`).
- test: stderr fixture with `title : Foo {Bar}` metadata before a genuine loudnorm JSON block → parses inputI == "-14.20" (throws today).

### C-5 | S2 | Support.swift:97-101,141-147 | AsyncSemaphore.wait fast path and withPermit never check cancellation, so a cancelled async-let sibling still starts a full ffmpeg/magick job after another child failed
- fix: `try Task.checkCancellation()` at top of wait() and after wait() returns in withPermit.
- test: cancel a task, then withPermit inside it → throws CancellationError, closure not run, available restored.

### C-6 | S2 | DependencyBootstrap.swift:216-248 | Installer subprocesses have no timeout and discard all diagnostics (stdout/stderr → /dev/null); HOMEBREW_NO_AUTO_UPDATE unset
- fix: route through ProcessRunner.run with generous timeout, capture stderr for the error, stdin /dev/null, set HOMEBREW_NO_AUTO_UPDATE=1.
- test: fake brew printing "Error: boom" exit 1 → message contains boom; fake brew sleeping 60 → timeout error.

### C-7 | S2 | ProcessRunner.swift:112-124 | Child stdin inherited from the terminal; protection relies on every ffmpeg call site passing -nostdin (32 sites do today); magick/ffprobe/open inherit the TTY
- fix: `process.standardInput = FileHandle.nullDevice` in ProcessRunner.run and isFunctionalTool.
- test: `sh -c "read x; echo got:$x"` → returns immediately with `got:`.

### C-8 | S3 | Support.swift:122-126 | cancelledBeforeSuspension can retain a UUID for a waiter already resumed by signal() (bounded, rare race); no lost permit, no double resume
- fix: track armed ids (insert in wait before continuation, remove in enqueue) and only insert the marker when armed; or rely on checkCancellation from C-5.
- test: signal+cancel loop 1000× → set empty.

### C-9 | S3 | DependencyBootstrap.swift:77-82 | Post-install failure message lists nothing when a tool is present but non-functional (missing computed by isUsableTool, list filtered by isExecutableAvailable)
- fix: filter with !isUsableTool; word "not functional after install".
- test: fake ffmpeg exit 1 + fake brew exit 0 → message names ffmpeg.

### C-10 | S3 | PipelineCore.swift:347,357-362; ProcessRunner.swift:78 | Dead code: second switch re-requires ffmpeg already required for every action; ProcessRunner.fileManager unreferenced (periphery confirms)
- fix: delete both.

### C-11 | S3 | PipelineCore.swift:372-379 | ensureWritableDirectory accepts a regular file at OUT_DIR; failure surfaces later as "Failed to create unique temporary file"
- fix: fileExists(atPath:isDirectory:) → throw "Not a directory".
- test: temp file → throws "Not a directory".

### C-12 | S3 | ProcessRunner.swift:156-160 | Signal deaths reported as ordinary exit codes (SIGSEGV → "exit code 11")
- fix: check terminationReason; format "killed by signal 11 (SIGSEGV)"; carry in ProcessResult.
- test: `sh -c "kill -SEGV $$"` → message contains "signal 11".

### C-13 | S3 | PipelineCore.swift:323-344 | Orphan-temp detection keys on local PID only; a synced directory (Dropbox) shared by two hosts can delete another machine's live temp
- fix: include a host identifier in the run token; skip files whose host segment differs.
- test: foreign-host temp name → not orphaned.

## Verdicts on suspicions
(a) SIGTERM-only hang: CONFIRMED (C-1). (b) semaphore growth: confirmed negligible (C-8); lost permit / double resume: NOT A BUG. (c) symlink inside OUT_DIR: NOT A BUG (publishTemp renames over the link, never writes through; `..` rejected; discovery skips symlinks via isRegularFileKey). (d) kill(pid,0) PID reuse: NOT A BUG (fail-safe direction); cross-host is the only unsafe case (C-13). (e) curl|bash: CONFIRMED (C-3); env leak NOT A BUG. (f) PipeCapture cap deadlock: NOT A BUG (keeps reading and discarding). (g) Logger secrets: NOT A BUG.

## Checked and OK
Nested permits cannot deadlock (inner ≤ outer, holders never await another permit). publishTemp/recoverPublishBackups crash ordering sound. Main defer cleanup on all thrown paths; exit codes honoured. formatCommand display-only. parseFlexibleTimecode rejects inf/nan. ProbeCache no stale-hit path found.

## Placeholder sweep result
0 markers in the six files (two prose uses of "placeholder"/"stub" describe real behaviour).
