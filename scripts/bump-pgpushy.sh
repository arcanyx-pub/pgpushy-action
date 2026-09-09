#!/usr/bin/env bash
#
# Rewrite pgpushy.pin for a different pgpushy release: download the four
# binaries, hash them, and refuse unless the release's own SHA256SUMS and
# GitHub's per-asset digests both agree with what was computed here.
#
# The three sources are not three authorities — SHA256SUMS and the API digest
# both come from the same origin as the asset, so a release that was replaced
# wholesale would be internally consistent. They are a cross-check against the
# ordinary failures: a truncated download, a stale asset left behind by a
# half-finished release run, a version typed wrong. What makes the pin worth
# something is the two steps after this one: a human reviews four hashes in a
# diff beside the version they belong to, and CI verifies them against the
# release on every run.
#
# So this writes the file and stops. It does not commit: a script that both
# fetched the hashes and committed them would make the review a formality, and
# the review is the mechanism.

set -euo pipefail

fail() {
    echo "bump-pgpushy: $1" >&2
    exit 1
}

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "usage: just bump-pgpushy <X.Y.Z> (a released pgpushy version, e.g. 0.3.2)"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin="$root/pgpushy.pin"
[ -f "$pin" ] || fail "$pin is missing"

# The output of this recipe is a diff for a human to read, so it starts from a
# tree where the only diff will be the one it wrote.
[ -z "$(git -C "$root" status --porcelain)" ] ||
    fail "working tree is dirty; commit or stash first, so the diff this prints is only the pin"

command -v gh >/dev/null ||
    fail "gh is not on PATH; the per-asset digests are read from the GitHub API with it"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# The platforms pgpushy publishes binaries for, in the order they are written
# to the pin file.
platforms=(linux-amd64 linux-arm64 darwin-amd64 darwin-arm64)
base="https://github.com/arcanyx-pub/pgpushy/releases/download/v$version"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The API rather than the release page: `digest` is what GitHub computed when
# the asset was uploaded, and it is the one of the three that is not a file
# somebody could have attached to the release afterwards.
if ! gh api "repos/arcanyx-pub/pgpushy/releases/tags/v$version" \
    --jq '.assets[] | "\(.name) \(.digest)"' >"$work/digests" 2>"$work/gh.err"; then
    echo "bump-pgpushy: gh said: $(tr '\n' ' ' <"$work/gh.err")" >&2
    fail "could not read the GitHub release v$version — is that version published?"
fi

echo "Fetching pgpushy v$version"
curl --proto '=https' --proto-redir '=https' \
    --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    "$base/SHA256SUMS" -o "$work/SHA256SUMS" ||
    fail "could not fetch $base/SHA256SUMS — is v$version released?"

: >"$work/rows"
for platform in "${platforms[@]}"; do
    asset="pgpushy-$version-$platform"
    curl --proto '=https' --proto-redir '=https' \
        --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        "$base/$asset" -o "$work/$asset" ||
        fail "could not download $base/$asset — the release publishes a binary for every platform this action installs on"

    computed=$(sha256_of "$work/$asset")
    # sha256sum format, bare filenames: "<hex>  <name>".
    published=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1; exit }' "$work/SHA256SUMS")
    api=$(awk -v name="$asset" '$1 == name { sub(/^sha256:/, "", $2); print $2; exit }' "$work/digests")

    [ -n "$published" ] || fail "the release's SHA256SUMS lists no $asset"
    [ -n "$api" ] || fail "release v$version has no asset named $asset"

    if [ "$computed" != "$published" ] || [ "$computed" != "$api" ]; then
        echo "  computed   $computed" >&2
        echo "  SHA256SUMS $published" >&2
        echo "  GitHub API $api" >&2
        fail "$asset: the three hashes disagree; nothing has been written"
    fi

    printf '%s  %s\n' "$computed" "$asset" >>"$work/rows"
    echo "  $asset $computed"
done

# The comment block is prose about why this file exists and says nothing about
# which version is pinned, so it is carried over and only the four rows are
# rewritten.
{
    grep '^#' "$pin"
    cat "$work/rows"
} >"$work/pgpushy.pin"
mv "$work/pgpushy.pin" "$pin"

# The same check `just lint` and CI run, over what was just written: a bump
# that produced a file the linter would reject should fail here, not there.
"$root/scripts/pin-check.sh"

if git -C "$root" diff --quiet -- pgpushy.pin; then
    echo "pgpushy.pin already pins pgpushy $version, byte for byte; nothing changed."
    exit 0
fi

echo
git -C "$root" --no-pager diff -- pgpushy.pin
echo
echo "Review the four hashes together with the version, then commit pgpushy.pin"
echo "and open a pull request. CI downloads the four assets and verifies them"
echo "against this file, and the e2e job runs the action against pgpushy v$version."
