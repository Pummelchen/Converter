# Security Policy

## Supported versions

Converter's latest numbered release is v1.0. Security fixes land on `main`, and the checked-in
`converter` binary at the repository root is rebuilt from `main` when a fix affects it. Only the
current `main` and the binary built from it are supported.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability reporting for this
repository (Security tab → "Report a vulnerability"). Do not open a public issue for a security
problem.

Include the converter commit or binary hash, the command line, the input files' formats and a
minimal reproduction where possible. Media files are not needed unless the problem depends on
their content.

You can expect an acknowledgement within 7 days and a status update within 30 days. Accepted
reports are fixed on `main` and noted in `docs/KNOWN_GOOD_VERSIONS.md`; declined reports get a
written reason.

## Scope notes

- Converter executes external tools (`ffmpeg`, `ffprobe`, `magick`) on the media you place in
  `Output/`; treat untrusted media as untrusted input to those tools.
- Dependency auto-install is off by default. With `CONVERTER_AUTO_INSTALL_DEPS=1` the tool runs
  `brew install` and, when Homebrew itself is absent, downloads a commit-pinned, SHA-256-verified
  Homebrew installer and executes it. See `README.md`.
