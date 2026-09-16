#!/usr/bin/env bash
# RELEASE.md §1.3: the version is single-sourced and enforced, not maintained by hope.
#
# `VERSION` at the repository root is the one authoritative value. Every other declaration is a
# *mirror*, and this gate fails when one disagrees, so a half-done bump cannot be committed and CI
# refuses it on the push.
#
# The mirrors checked here are:
#   * the topmost `## [X.Y]` heading of CHANGELOG.md — the announcement;
#   * the release-notes file `docs/release-notes-vX.Y.md` — the published notes.
# The third declaration is the git tag. Only `scripts/release.sh` can see it, and it refuses to
# publish unless the tag points at HEAD.
#
# Usage: scripts/check-version-sync.sh          # fail on a malformed or mismatched identity
#        scripts/check-version-sync.sh --write  # write the CHANGELOG mirror from VERSION
set -euo pipefail
cd "$(dirname "$0")/.."

version_file=VERSION
changelog=CHANGELOG.md

die() {
  echo "::error::$*" >&2
  exit 1
}

[ -f "$version_file" ] || die "$version_file is missing — it is the single source of the version"

# Command substitution strips the trailing newline; strip any stray blanks so a Windows checkout
# or an editor that pads the file does not read as a malformed version.
version="$(tr -d '[:space:]' <"$version_file")"

# Part 2 fixes this repository's scheme at `vX.Y`: two components, never three. The tag adds the
# `v`, so the file itself must not carry one.
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+$' \
  || die "$version_file holds '$version'; the scheme is X.Y (for example 1.1), and the tag adds the v"

notes="docs/release-notes-v${version}.md"

if [ "${1:-}" = "--write" ]; then
  # "Bump once, propagate mechanically": write the mirror from the authoritative value. The
  # heading's date is preserved, because the date is not part of the identity.
  awk -v v="$version" '
    !done && /^## \[/ { sub(/^## \[[^]]*\]/, "## [" v "]"); done = 1 }
    { print }
  ' "$changelog" >"$changelog.tmp"
  mv "$changelog.tmp" "$changelog"
  echo "wrote $changelog heading from $version_file ($version)"
  exit 0
fi

fail=0

# Mirror 1 — CHANGELOG.md. The topmost version heading is the current one; an older heading
# underneath it is history and is left alone.
heading="$(grep -m1 -E '^## \[[^]]*\]' "$changelog" || true)"
if [ -z "$heading" ]; then
  echo "::error::$changelog has no '## [X.Y]' heading" >&2
  fail=1
else
  # `case` rather than `[ ]`: only `case` does pattern matching, and the heading legitimately
  # carries a trailing date, so this compares the prefix.
  case "$heading" in
    "## [${version}]"*) ;;
    *)
      echo "::error::$changelog's current heading is '$heading', not '## [${version}]'" >&2
      fail=1
      ;;
  esac
fi

# Mirror 2 — the release notes. Their filename carries the version, so a release cannot be cut
# without notes named for it.
if [ ! -f "$notes" ]; then
  echo "::error::release notes $notes do not exist (RELEASE.md §1.8)" >&2
  fail=1
fi

[ "$fail" -eq 0 ] || {
  echo "identity is out of sync; bump $version_file and run scripts/check-version-sync.sh --write" >&2
  exit 1
}

echo "version $version: $version_file, $changelog and $notes agree"
