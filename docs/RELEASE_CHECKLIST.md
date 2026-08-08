# Release 1.0 Checklist

Checklist for declaring the converter stable as Release v1.0. Track blockers as linked GitHub issues.

## Build and test validation

- [ ] `swift build --package-path Sources -c release` succeeds on a clean checkout (macOS 14+, Apple Silicon, Swift tools 6.3.3+)
- [ ] `swift test --package-path Sources` passes fully (baseline: 122 tests at `c75929f`)
- [ ] CI workflow (`.github/workflows/ci.yml`) green on the release commit
- [ ] Manual smoke test on representative (non-private) media: `-full`, `-album`, `-short`, `-nfttoshort`, one audio batch action, `-doctor`

## Runtime dependency validation

- [ ] `./converter -doctor` passes on a clean machine
- [ ] Auto-install path verified once with Homebrew present, then re-checked with `CONVERTER_AUTO_INSTALL_DEPS=0 ./converter -doctor`
- [ ] Known-good toolchain versions recorded in `docs/KNOWN_GOOD_VERSIONS.md`

## Documentation completeness

- [ ] README matches current CLI behavior (commands, contracts, standards)
- [ ] `docs/FORMATS.md` matches CLI help text and implementation
- [ ] `config.txt` keys synchronized with `Sources/converter/Config.swift` (supported keys, defaults, validation)
- [ ] `CONTRIBUTING.md`, issue templates, and wiki current

## Release binary handling

- [ ] The checked-in `converter` binary is regenerated from the release commit:
  ```bash
  swift build --package-path Sources -c release
  cp Sources/.build/arm64-apple-macosx/release/converter ./converter
  chmod +x ./converter
  ```
- [ ] Binary verified: `./converter -help`, `./converter -matrix`, `./converter -doctor`
- [ ] Commit message states the binary was intentionally regenerated

## Release mechanics

- [ ] Tag the release commit (`v1.0`) and publish GitHub release notes summarizing changes since the previous baseline
- [ ] Confirm no runtime media or secrets are tracked (`git status` clean, `Output/` ignored except `.gitkeep`)
- [ ] All P1 roadmap issues closed or explicitly deferred with rationale
