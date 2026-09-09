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

# The messages name the file rather than this script: they are read in an
# install step's log, where what matters is which file is wrong, and install.sh
# passes them through to the run's error annotation unchanged.
fail() {
    echo "$1" >&2
    exit 1
}

pin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pgpushy.pin"
[ -f "$pin" ] || fail "pgpushy.pin is missing at $pin; it is where the pinned pgpushy version and its hashes live"

platform="${1:-}"

version=""
want=""
seen=""
line=""

# sha256sum format, exactly: "<hex>  pgpushy-<version>-<os>-<arch>", no leading
# whitespace and no binary-mode marker. Comment lines are skipped the way
# `sha256sum -c` skips them, so the same file serves both readers, and anything
# else is fatal rather than skipped: this file decides which bytes get
# executed, so a row it cannot read is one it must not guess at.
#
# The version is taken from the asset names because that is where it is
# written. Two rows naming different versions, or two rows for one platform,
# are a pin file that pins nothing, and are refused rather than resolved.
#
# `|| [ -n "$line" ]` because `read` reports failure on a last line with no
# terminating newline after assigning it, and `sha256sum -c` would still check
# that row. scripts/pin-check.sh refuses such a file outright; this loop reads
# it rather than silently dropping the row in the meantime.
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "#"*) continue ;; esac
    [[ "$line" =~ ^([0-9a-f]{64})\ \ (pgpushy-(.+)-([a-z0-9]+-[a-z0-9]+))$ ]] ||
        fail "pgpushy.pin: not a sha256sum row for a pgpushy release asset: '$line'"
    row_version="${BASH_REMATCH[3]}"
    row_platform="${BASH_REMATCH[4]}"

    if [ -z "$version" ]; then
        version="$row_version"
    elif [ "$row_version" != "$version" ]; then
        fail "pgpushy.pin names two versions, $version and $row_version; exactly one release is pinned"
    fi

    case " $seen " in
        *" $row_platform "*) fail "pgpushy.pin lists $row_platform twice; one row per platform" ;;
    esac
    seen="$seen $row_platform"

    [ "$row_platform" != "$platform" ] || want="${BASH_REMATCH[1]}"
done <"$pin"

[ -n "$version" ] || fail "pgpushy.pin lists no release assets, so nothing is pinned"

if [ -z "$platform" ]; then
    printf '%s\n' "$version"
    exit 0
fi

[ -n "$want" ] ||
    fail "pgpushy.pin carries no hash for $platform, so pgpushy $version cannot be verified on this runner"

printf '%s %s\n' "$version" "$want"
