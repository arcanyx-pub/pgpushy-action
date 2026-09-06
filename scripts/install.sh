#!/usr/bin/env bash
#
# Fetch the pgpushy release binary, verify it, and put it on PATH.
#
# This mirrors what pgpushy itself does for pgschema (spec §8.5), including
# the part that is easy to skip: a cached binary is re-verified rather than
# trusted for being present. An atomic write protects against this script's
# own interrupted downloads and says nothing about what else may have touched
# the tool cache since — which on a hosted runner is a fresh disk, and on a
# self-hosted one is anybody's guess.

set -euo pipefail

fail() {
    echo "::error::pgpushy-action: $1"
    exit 1
}

: "${VERSION:?}" "${RUNNER_OS:?}" "${RUNNER_ARCH:?}"
version="${VERSION#v}"

# pgpushy publishes binaries for the platforms pgschema does, which is what
# its managed backend can serve (spec §8.5). Windows has no pgschema binary
# and therefore no pgpushy release asset; saying so here is kinder than a 404.
case "$RUNNER_OS" in
    Linux) os=linux ;;
    macOS) os=darwin ;;
    *) fail "$RUNNER_OS is not a platform pgpushy publishes binaries for (Linux and macOS are). pgschema ships no Windows binary, so neither does pgpushy." ;;
esac
case "$RUNNER_ARCH" in
    X64) arch=amd64 ;;
    ARM64) arch=arm64 ;;
    *) fail "$RUNNER_ARCH is not an architecture pgpushy publishes binaries for (X64 and ARM64 are)" ;;
esac

platform="$os-$arch"
asset="pgpushy-$version-$platform"
base="https://github.com/arcanyx-pub/pgpushy/releases/download/v$version"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The release's SHA256SUMS is the authority, so it is fetched on every run,
# cache hit or not: the check is only worth making against a hash that was not
# stored beside the thing it verifies.
started=$SECONDS
curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    "$base/SHA256SUMS" -o "$work/SHA256SUMS" ||
    fail "could not fetch $base/SHA256SUMS — is $version a released pgpushy version?"

# sha256sum format, bare filenames: "<hex>  <name>".
expected=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$work/SHA256SUMS")
[ -n "$expected" ] || fail "SHA256SUMS for v$version lists no $asset"

dir="$RUNNER_TOOL_CACHE/pgpushy/$version/$platform"
binary="$dir/pgpushy"
mkdir -p "$dir"

if [ -f "$binary" ] && [ "$(sha256_of "$binary")" = "$expected" ]; then
    echo "pgpushy $version ($platform) is already in the tool cache and still verifies"
else
    # A mismatched cache entry is re-fetched rather than executed, so this
    # path covers both "not downloaded yet" and "downloaded, but not what the
    # release says it is".
    [ ! -f "$binary" ] || echo "::warning::cached $binary does not match SHA256SUMS; re-downloading"
    echo "Downloading $base/$asset"
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        "$base/$asset" -o "$work/$asset" ||
        fail "could not download $base/$asset"

    actual=$(sha256_of "$work/$asset")
    if [ "$actual" != "$expected" ]; then
        rm -f "$work/$asset"
        fail "$asset failed SHA-256 verification (expected $expected, got $actual); the download has been deleted"
    fi
    echo "$asset verified: $actual"

    # Move into place only after it verifies, so an interrupted or corrupt
    # download never becomes a cache entry a later run could find.
    chmod +x "$work/$asset"
    mv -f "$work/$asset" "$binary"
fi

chmod +x "$binary"
echo "$dir" >>"$GITHUB_PATH"
echo "pgpushy-path=$binary" >>"$GITHUB_OUTPUT"

# The binary states its own version, and it has to be the one that was asked
# for: an asset served from the wrong place, or a tool cache shared with
# something else, shows up here rather than three steps later as a plan
# computed by a version nobody chose.
reported=$("$binary" --version)
[ "$reported" = "pgpushy $version" ] ||
    fail "$binary reports '$reported', expected 'pgpushy $version'"

echo "Installed $reported at $binary in $((SECONDS - started))s"
