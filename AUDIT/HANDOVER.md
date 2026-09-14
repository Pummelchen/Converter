# Handover — audit session 2026-09-13, resumed by a new agent on 2026-09-14

Read this first, then `AUDIT/ledger.md` and `AUDIT/environment.md`. The ledger is the source of
truth; this file says where to resume and how the workflow ran.

## Session change (hard cutover, 2026-09-14)

The original audit session was executed by one AI agent. That session was cut over **cold** to a
new agent (no shared context): this file, the ledger, and the git history are the only memory.
The new agent's job is to finish the ledger, not to re-audit. Everything below was re-verified
against the working tree and `origin` on 2026-09-14 06:58 WIB.

## State at handover (verified 2026-09-14)

- Branch: `audit/2026-09-13`, HEAD `4bd292e` — a merge of `origin/main` (`5e892b6`) into the audit
  tip, **18 commits ahead of `origin/audit/2026-09-13`**. `main` is untouched by the audit itself
  and still at `5e892b6` on the remote. Local `main` ref is stale at `4bb136a` (the merge base).
- The merge adopted `main`'s **MIT LICENSE** (owner decision, "Copyright (c) 2026 André Borchert")
  and the README badge / License / Contact sections, and kept the audit's libbw64 attribution
  section from #0028. **This resolves the #0029 licence blocker** — it only needed a ledger entry.
- Ledger (`AUDIT/ledger.json`): 100 tasks — **DONE 48, START 50, PROGRESS 1, BLOCKED 1**.
- **Ledger drift to fix first:** 8 audit fixes are committed on this branch but their ledger rows
  still read START, because they were made with `commit_task.py` and never stamped:
  **#0039, #0042, #0064, #0065, #0076, #0083, #0084, #0085**. Each has its own
  `AUDIT/evidence/<id>-before.log` / `-after.log`; they only need a green full suite plus
  `AUDIT/tools/mark_done.py`.
- Last *verified* full suite before those 8 fixes: `AUDIT/evidence/0019-0024-fullsuite.txt`
  (177 tests) and the #0043/#0047/#0052/#0081 batch suite (226 tests, 0 failures) in `8bc9f07`.
  A fresh suite is being captured for the 8 pending tasks as
  `AUDIT/evidence/0039-0085-fullsuite.txt`.
- Wiki `Audit-Tracker` is **stale** (says 44 done; ledger says 48). It is generated from the
  ledger by `AUDIT/tools/render_wiki.py` — regenerate and push after the next stamp.
- Environment: Swift 6.3.3, ffmpeg 9.0.1, ImageMagick 7.1.2-31, swiftlint + periphery present.
  Remove `Sources/.build` before a fresh build if it carries a module cache from the old path
  (the project folder was moved into `Downloads/Converter/Converter`, which invalidates it).
- Working tree clean; no stash; the five `Converter-wt/*` worktrees are stale/unregistered
  (`git worktree list` marks them *prunable*) and are not usable without re-creating them.

## Progress since resume (2026-09-14, new agent)

- Merged `origin/main` (`4bd292e`): adopted the owner's MIT LICENSE and the README
  badge/License/Contact sections and kept the audit's libbw64 attribution — **#0029 resolved**.
- Stamped the 8 drifted fixes (**#0039, #0042, #0064, #0065, #0076, #0083, #0084, #0085**) DONE
  after a 235-test full suite, and closed **#0005** (wiki tracker) against the pushed page.
- Batch 2 DONE after a 238-test full suite: **#0053** (empty colon-separated timecode components),
  **#0078** (regular file at OUT_DIR), **#0079** (signal deaths named), **#0091** (stale ignore
  entry), **#0092** (FORMATS.md maintenance commands + `-fadeflac`).
- Ledger after batch 2: **done 63 · open 37 · blocked 0**. Both repos are pushed.
- Batch 3 DONE after a 242-test full suite: **#0054** (`-mp4toshort` re-ingested its own
  `_Short_CenterCut`/`_Short_FullSong` companions), **#0057** (EXIF-rotated phone JPEGs were
  classified by stored pixels, not displayed geometry; squares now warn), **#0060** (the author's
  personal `album.txt` replaced by a documented, git-ignored `album.example.txt`).
