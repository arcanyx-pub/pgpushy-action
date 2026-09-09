#!/usr/bin/env bash
#
# Read the pinned pgpushy version, and the SHA-256 expected of one platform's
# binary, out of pgpushy.pin.
#
# Nothing here touches the network. The pin file is what makes this action the
# source of truth for the integrity of the binary it installs: a hash fetched
# from the same origin as the thing it verifies checks for a corrupted
# download, not for a release that changed. pgpushy makes that argument for
# pgschema (spec §8.5); pgpushy.pin makes it for pgpushy.
#
# With no argument this prints the pinned version. With a platform — one of
# linux-amd64, linux-arm64, darwin-amd64, darwin-arm64 — it prints
# "<version> <sha256>" for that platform's asset.

set -euo pipefail

fail() {
    echo "pgpushy-action: $1" >&2
    exit 1
}

pin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pgpushy.pin"
[ -f "$pin" ] || fail "$pin is missing; it is where the pinned pgpushy version and its hashes live"

platform="${1:-}"

version=""
want=""

# sha256sum format: "<hex>  pgpushy-<version>-<os>-<arch>". Comment lines are
# skipped the way `sha256sum -c` skips them, so the same file serves both
# readers. The version is taken from the asset names because that is the only
# place it is written; two rows naming different versions is a pin file that
# pins nothing, and is refused rather than resolved.
while read -r sum name _; do
    case "$sum" in "" | "#"*) continue ;; esac
    [[ "$name" =~ ^pgpushy-(.+)-([a-z0-9]+-[a-z0-9]+)$ ]] ||
        fail "pgpushy.pin: '$name' is not a pgpushy release asset name"
    if [ -z "$version" ]; then
        version="${BASH_REMATCH[1]}"
    elif [ "${BASH_REMATCH[1]}" != "$version" ]; then
        fail "pgpushy.pin names two versions, $version and ${BASH_REMATCH[1]}; exactly one release is pinned"
    fi
    [ "${BASH_REMATCH[2]}" != "$platform" ] || want="$sum"
done <"$pin"

[ -n "$version" ] || fail "pgpushy.pin lists no release assets"

if [ -z "$platform" ]; then
    printf '%s\n' "$version"
    exit 0
fi

[ -n "$want" ] ||
    fail "pgpushy.pin carries no hash for $platform, so pgpushy $version cannot be verified on this runner"

printf '%s %s\n' "$version" "$want"
