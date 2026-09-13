# Handover — audit session 2026-09-13 (moved to another computer)

Read this first, then `AUDIT/ledger.md` and `AUDIT/environment.md`. The ledger is the source of
truth; this file says where to resume and how the workflow ran.

## State at handover

- Branch: `audit/2026-09-13` (pushed to origin). `main` is untouched since `4bb136a`. No PR yet.
- Ledger: 100 tasks. 25 DONE, 1 BLOCKED (#0029 licence, owner decision), 2 in TEST awaiting a full
  suite (#0020, #0021), 1 PROGRESS (#0026, written and compiling, unverified), 71 START.
  Both S0 defects are fixed and committed (#0007 source overwrite, #0008 --output-file).
- Last verified full suite: `AUDIT/evidence/0019-0024-fullsuite.txt` — 177 tests, 0 failures, 0
  warnings, on the tree at commit `7a3f7b7`+ledger. Since then #0020, #0021 (committed, targeted
  tests green) and #0026 (WIP) changed sources; the batch suite for #0020/#0021 was interrupted at
  52 passed / 0 failed.
- Baseline (never regress): `AUDIT/baseline.md`. swiftlint accepted level is **535/56** (533/56
  baseline + 3 justified `inclusive_language` hits on identifiers containing "master"; see #0048).
- Wiki `Audit-Tracker` page mirrors the ledger (regenerate with `AUDIT/tools/render_wiki.py`).

## Exactly where to continue

1. Fresh machine setup: `brew install swiftlint periphery gitleaks trufflehog semgrep cppcheck`
   (see `AUDIT/environment.md`; Xcode 26.6 / Swift 6.3.3 / ffmpeg 9.0.1 / ImageMagick 7.1.2 as on
   the fleet). Clone the wiki: `git clone https://github.com/Pummelchen/Converter.wiki.git`.
2. `git checkout audit/2026-09-13`, build: `swift build --package-path Sources --build-tests -Xswiftc -warnings-as-errors`.
3. Finish **#0026** exactly as its ledger `evidence_after` field describes (failing-before with only
   the .cpp reverted, then after, then `--filter BW64`).
4. Run the **full suite** (`swift test --package-path Sources`, ~10 min, serial) and mark
   #0020, #0021, #0026 DONE with the log (`AUDIT/evidence/<ids>-fullsuite.txt`).
5. Continue the S1 list in id order: #0015 (clipped-sample rebase, medium confidence — verify with a
   clipped 48 kHz fixture first), #0030 (docs sync — do LAST among S1 so it describes final
   behaviour; also covers CONTRIBUTING wording, CLI help lines, wiki pages), then the S1 test-gap
   tasks #0031–#0038. Then S2 (#0039–#0076), then S3 (#0077–#0100).
6. Phase E on `node1` from a fresh clone (task #0006), then open the PR from `audit/2026-09-13` to
   `main` and merge only after Phase E passes.

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

## Decisions taken (document in #0030 / wiki)

- Full run renames the source to `1_source.<ext>` (whole family, companions to
  `1_source_RF64/_BW64.<ext>`); deliverables are `1.*`; the source is never written to.
- `--output-file` is only accepted by single-output actions.
- `-mp3clean` is a verified stream copy (keeps bitrate/rate); `-master` / `-flactoalbum` /
  `-album` ignore the pipeline's own outputs; album.txt misses are errors.
- Homebrew self-install is pinned + SHA-256 verified (update both constants together).
- Unknown options and stray positionals are errors.
