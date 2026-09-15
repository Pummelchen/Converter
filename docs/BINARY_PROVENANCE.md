# Release binary provenance

`converter` at the repository root is a prebuilt Apple Silicon release binary. This file records
exactly which source and toolchain produced the committed file, so a replacement can be detected
and a rebuild can be compared.

## Current record

| Field | Value |
|---|---|
| File | `converter` |
| Size | 1 696 168 bytes |
| SHA-256 | `75de0aa1f82e5ae7e2d64f9e4e801079fbee96c43baa1f346b8f9e1e3dd0d602` |
| Source commit | `d9aa826c3db6c24084d3b3b870694b42fe31d2c0` |
| Build command | `swift build --package-path Sources -c release -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror` |
| Swift | 6.4 (`swiftlang-6.4.0.34.1`), target `arm64-apple-macosx27.0.0` |
| Xcode | 27.0 (27A266a) |
| macOS | 27.0 (26A428) |
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
# Swift 6.4 moved the products under .build/out/Products/<config>, so ask SwiftPM where they are.
cp "$(swift build --package-path Sources -c release --show-bin-path)/converter" ./converter
chmod +x ./converter
shasum -a 256 converter          # copy the value into docs/converter.sha256 and this table
```

The binary is CPU-generic on purpose (no `-mcpu=` targeting) so it runs on every Apple Silicon Mac;
see `docs/KNOWN_GOOD_VERSIONS.md` for the measurement behind that decision.

## History

| Date | Source commit | SHA-256 | Notes |
|---|---|---|---|
| 2026-09-15 | `d9aa826` | `75de0aa1…dd0d602` | Rebuilt under the Swift 6.4 / Xcode 27 standard at the end of the re-audit; verified with `-help`, `-matrix` and `-doctor`. |
| 2026-09-14 | `7abe547` | `2a8484bb…ea9427e` | First recorded rebuild, after the pre-production audit fixes. |
| (before 2026-09-07) | unknown | `d58901a1d02ee94d6886e77148753503898ee88bee89dae6c1e4f36bd916ddce` | Pre-audit binary committed in `4bb136a`; no build inputs were recorded. |
