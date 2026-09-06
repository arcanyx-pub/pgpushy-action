# The actionlint release this repository lints with. CI pins the same one, so
# a green `just lint` and a green CI job mean the same thing.
actionlint_version := "1.7.12"
actionlint := justfile_directory() / ".actionlint" / "actionlint"

# List available recipes
default:
    @just --list

# Lint the workflows and every script the action runs
lint: _actionlint
    {{ actionlint }} -color
    shellcheck scripts/*.sh

# Fetch the pinned actionlint into .actionlint/ if it is not already there
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
    mkdir -p "$(dirname "{{ actionlint }}")"
    echo "fetching actionlint {{ actionlint_version }} ($os-$arch)"
    curl --fail --silent --show-error --location \
        "https://github.com/rhysd/actionlint/releases/download/v{{ actionlint_version }}/actionlint_{{ actionlint_version }}_${os}_${arch}.tar.gz" \
        | tar xz -C "$(dirname "{{ actionlint }}")" actionlint

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
