#!/usr/bin/env bash
#
# Check that pgpushy.pin is well formed — one version, all four platforms, a
# 64-character lowercase hex hash for each — and that the README names the
# version it pins.
#
# Run by `just lint` and by CI, and by `just bump-pgpushy` over what it just
# wrote. This parses the file itself rather than calling scripts/pin.sh: the
# reader's job is to find a hash, this one's is to notice a file that would let
# the reader find the wrong one, and a checker that shared the reader's parse
# would agree with it about anything it got wrong.
#
# Shape only. Whether a hash is the *right* hash is not something any local
# check can answer — CI downloads the four assets and verifies them against
# this file on every run, which is the part that would catch a bad row.

set -euo pipefail

fail() {
    echo "pin-check: $1" >&2
    exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin="$root/pgpushy.pin"
[ -f "$pin" ] || fail "$pin is missing"

# `read` reports failure on a last line with no terminating newline, so a
# reader that only tests its status drops that row while `sha256sum -c` still
# checks it — the two would disagree about what is pinned. Refusing the file is
# cheaper than making every reader handle it.
if [ -n "$(tail -c 1 "$pin")" ]; then
    fail "pgpushy.pin does not end with a newline; its last row would be read by some tools and skipped by others"
fi

# The platforms pgpushy publishes binaries for, which are the platforms
# pgschema publishes binaries for (pgpushy spec §8.5). A pin file missing one
# of them installs nothing on a runner of that shape.
readonly PLATFORMS="linux-amd64 linux-arm64 darwin-amd64 darwin-arm64"

version=""
seen=""
line_no=0

while IFS= read -r line; do
    line_no=$((line_no + 1))
    case "$line" in "#"*) continue ;; esac
    [ -n "$line" ] || fail "pgpushy.pin line $line_no is blank; sha256sum -c reads this file, and a blank line is not a comment"

    # Exactly the shape sha256sum writes: the hash, two spaces, a bare
    # filename. The binary-mode "<hex> *<name>" spelling is refused rather than
    # accepted, so there is one spelling of this file to review.
    [[ "$line" =~ ^[0-9a-f]{64}\ \ (pgpushy-[^[:space:]]+)$ ]] ||
        fail "pgpushy.pin line $line_no is not '<64 lowercase hex>  pgpushy-<version>-<platform>': $line"
    name="${BASH_REMATCH[1]}"

    [[ "$name" =~ ^pgpushy-([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?)-([a-z0-9]+-[a-z0-9]+)$ ]] ||
        fail "pgpushy.pin line $line_no names '$name', which is not pgpushy-<version>-<platform>"
    row_version="${BASH_REMATCH[1]}"
    platform="${BASH_REMATCH[3]}"

    if [ -z "$version" ]; then
        version="$row_version"
    elif [ "$row_version" != "$version" ]; then
        fail "pgpushy.pin line $line_no pins $row_version where an earlier row pins $version; exactly one release is pinned"
    fi

    case " $PLATFORMS " in
        *" $platform "*) ;;
        *) fail "pgpushy.pin line $line_no names platform '$platform', which pgpushy publishes no binary for" ;;
    esac
    case " $seen " in
        *" $platform "*) fail "pgpushy.pin line $line_no repeats $platform" ;;
    esac
    seen="$seen $platform"
done <"$pin"

[ -n "$version" ] || fail "pgpushy.pin lists no release assets, so nothing is pinned"

for platform in $PLATFORMS; do
    case " $seen " in
        *" $platform "*) ;;
        *) fail "pgpushy.pin has no row for $platform, so pgpushy $version could not be installed on a runner of that shape" ;;
    esac
done

# The README states the pinned version in prose, because a reader deciding
# whether to adopt this action should not have to open a checksum file to find
# out what it runs. Two places, so this is the check that keeps them one
# answer: `just lint` fails on a bump that rewrote the rows and left the
# sentence behind.
readme="$root/README.md"
[ -f "$readme" ] || fail "$readme is missing; it names the pinned version too"
grep -qF "installs **pgpushy $version**" "$readme" ||
    fail "README.md does not say 'installs **pgpushy $version**'; its \"Which pgpushy\" section names the pinned version and pgpushy.pin now pins $version"

echo "pin-check: pgpushy.pin pins pgpushy $version, with hashes for$seen, and README.md agrees"
