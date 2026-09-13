# Reviewer report: BW64 bridge (L3/L4) and repository/docs (L0/L7) — raw, 2026-09-13

Local ids B-n; ledger ids assigned in ledger.json.

### B-1 | S1 | bw64_bridge.cpp:178-197 (+ libbw64 writer.hpp:298) | Disk-write failures undetectable; bridge validates against a ds64 size it wrote itself
- evidence: `Bw64Writer::write` never checks fileStream_ (badbit on ENOSPC/EIO silent); dataBytes = framesWritten*channels*4 (frames REQUESTED); forceBW64Container writes that into ds64; validateOutput reads numberOfFrames() which libbw64 derives from that same ds64 dataSize → truncated data passes; parseChunkHeaders ends silently at EOF. forceBW64Container flushes but never closes/checks close.
- mitigation keeping it S1: Swift verifier compares duration and full PCM against the source before publish.
- fix: after writer.reset(), locate the data chunk header via reader->chunks() (ChunkHeader.position) and require fileSize == dataPos + 8 + dataBytes + (dataBytes & 1); check stream state after writes; stream.close() + fail() check in forceBW64Container. Optionally patch vendored write() to throw on stream failure (document the patch).
- test: RAM disk 1 MB (hdiutil attach -nomount ram://2048; newfs_hfs) + 4 MB f32le → bridge returns 0 today, 1 with "output size … expected …" after.

### B-2 | S1 | SECURITY.md:1-21 | Unedited GitHub template with fictitious versions (5.1.x/4.0.x; no tags exist) and no reporting channel
- fix: state supported = main + current checked-in binary; reporting via GitHub private vulnerability reporting; response expectation.
- test: grep -c "Use this section" → 2 before, 0 after.

### B-3 | S1 | repo root (no LICENSE) + ThirdParty/libbw64/LICENSE | No project license; Apache-2.0 vendored code and a redistributed binary without attribution/provenance (no upstream commit/tag recorded; only "Import converter project")
- fix: add root LICENSE (owner's choice — BLOCKED-for-human decision on license text), ThirdParty/libbw64/UPSTREAM.md (URL + version/commit), README "Third-party" section.

### B-4 | S1 | README.md:25 vs Actions.swift:209-218 | README says "Your source files keep their own names" and outputs are "named after the audio file"; -full/-run moves the source to 1.<ext> and names outputs 1_*; CLI.swift:664-665 --keep-full-name help ("now preserved by default") compounds it; docs only in KNOWN_GOOD_VERSIONS changelog
- fix: rewrite README:25, add to docs/FORMATS.md:53 and wiki Home/Full-Run-Contract, scope the --keep-full-name help text.

### B-5 | S2 | converter binary, README.md:84, CONTRIBUTING.md:21, bug_report.md:38, RELEASE_CHECKLIST | Checked-in binary has no verifiable provenance (adhoc linker-signed, no SHA-256, no tag, CI never compares); 15 historical versions ≈ 22 MB in git
- fix: record sha256 in docs/KNOWN_GOOD_VERSIONS.md per rebuild; CI release-build + help diff; long term: tagged GitHub Releases built by CI (removal from git is a maintainer decision).

### B-6 | S2 | ci.yml:24,27-32,39-40 | CI not reproducible: actions/checkout by tag, "latest Xcode" selection, brew update + unpinned ffmpeg/imagemagick (an 8→9 ffmpeg jump already happened unplanned)
- fix: pin checkout SHA, explicit DEVELOPER_DIR, print brew versions, fail-fast guard on ffmpeg/ImageMagick major vs recorded baseline.

### B-7 | S2 | album.txt:1-15 (+ AudioPipeline.swift:2063) | Personal track list (1_GB…15_GB) committed as the production order file; for any other user -wavtoalbum/-mp3toalbum emits 15 warnings and fails; README:97 presents it as project config
- fix: git mv album.txt album.example.txt, ignore album.txt, loader error mentions the example; update README/FORMATS/wiki.

### B-8 | S2 | bw64_bridge.cpp:125-141,161 (+ chunks.hpp:155-157, writer.hpp:293-298) | Bridge does not bound `channels`; libbw64 uint16 blockAlignment wraps (channels=16384, 32-bit → 0) → empty rawDataBuffer_, &buf[0] UB, heap overflow in encodePcmSamples; unreachable today (config forces 2 channels)
- fix: requireOptions rejects channels*bitDepth/8 > UINT16_MAX and channels > 64.
- test: bridge call with channels 16384 under ASan → heap overflow before, return 1 after.

### B-9 | S3 | libbw64 reader.hpp:220,225,227 | -Wsign-compare hits are benign (line 220 only when frameOffset<0; 225/227 failed tellg() → UINT64_MAX → seeks to end; bridge only uses seek(0) after successful parse)
- fix: compile vendored dir as system headers (`-isystem` via unsafeFlags) OR patch with explicit casts and a tellg() < 0 check; document either way.

### B-10 | S3 | include/bw64_bridge.h:14-22 | bugprone-easily-swappable-parameters: swapping the two paths would truncate the source PCM (writer opens output with fstream::out); sole Swift caller is correct
- fix: struct bw64_write_request with named fields, or NOLINT with rationale.

### B-11 | S3 | .gitignore:2 | Stale `.converter_bw64_writer` entry (external writer removed)
- fix: delete the line.

### B-12 | S3 | docs/FORMATS.md vs CLI.swift | -doctor, -clean, -matrix, -help, -list and the -fadeflac alias absent from FORMATS.md
- fix: Maintenance table + alias note.

### B-13 | S3 | config.txt vs Config.swift:108,235-237 | PREFLIGHT_SECONDS, DURATION_TOLERANCE_SEC, CRC_CHUNK_BYTES missing from config.txt (same as V-14)
- fix: add with defaults and comments.

### B-14 | S3 | CONTRIBUTING.md:59 vs README.md:90 | "Operational commands may auto-install missing Homebrew formulae" contradicts off-by-default contract and omits curl|bash warning
- fix: reword to "only when CONVERTER_AUTO_INSTALL_DEPS=1; never broaden".

### B-15 | S3 | bw64_bridge.cpp:95 | Dead conditional `fileSize >= 8 ? fileSize - 8 : 0` (fileSize < 48 already threw)
- fix: simplify.

## Checked and OK
Exceptions never cross the C ABI (catch std::exception + catch(...)). Error buffer NUL-terminated and truncated safely; Swift side decodes correctly; ABI types match. Partial reads handled via gcount/eof; non-multiple-of-frame input throws; zero frames throws. uint64 arithmetic bounded by config. Fixed-offset rewrite verified against libbw64 layout (RIFF 12 B, JUNK 8+28 at 12, fmt at 48, chna at 72, data at 84); also correct on the >4 GB path. RAII on all paths. Only reinterpret_cast<char*>; memcpy for fourCC. Native-LE assumption valid for arm64 macOS. No media in git history; 99 commits; no Package.resolved needed; test counts consistent (74+85=159); CI sets auto-install 0; binary embeds no absolute /Users paths; no secrets in historical deletions.

## Placeholder sweep result
3 on shipped paths: SECURITY.md template (B-2), album.txt personal list (B-7), stale .gitignore entry (B-11). Borderline: CLI.swift:665 changelog wording "now preserved by default" (B-4).

## Docs-vs-code mismatch table
| claim | where | actual | where |
|---|---|---|---|
| source files keep their names / named after the audio file | README.md:25 | moved to 1.<ext>, outputs 1_* | Actions.swift:209-217 |
| --keep-full-name "now preserved by default" | CLI.swift:664-665 | not for -full | Actions.swift:209 |
| may auto-install | CONTRIBUTING.md:59 | only with CONVERTER_AUTO_INSTALL_DEPS | DependencyBootstrap.swift:86-91 |
| supported versions 5.1.x/4.0.x | SECURITY.md | no versions/tags | git tag |
| prebuilt binary ships / reproduce with binary | README.md:84, bug_report.md:38 | adhoc-signed, no checksum, no release | codesign -dvv |
| centralized settings | config.txt:1-3 | 3 keys absent | Config.swift:108 |
| FORMATS aligned with CLI help | FORMATS.md:3 | 5 commands + alias missing | CLI.swift:3-58,124 |
| vendored libbw64 | README.md:94 | Apache-2.0 v0.10.0, no upstream ref | ThirdParty/libbw64 |
| 159 tests | README/CONTRIBUTING | consistent | tests |
