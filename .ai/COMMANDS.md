<!--
AI onboarding file.
Mode: bootstrap
Indexed commit: 0ec7e71f0decd52d208c001ec16c4d7382d73fa7
Last generated: 2026-06-25T10:26:41Z
Generator: generic high-end AI coding agent
Purpose: Help future AI sessions understand this repository quickly.
Audience: Any high-capability AI coding agent, regardless of vendor or model family.
Human edits are allowed. Future refreshes should preserve valid human edits.
-->
# Commands

Run commands from the repository root unless noted.

## Install / setup

| Purpose | Command | Notes |
|---|---|---|
| Ensure Swift toolchain | `swift --version` | Repository requires Swift tools 6.0 and macOS 14+ per `Sources/Package.swift`. |
| Install runtime tools manually | `brew install ffmpeg imagemagick` | `ffmpeg` provides `ffmpeg`/`ffprobe`; ImageMagick provides `magick`. |
| Disable runtime auto-install | `CONVERTER_AUTO_INSTALL_DEPS=0 ./converter -doctor` | Fails fast if Homebrew formulae are missing. |
| Check runtime dependencies | `./converter -doctor` | Operational action; may trigger dependency bootstrap unless disabled. |

Evidence:
- `README.md`
- `Sources/Package.swift`
- `Sources/converter/DependencyBootstrap.swift`

## Build

```bash
swift build --package-path Sources -c release
```

To replace the checked-in release binary intentionally:

```bash
cp Sources/.build/arm64-apple-macosx/release/converter ./converter
chmod +x ./converter
```

Do not update `./converter` in a docs-only change.

Evidence:
- `README.md`

## Test

```bash
swift test --package-path Sources
```

Focused tests can normally use SwiftPM XCTest filters, for example:

```bash
swift test --package-path Sources --filter converterTests.testNoArgumentsShowHelpInsteadOfFullRun
```

`inferred`: exact focused-test filter names should be checked with the local SwiftPM/XCTest version if the command fails.

Evidence:
- `README.md`
- `Sources/Package.swift`
- `Sources/Tests/converterTests/converterTests.swift`

## Local development / runtime commands

| Purpose | Command |
|---|---|
| Show help | `./converter -help` |
| Show help via no-arg default | `./converter` |
| List actions | `./converter -list` |
| Show conversion matrix | `./converter -matrix` |
| Dependency check | `./converter -doctor` |
| Full production pipeline | `./converter -full` or `./converter -run` |
| Album production pipeline | `./converter -album` |
| Hash rename | `./converter --hash` |
| Bass default | `./converter -bass` |
| Bass custom/cut | `./converter -bass 80 5` / `./converter -bass 80 -5` |
| Loudness scan | `./converter -loudscan` |
| Loudness normalize | `./converter -loudness` or `./converter -loudness -13` |
| Tail fade | `./converter -fade 10` |
| Cut then fade | `./converter -fadecut 5 10` |
| Truncated fadeout | `./converter -fadeout 1:30 10` |
| Noise padding | `./converter -noise` or `./converter -noise 45` |
| Silence padding | `./converter -silence` or `./converter -silence 45` |
| MP3 to short | `./converter -mp3toshort` |
| M4A to MP4 | `./converter -m4atomp4` |

Evidence:
- `README.md`
- `Sources/converter/CLI.swift`

## Lint / format / typecheck

| Task | Command | Status |
|---|---|---|
| Lint | unknown | No SwiftLint config or lint command found in inspected files. |
| Format | unknown | No formatter config or command found in inspected files. |
| Typecheck | `swift build --package-path Sources` | `inferred`: Swift build performs compilation/type checking. |

## Database migrations

Not applicable based on inspected files. No database, migration directory, Prisma, SQL migration, or ORM config was found.

## Docker / local services

Not applicable based on inspected files. No `Dockerfile` or `docker-compose.yml` was found at checked common paths.

## Release / deploy

Verified release-adjacent command is the local release build and binary copy:

```bash
swift build --package-path Sources -c release
cp Sources/.build/arm64-apple-macosx/release/converter ./converter
chmod +x ./converter
```

No deployment system was found in inspected files.

## Safe docs/onboarding validation

```bash
python -m json.tool .ai/MANIFEST.json >/dev/null
git diff --check
git status --short
```

When direct Git CLI is unavailable, validate generated files locally before committing through repository APIs.
