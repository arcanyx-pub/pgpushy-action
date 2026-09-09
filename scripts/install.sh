#!/usr/bin/env bash
#
# Fetch the pinned pgpushy release binary, verify it, and put it on PATH.
#
# This mirrors what pgpushy itself does for pgschema (spec §8.5), including
# the two parts that are easy to skip. The expected hash comes from this
# action's own pgpushy.pin, not from the release: a checksum served from the
# same origin as the binary it describes catches a corrupted download and
# nothing else, while a hash reviewed alongside the version bump that added it
# catches a release that changed under its tag. And a cached binary is
# re-verified rather than trusted for being present. An atomic write protects
# against this script's own interrupted downloads and says nothing about what
# else may have touched the tool cache since — which on a hosted runner is a
# fresh disk, and on a self-hosted one is anybody's guess.

set -euo pipefail

fail() {
    echo "::error::pgpushy-action: $1"
    exit 1
}

: "${RUNNER_OS:?}" "${RUNNER_ARCH:?}"
: "${RUNNER_TOOL_CACHE:?}" "${GITHUB_PATH:?}" "${GITHUB_OUTPUT:?}"

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

# One read, of one file: the version this action installs and the hash it must
# have are the same pin, so a runner cannot end up verifying one release
# against another's hash.
pinned=$("$(dirname "${BASH_SOURCE[0]}")/pin.sh" "$platform") ||
    fail "could not read the pinned pgpushy version for $platform"
read -r version expected <<<"$pinned"

asset="pgpushy-$version-$platform"
base="https://github.com/arcanyx-pub/pgpushy/releases/download/v$version"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

dir="$RUNNER_TOOL_CACHE/pgpushy/$version/$platform"
binary="$dir/pgpushy"
mkdir -p "$dir"

# Under the tool cache rather than in /tmp, so that the move into place at the
# end is a rename within one filesystem and therefore atomic. A partially
# copied binary that a later job found and ran is the failure this avoids.
work=$(mktemp -d "$RUNNER_TOOL_CACHE/pgpushy/.tmp.XXXXXX")
trap 'rm -rf "$work"' EXIT

started=$SECONDS
if [ -f "$binary" ] && [ "$(sha256_of "$binary")" = "$expected" ]; then
    echo "pgpushy $version ($platform) is already in the tool cache and still matches the pinned hash"
else
    # A mismatched cache entry is re-fetched rather than executed, so this
    # path covers both "not downloaded yet" and "downloaded, but not what the
    # pin says it is".
    [ ! -f "$binary" ] || echo "::warning::cached $binary does not match the hash pinned in pgpushy.pin; re-downloading"
    echo "Downloading $base/$asset"
    curl --proto '=https' --proto-redir '=https' \
        --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        "$base/$asset" -o "$work/$asset" ||
        fail "could not download $base/$asset"

    actual=$(sha256_of "$work/$asset")
    if [ "$actual" != "$expected" ]; then
        rm -f "$work/$asset"
        fail "$asset failed SHA-256 verification against pgpushy.pin (expected $expected, got $actual); the download has been deleted and nothing was installed"
    fi
    echo "$asset verified: $actual"

    # Move into place only after it verifies, so an interrupted or corrupt
    # download never becomes a cache entry a later run could find.
    chmod +x "$work/$asset"
    mv -f "$work/$asset" "$binary"
fi

chmod +x "$binary"
echo "$dir" >>"$GITHUB_PATH"
{
    echo "pgpushy-path=$binary"
    # Reported as an output so a workflow can print or assert which pgpushy
    # this release of the action brings with it, without reading pgpushy.pin
    # or parsing `pgpushy --version` itself.
    echo "pgpushy-version=$version"
} >>"$GITHUB_OUTPUT"

# The binary states its own version, and it has to be the pinned one: an asset
# served from the wrong place, or a tool cache shared with something else,
# shows up here rather than three steps later as a plan computed by a version
# nobody chose.
reported=$("$binary" --version)
[ "$reported" = "pgpushy $version" ] ||
    fail "$binary reports '$reported', expected 'pgpushy $version'"

echo "Installed $reported at $binary in $((SECONDS - started))s"
