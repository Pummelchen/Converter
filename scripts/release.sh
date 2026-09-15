#!/usr/bin/env bash
# The release mechanism for this repository, per RELEASE.md.
#
# Part 1 is generic and Part 2 is this repository's own section; where they disagree, Part 2 wins.
# Part 2 fixes the artifact as a single executable `converter` plus `docs/converter.sha256` — the
# minimal shape — and the identity as the semantic version `vX.Y` in the root `VERSION` file.
#
# A dry run is the default and touches nothing remote. `--publish` is the explicit flag (§1.2.6):
# it refuses unless every precondition holds, and it never weakens a check to make one pass.
#
# Usage: scripts/release.sh            # dry run: build, assert the arch, report the digest
#        scripts/release.sh --publish  # tag and publish, after a clean dry run
set -euo pipefail
cd "$(dirname "$0")/.."

repo=Pummelchen/Converter
asset=converter
checksum=docs/converter.sha256
provenance=docs/BINARY_PROVENANCE.md
source_commit_recorded_at=8d2a70758a15327d70e5d073f69ffc994772fe2c

publish=0
[ "${1:-}" = "--publish" ] && publish=1

die() {
  echo "release: $*" >&2
  exit 1
}

step() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- preconditions (§1.4)

step "preconditions"

# The version is single-sourced. Read it through the gate so a malformed or half-bumped identity
# stops the release here rather than after a build.
version="$(tr -d '[:space:]' <VERSION)"
scripts/check-version-sync.sh >/dev/null || die "identity is out of sync; see the gate's output above"
tag="v${version}"
notes="docs/release-notes-${tag}.md"
echo "version $version (tag $tag)"

swift --version | grep -q 'Swift version 6.4' \
  || die "this package requires Swift 6.4 (see Sources/Package.swift); found: $(swift --version | head -1)"
echo "toolchain: $(swift --version | head -1)"

# A release is cut from a committed tree: the tag has to name the commit whose bytes are published.
dirty="$(git status --porcelain --untracked-files=no)"
[ -z "$dirty" ] || die "the tree has uncommitted tracked changes; commit or stash them first:
$dirty"

gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
account="$(gh api user --jq .login)"
[ "$account" = "Pummelchen" ] || die "gh is authenticated as '$account', not the repository owner"
echo "gh: $account"

[ -f "$notes" ] || die "release notes $notes do not exist (§1.8)"

# ---------------------------------------------------------------- gates (§1.5)

# The scratch build is the point: a warning scan over an *incremental* build compiles nothing and
# passes vacuously, so this always uses a fresh path (§1.5).
step "clean scratch build (warnings are errors)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/converter-release.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
log="$scratch/build.log"

if ! swift build --package-path Sources --scratch-path "$scratch" -c release \
  -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror >"$log" 2>&1; then
  tail -40 "$log" >&2
  die "the release build failed"
fi

# Match compiler diagnostics only: a bare `grep warning:` also catches SwiftPM notices such as
# "warning: 'swift-system': skipping cache", which would fail the gate misleadingly.
if grep -qE '^[^ ]+\.(swift|metal|c|h|m|mm):[0-9]+:[0-9]+: warning:' "$log"; then
  grep -E '^[^ ]+\.(swift|metal|c|h|m|mm):[0-9]+:[0-9]+: warning:' "$log" >&2
  die "the release build emitted warnings"
fi
echo "release build clean, no compiler warnings"

bin_dir="$(swift build --package-path Sources --scratch-path "$scratch" -c release --show-bin-path)"
built="$bin_dir/$asset"
[ -x "$built" ] || die "no executable at $built"

# §1.2.2 — assert the architecture, do not assume it. A fat binary is a release defect.
step "architecture"
archs="$(lipo -archs "$built")"
[ "$archs" = "arm64" ] || die "lipo -archs reports '$archs'; a release must be arm64 only (M1-M6)"
echo "lipo -archs: $archs"

# ---------------------------------------------------------------- the artifact

step "artifact"
digest="$(shasum -a 256 "$built" | awk '{print $1}')"
bytes="$(stat -f '%z' "$built")"
echo "SHA-256: $digest"
echo "bytes:   $bytes"

committed_digest="$(awk '{print $1}' "$checksum")"
committed_name="$(awk '{print $2}' "$checksum")"
[ "$committed_name" = "$asset" ] || die "$checksum names '$committed_name', not '$asset'"

if [ "$digest" = "$committed_digest" ]; then
  echo "matches the committed $checksum — the binary is unchanged from the last build"
else
  cat >&2 <<EOF
release: the rebuilt binary differs from the committed one.
  committed: $committed_digest
  rebuilt:   $digest ($bytes bytes)

Commit the new binary first, so the tag names the bytes it publishes:
  cp "$built" ./$asset && chmod +x ./$asset
  printf '%s  %s\n' "$digest" "$asset" > $checksum
  # then update the size, source commit and toolchain in $provenance
The record in $provenance currently names $source_commit_recorded_at.
EOF
  [ "$publish" -eq 0 ] || die "refusing to publish a digest that is not the committed one"
  echo "release: dry run only — nothing was published"
  exit 0
fi

# ---------------------------------------------------------------- dry run stops here

if [ "$publish" -eq 0 ]; then
  step "dry run"
  echo "would tag $tag and publish $repo with $asset ($bytes bytes) and $checksum"
  echo "release: dry run complete — nothing was tagged or published"
  exit 0
fi

# ---------------------------------------------------------------- publish (§1.7, §1.8)

step "publishing"

# §1.8 — refuse unless the notes carry the placeholder or already quote the real values. A release
# quoting the wrong digest is worse than one quoting none.
if grep -q 'SHA256_PENDING\|ARCHIVE_BYTES_PENDING' "$notes"; then
  echo "notes: substituting the checksum block"
elif grep -q "$digest" "$notes" && grep -q "$bytes" "$notes"; then
  echo "notes: already quote the current digest and size"
else
  die "$notes carries neither the §1.8 placeholders nor the real digest and size"
fi

rendered="$scratch/notes.md"
sed -e "s/SHA256_PENDING/$digest/g" -e "s/ARCHIVE_BYTES_PENDING/$bytes/g" "$notes" >"$rendered"
grep -q "$digest" "$rendered" || die "the rendered notes do not quote the digest"

gh release view "$tag" --repo "$repo" >/dev/null 2>&1 && die "release $tag already exists"

# §1.4 — HEAD is the tag. Create the tag from the clean HEAD if it is absent, and refuse if an
# existing tag points somewhere else, because then the published bytes are not the tagged source.
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  tagged="$(git rev-list -n1 "$tag")"
  [ "$tagged" = "$(git rev-parse HEAD)" ] \
    || die "$tag already points at $tagged, not HEAD ($(git rev-parse HEAD))"
  echo "tag $tag already points at HEAD"
else
  git tag -a "$tag" -m "Converter $version"
  echo "created annotated tag $tag -> $(git rev-parse --short HEAD)"
fi

git push origin "refs/tags/$tag"

gh release create "$tag" "$built" "$checksum" \
  --repo "$repo" \
  --title "Converter $version" \
  --notes-file "$rendered" \
  --latest

echo
echo "release: published https://github.com/$repo/releases/tag/$tag"
