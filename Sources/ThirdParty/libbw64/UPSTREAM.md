# Vendored: libbw64

| | |
|---|---|
| Upstream | https://github.com/ebu/libbw64 |
| Version | tag `0.10.0` = commit `3a43b909f7e8f6bef93403816e9b73b8bfa5a133` (2019-01-21), the latest upstream release |
| License | Apache License 2.0 (`LICENSE` in this directory, byte-identical to upstream: `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`) |
| Consumed by | `Sources/BW64Bridge` (in-process BW64 writer used for the `*_BW64.wav` archival deliverable) |

Header-only; only the `bw64/` headers are used.

## Local modifications

Two headers are **not** verbatim, one declaration each:

| File | Change | Why |
|---|---|---|
| `bw64/writer.hpp:49` | `Bw64Writer(const char*, uint16_t channels, uint16_t sampleRate, …)` → `uint32_t sampleRate` | upstream stores the rate as `uint32_t` (`bw64/chunks.hpp:120,182`), so the `uint16_t` parameter silently truncated any rate above 65 535 before it reached the chunk |
| `bw64/bw64.hpp:50` | `writeFile(…, uint16_t sampleRate = 48000u, …)` → `uint32_t sampleRate` | same truncation, on the convenience entry point `BW64Bridge` calls |

`bw64/version.hpp` is also local: upstream has no such header (the version comes from
`project(libbw64 VERSION 0.10.0)` in its `CMakeLists.txt`). Our copy mirrors that metadata
(`LIBBW64_VERSION "0.10.0"`, build date `2019-01-21T15:45:52`, the commit time of `3a43b90`).

Everything else — `bw64/parser.hpp`, `bw64/chunks.hpp`, `bw64/reader.hpp`, `bw64/utils.hpp` and
`LICENSE` — matches upstream `0.10.0` byte for byte (verify with `shasum -a 256` against the tag
tarball; the file list above is what a refresh must keep).

## Refreshing to a newer tag

1. Download the tag and compare every header under `bw64/` against this directory
   (`git diff --no-index`) to see the upstream delta.
2. Re-apply the two `uint32_t sampleRate` widenings if upstream still declares `uint16_t`, and
   update `bw64/version.hpp` from the new tag's CMake version and commit date.
3. Record the new tag, commit SHA and date in the table above, and note any dropped patch.
