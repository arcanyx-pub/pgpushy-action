# The actionlint release this repository lints with. CI pins the same one, so
# a green `just lint` and a green CI job mean the same thing.
actionlint_version := "1.7.12"
actionlint := justfile_directory() / ".actionlint" / "actionlint"

# List available recipes
default:
    @just --list

# Lint the workflows and every script, check the pin file, and run the fixture
# checks
lint: _actionlint
    {{ actionlint }} -color
    shellcheck scripts/*.sh .github/fixtures/*/check.sh
    ./scripts/pin-check.sh
    bash .github/fixtures/comment/check.sh
    bash .github/fixtures/mask/check.sh
    bash .github/fixtures/exit/check.sh

# Pin a different pgpushy release in pgpushy.pin, and print the diff to review
#
# The work is in scripts/bump-pgpushy.sh rather than inline here, because a
# recipe body is the one piece of shell in this repository shellcheck does not
# read, and rewriting the hashes an installed binary is verified against is not
# where to have unchecked shell. It writes the file and stops: a human reviews
# the four hashes beside the version, and CI proves them against the release.
bump-pgpushy version:
    ./scripts/bump-pgpushy.sh {{ version }}

# Fetch the pinned actionlint into .actionlint/ if it is not already there
#
# Pinned by hash and not just by version. This repository's subject is that a
# downloaded binary in CI is a supply-chain step, and a linter fetched on
# nothing but TLS would make that a claim rather than a practice. The hashes
# are actionlint's own published checksums for the pinned release; CI pins the
# same version and the same linux-amd64 hash.
_actionlint:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -x "{{ actionlint }}" ]] && \
       [[ "$("{{ actionlint }}" --version | head -1)" == "{{ actionlint_version }}" ]]; then
        exit 0
    fi
    case "$(uname -s)" in
        Linux) os=linux ;;
        Darwin) os=darwin ;;
        *) echo "no actionlint build for $(uname -s)" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        arm64 | aarch64) arch=arm64 ;;
        *) echo "no actionlint build for $(uname -m)" >&2; exit 1 ;;
    esac
    case "${os}_${arch}" in
        linux_amd64)  want=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
        linux_arm64)  want=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6 ;;
        darwin_amd64) want=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644 ;;
        darwin_arm64) want=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f ;;
    esac
    dir="$(dirname "{{ actionlint }}")"
    mkdir -p "$dir"
    tarball="$dir/actionlint.tar.gz"
    echo "fetching actionlint {{ actionlint_version }} ($os-$arch)"
    curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location \
        "https://github.com/rhysd/actionlint/releases/download/v{{ actionlint_version }}/actionlint_{{ actionlint_version }}_${os}_${arch}.tar.gz" \
        -o "$tarball"
    if command -v sha256sum >/dev/null; then
        got=$(sha256sum "$tarball" | awk '{print $1}')
    else
        got=$(shasum -a 256 "$tarball" | awk '{print $1}')
    fi
    if [[ "$got" != "$want" ]]; then
        rm -f "$tarball"
        echo "actionlint {{ actionlint_version }} ($os-$arch) failed SHA-256 verification" >&2
        echo "  expected $want" >&2
        echo "  got      $got" >&2
        exit 1
    fi
    tar xz -C "$dir" -f "$tarball" actionlint
    rm -f "$tarball"

# Tag vX.Y.Z, move the v<major> tag onto it, and push both
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    # Releasing this action is tagging it: there is nothing to build and
    # nothing to upload, so the tags are the artifact. `vX.Y.Z` is immutable
    # and is what a changelog entry names; `v<major>` moves, and is what
    # consumers actually reference.
    if ! [[ "{{ version }}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "usage: just release <X.Y.Z>" >&2
        exit 1
    fi
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$branch" != "main" ]]; then
        echo "release must be run from main (currently on '$branch')" >&2
        exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "working tree is dirty; commit or stash before releasing" >&2
        exit 1
    fi
    git pull --ff-only
    version="{{ version }}"
    tag="v$version"
    if git rev-parse "$tag" >/dev/null 2>&1; then
        echo "tag $tag already exists; a released version is never re-cut" >&2
        exit 1
    fi
    major="v${version%%.*}"
    if grep -q '^## \[Unreleased\]' CHANGELOG.md; then
        echo "warning: CHANGELOG.md still says '## [Unreleased]'; stamp it with $tag first" >&2
    fi
    git tag -a "$tag" -m "pgpushy-action $tag"
    # Forced, because this is the tag consumers write in their workflows and
    # it has to point at the newest release of this major version.
    git tag -f -a "$major" -m "pgpushy-action $major -> $tag"
    git push origin "$tag"
    git push origin -f "$major"
    echo "Pushed $tag and moved $major onto it."
