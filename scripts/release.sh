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
# Two facts about this build shape the script:
#
#   * The published artifact is the **committed** `converter`, not the one just built. The build is
#     content-deterministic but not bit-reproducible: two canonical builds match in size and code
#     and differ only in the linker's LC_UUID and the ad-hoc signature over it (measured: 85 bytes
#     of 1 715 256). Shipping the committed file keeps the digest, `docs/BINARY_PROVENANCE.md` and
#     CI's `shasum -c` gate pointing at the same bytes.
#   * The build must therefore happen in the canonical location. A `--scratch-path` build is a
#     different binary, not merely a differently-signed one: the probe differed in size and in
#     17 664 bytes, because the module metadata follows the build directory.
#
# Usage: scripts/release.sh            # dry run: build, assert the arch, report the digest
#        scripts/release.sh --publish  # tag and publish, after a clean dry run
set -euo pipefail
cd "$(dirname "$0")/.."

repo=Pummelchen/Converter
asset=converter
checksum=docs/converter.sha256

publish=0
[ "${1:-}" = "--publish" ] && publish=1

die() {
  echo "release: $*" >&2
  exit 1
}

step() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- preconditions (§1.4)

step "preconditions"

# The version is single-sourced. Read it through the gate, so a malformed or half-bumped identity
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

# §1.5.4 — the clean build. A warning scan over an *incremental* build compiles nothing and passes
# vacuously, so the products are removed first: that is what makes this a scratch build, while the
# build itself stays in the canonical location the provenance records.
step "clean release build (warnings are errors)"
rm -rf Sources/.build
log="${TMPDIR:-/tmp}/converter-release-build.log"

if ! swift build --package-path Sources -c release \
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

bin_dir="$(swift build --package-path Sources -c release --show-bin-path)"
built="$bin_dir/$asset"
[ -x "$built" ] || die "no executable at $built"

# §1.2.2 — assert the architecture, do not assume it, on the artifact that will be published.
step "architecture"
for candidate in "./$asset" "$built"; do
  archs="$(lipo -archs "$candidate")"
  [ "$archs" = "arm64" ] || die "lipo -archs on $candidate reports '$archs'; a release must be arm64 only (M1-M6)"
  echo "lipo -archs $(basename "$candidate"): $archs"
done

# ---------------------------------------------------------------- the artifact

# §1.2.5 — never publish a binary without a digest beside it, and never publish bytes other than the
# ones the digest and the provenance record describe.
step "artifact (committed)"
shasum -a 256 -c "$checksum" >/dev/null || die "the committed $asset does not match $checksum"
digest="$(shasum -a 256 "./$asset" | awk '{print $1}')"
bytes="$(stat -f '%z' "./$asset")"
echo "file:    $asset"
echo "SHA-256: $digest"
echo "bytes:   $bytes"

fresh_digest="$(shasum -a 256 "$built" | awk '{print $1}')"
if [ "$fresh_digest" = "$digest" ]; then
  echo "the clean build is bit-identical to the committed binary"
else
  echo "the clean build differs from the committed binary, as expected: the linker's LC_UUID and"
  echo "the ad-hoc signature over it are not reproducible. The committed binary is what ships."
fi

# ---------------------------------------------------------------- dry run stops here

if [ "$publish" -eq 0 ]; then
  step "dry run"
  echo "would tag $tag and publish $repo with the committed $asset ($bytes bytes) and $checksum"
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

rendered="${TMPDIR:-/tmp}/converter-release-notes-${tag}.md"
sed -e "s/SHA256_PENDING/$digest/g" -e "s/ARCHIVE_BYTES_PENDING/$bytes/g" "$notes" >"$rendered"
grep -q "$digest" "$rendered" || die "the rendered notes do not quote the digest"

gh release view "$tag" --repo "$repo" >/dev/null 2>&1 && die "release $tag already exists"

# §1.4 — HEAD is the tag. Create the tag from the clean HEAD when it is absent, and refuse when an
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

gh release create "$tag" "./$asset" "$checksum" \
  --repo "$repo" \
  --title "Converter $version" \
  --notes-file "$rendered" \
  --latest

echo
echo "release: published https://github.com/$repo/releases/tag/$tag"