- Ledger after batch 3: **done 66 · open 34 · blocked 0**.
- Batch 4 DONE after a 245-test full suite: **#0056** (`-mp4toshort` used ffmpeg's default
  scaler), **#0055** (fitted portrait still sharpened already-processed masters and a user
  `Vertical_8K.png`), **#0041** (installer subprocesses had no timeout and discarded stderr;
  installer runner now lives in `Sources/converter/DependencyInstaller.swift`).
- Ledger after batch 4: **done 69 · open 31 · blocked 0**. swiftlint is 530/56 (one below the
  531 baseline).
- Batch 5 DONE after a 247-test full suite: **#0040** (a cancelled fan-out left sibling
  ffmpeg/magick processes running; ProcessRunner now tracks live children and the permit helpers
  terminate them on cancellation), **#0087** (CLI accepted `--seed 0`, unbounded `--sharpness`,
  a second action flag and option-like option values).
- Ledger after batch 5: **done 71 · open 29 · blocked 0**.
- Batch 6 DONE after a 249-test full suite: **#0050** (the loudness fallback excused every
  true-peak issue and labelled the result "closest-safe"; it now only excuses a peak the render
  did not add, with 0.3 dB of MP3 headroom, and the label comes from the issue set), **#0077**
  (the post-install failure message listed nothing when a tool was present but failed its
  `-version` probe).
- Ledger after batch 6: **done 73 · open 27 · blocked 0**. swiftlint is 528/56 (three below the
  531 baseline).
- Batch 7 DONE after a 251-test full suite: **#0100** (`stepFull` now preflights the source before
  `resolveFullAudio` renames it to `1_source`; the rename helper stays a pure resolver so the
  naming tests keep driving it), **#0080** (temp names carry a host token, so orphan cleanup no
  longer deletes another machine's live temp in a synced directory).
- Ledger after batch 7: **done 75 · open 25 · blocked 0**. swiftlint is 526/56.
- Batch 8 DONE after a 252-test full suite: **#0088** (`VIDEO_MP4_SCALE_FILTER` and the
  `VIDEO_COLOR_*` values are validated against allow-lists / a token charset instead of only
  non-empty, closing a filter-graph injection), **#0090** (the BW64 bridge's two path parameters
  are separated by the numeric options so a swap cannot compile, and equal input/output is
  refused before the writer truncates the source).
- Ledger after batch 8: **done 77 · open 23 · blocked 0**.
- Batch 9 DONE after a 253-test full suite: **#0089** (every full run decoded its own ALAC M4A
  into a 96 kHz WAV and re-encoded it for all five videos; a stream copy is now used when the
  source already matches the project's ALAC sample format, raw bit depth, rate and channels).
- Ledger after batch 9: **done 78 · open 22 · blocked 0**. swiftlint is 526/56.
- Next planned batch (test quality, mostly test-only changes — use a deliberate mutation to show
  the weak test passes and the strengthened one fails): **#0069** (bare `XCTAssertThrowsError` on
  a garbage MP3), **#0096** (SchedulerProfile asserted through its summary string), **#0095**
  (progress-event count pinned to `== 6`), **#0093** (10 s wall-clock budget on the shell-loop
  test), **#0094** (help-text tests couple to prose), **#0098** (bass filter string pinned
  without a stated reason). Then **#0074/#0075** (dead code), **#0066–#0068** (test gaps), and
  S0 **#0006** (Phase E on `node1`) once the tree is frozen.
- Investigated but deliberately deferred: **#0086** (the 3-byte width in `estimateWAVBytes` is
  latent because `Config.validate` pins `WAV_CODEC` to `pcm_s24le`; only the BW64 free-space gap
  is real — fold it into a later perf/validation pass), **#0051** (needs a counting runner to
  assert fewer ffmpeg invocations).
- Next planned batch: **#0088** (validate `VIDEO_MP4_SCALE_FILTER` / `VIDEO_COLOR_*` instead of
  only non-empty), **#0090** (easily swappable C ABI parameters), **#0089** (ALAC audio decoded and
  re-encoded for every video), then the test-quality batch #0093–#0098.

## Exactly where to continue

