# Release binary provenance

`converter` at the repository root is a prebuilt Apple Silicon release binary. This file records
exactly which source and toolchain produced the committed file, so a replacement can be detected
and a rebuild can be compared.

## Current record

| Field | Value |
|---|---|
| File | `converter` |
| Size | 1 717 352 bytes |
| SHA-256 | `2a8484bb2eb73161561e6683ca9488d7a859187b11485f8415f035ad6ea9427e` |
| Source commit | `7abe547bb09dc43b22e8eac730828159b4269d2a` |
| Build command | `swift build --package-path Sources -c release` |
| Swift | 6.3.3 (`swiftlang-6.3.3.1.3`), target `arm64-apple-macosx26.0` |
| Xcode | 26.6 (17F113) |
| macOS | 26.6.2 (25G83) |
| Architecture | Mach-O thin `arm64` |
| Signature | adhoc / linker-signed (no Developer ID; the binary is not notarised) |

## Verifying the committed binary

```bash
shasum -a 256 -c docs/converter.sha256
./converter -doctor                # functional smoke test; CONVERTER_AUTO_INSTALL_DEPS=0 to stay offline
```

CI runs the checksum step on every push and pull request, so replacing the binary without updating
`docs/converter.sha256` fails the build.

## Replacing the binary

Follow `CONTRIBUTING.md` ("Release binary updates"), then update both this file and
`docs/converter.sha256` in the same commit:

```bash
swift build --package-path Sources -c release
cp Sources/.build/arm64-apple-macosx/release/converter ./converter
chmod +x ./converter
shasum -a 256 converter          # copy the value into docs/converter.sha256 and this table
```

The binary is CPU-generic on purpose (no `-mcpu=` targeting) so it runs on every Apple Silicon Mac;
see `docs/KNOWN_GOOD_VERSIONS.md` for the measurement behind that decision.

## History

| Date | Source commit | SHA-256 | Notes |
|---|---|---|---|
| 2026-09-14 | `7abe547` | `2a8484bb…ea9427e` | First recorded rebuild, after the pre-production audit fixes. |
| (before 2026-09-07) | unknown | `d58901a1d02ee94d6886e77148753503898ee88bee89dae6c1e4f36bd916ddce` | Pre-audit binary committed in `4bb136a`; no build inputs were recorded. |
