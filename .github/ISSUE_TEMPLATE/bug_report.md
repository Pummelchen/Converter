---
name: Bug report
about: Report a converter failure or unexpected behavior
title: "[Bug] "
labels: "type: bug"
---

## Command

<!-- Exact command, e.g. `./converter -nfttoshort --src-dir ...` -->

## Inputs

<!-- File types/sizes in SRC_DIR relevant to the command. Do NOT attach private media. -->

## Expected behavior

## Actual behavior

<!-- Include the full terminal error output. -->

## Steps to reproduce

1.
2.

## Tool versions

<!-- Collect with:
swift --version
ffmpeg -version | head -1
magick -version | head -1
sw_vers
-->

## Checklist

- [ ] Reproduced with the checked-in `converter` binary or a fresh `swift build --package-path Sources -c release`
- [ ] `./converter -doctor` output reviewed
- [ ] No private or copyrighted media attached to this report