1. Finish the in-flight full suite; if green, stamp the 8 pending tasks DONE via
   `AUDIT/tools/mark_done.py "#0039,#0042,#0064,#0065,#0076,#0083,#0084,#0085" <suite-log>`.
2. Move **#0029** BLOCKED → DONE (MIT LICENSE now present, cites `4bd292e`).
3. Re-render the ledger (`AUDIT/tools/render_ledger.py`) and the wiki tracker
   (`AUDIT/tools/render_wiki.py ../Converter.wiki/Audit-Tracker.md`); commit and push both.
4. Continue the open S1 list: **#0006** (S0, Phase E fresh-clone verification on `node1`) and
   **#0030** (docs/CLI-help/README/wiki sync — do LAST among S1, it must describe final behaviour).
5. Then S2 in id order (#0040, #0041, #0050, #0051, #0053–#0075), then S3 (#0077–#0100).
   Note: #0039, #0042, #0064, #0065, #0076, #0083–#0085 are already fixed and only need stamping.
6. When the ledger is fully DONE, merge `audit/2026-09-13` into `main` and push (open the PR from
   the branch first only if the owner wants review; the handover contract allows a direct merge
   once Phase E passes). Re-check README/wiki after that push.

## Branch policy (owner instruction, 2026-09-14)

- Do **not** create new branches.
- Commit to the remote after every major task; the audit branch is the working branch until the
  ledger is complete, then it merges to `main`.
- After any push, check whether the README and the wiki pages need updating, and refresh the
  wiki project tracker (this page's companion, `Audit-Tracker`).

## Workflow that was used (keep it)

Per task: write the test(s) → run them on the unfixed code and save the log to
`AUDIT/evidence/<id>-before.log` → implement → run targeted tests → **swiftlint before launching
any suite** (`swiftlint lint --quiet --reporter json Sources/converter Sources/Tests`, total must
be ≤ 535 / errors ≤ 56; wrap only lines you added) → commit with
`python3 AUDIT/tools/commit_one.py "#00NN" <msgfile> TEST "<fix summary>" "<evidence>" <files…>`
(it stamps the SHA in a follow-up ledger commit) → after 2–4 tasks run the full suite and mark
DONE. Commit messages: `audit(#id): title` + What/Why/Evidence + the Co-Authored-By line.

Gotchas learned:
- Never run two SwiftPM commands against `Sources/.build` at once; a stray `pkill xctest` also
  kills sanitizer runs in other scratch paths.
- Do not edit sources while a full suite you intend to cite is running.
- `git commit --amend` after stamping a SHA creates dangling references; the two-commit stamp in
  `commit_one.py` avoids that.
- File-level staging cannot split a file shared by two tasks; either commit tasks that share
  hunks together (say so in the ledger) or reconstruct intermediate file versions (see the
  album-group commit `8fac9dc`).
- The test workspace config tolerates 1 000 000 clipped samples and 0 dBTP; tests of QC
  behaviour must override those keys.
- ffmpeg's `sine` source sits near −21 dBFS and clips internally; +20 dB ≈ −1 dBFS.
- Unknown-encoder ladders fail before the loop (`requireAvailableEncoderLadder`); to exercise the
  loop use real encoders with `VIDEO_MP4_SOFTWARE_PRESET=no_such_preset`.
- A 1 MB RAM disk works unprivileged: `hdiutil attach -nomount ram://2048`, `newfs_hfs`,
  `diskutil mount`; detach with `hdiutil detach <dev> -force`.
- The remote URL carries the PAT, so `git fetch` logs a harmless
  `failed to store: -25308` from the osxkeychain helper; the fetch/ls-remote still succeeds.

## Decisions taken (document in #0030 / wiki)

- Full run renames the source to `1_source.<ext>` (whole family, companions to
  `1_source_RF64/_BW64.<ext>`); deliverables are `1.*`; the source is never written to.
- `--output-file` is only accepted by single-output actions.
- `-mp3clean` is a verified stream copy (keeps bitrate/rate); `-master` / `-flactoalbum` /
  `-album` ignore the pipeline's own outputs; album.txt misses are errors.
- Homebrew self-install is pinned + SHA-256 verified (update both constants together).
- Unknown options and stray positionals are errors.
- Licence: **MIT** (owner chose it on `main`; adopted here by the `4bd292e` merge).
