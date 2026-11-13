#!/usr/bin/env bash
#
# Copyright (c) 2026 Andrey Novikov
# Licensed under the Nmap Public Source License v0.95; see LICENSE and NOTICE.
#
# plan-release.sh VERSION
#
# Decide whether nmap VERSION needs a build, and under which release tag.
# Prints GitHub Actions outputs: build, tag, previous_tag, inputs, reason.
#
# Every release records its build inputs (the OpenSSL and Alpine versions
# pinned in download_sources.sh) in its notes as
#   <!-- build-inputs: openssl=X alpine=Y -->
# The first release of a version is tagged VERSION. When the pins change
# later, the same nmap version is rebuilt as VERSION-2, VERSION-3, ...
#
# Needs: gh (authenticated), GH_REPO=owner/repo.

set -euo pipefail

VERSION=${1:?usage: plan-release.sh VERSION}
: "${GH_REPO:?GH_REPO must be set}"
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

pin() { sed -n "s/^$1=//p" "$ROOT/download_sources.sh"; }
inputs="openssl=$(pin OPENSSL_VERSION) alpine=$(pin ALPINE_VERSION)"
[[ "$inputs" =~ ^openssl=[0-9][^\ ]*\ alpine=[0-9] ]] \
    || { echo "error: cannot read the pinned versions from download_sources.sh" >&2; exit 1; }

# One line per release: tag, draft flag, recorded build inputs (may be empty).
releases=$(gh api --paginate "repos/$GH_REPO/releases" --jq '.[] | [
    .tag_name,
    (.draft | tostring),
    ((.body // "") | [capture("<!-- build-inputs: (?<i>[^>]*?) -->")] | .[0].i // "")
  ] | @tsv')

# The newest published release of VERSION: build 1 is the bare tag.
last_n=0 last_tag="" last_inputs=""
while IFS=$'\t' read -r tag draft recorded; do
    [ -n "$tag" ] && [ "$draft" = false ] || continue
    if [ "$tag" = "$VERSION" ]; then
        n=1
    elif [[ "$tag" == "$VERSION"-* && "${tag#"$VERSION"-}" =~ ^[0-9]+$ ]]; then
        n=${tag#"$VERSION"-}
    else
        continue
    fi
    if [ "$n" -gt "$last_n" ]; then
        last_n=$n last_tag=$tag last_inputs=$recorded
    fi
done <<<"$releases"

previous=""
if [ "$last_n" -eq 0 ]; then
    build=true tag=$VERSION
    reason="no release of nmap $VERSION yet"
elif [ -z "$last_inputs" ]; then
    # Unknown inputs: never rebuild on a guess.
    build=false tag=$last_tag
    reason="$last_tag does not record its build inputs; not rebuilding"
elif [ "$last_inputs" = "$inputs" ]; then
    build=false tag=$last_tag
    reason="$last_tag is up to date ($inputs)"
else
    build=true tag="$VERSION-$((last_n + 1))" previous=$last_tag
    reason="build inputs changed since $last_tag: $last_inputs -> $inputs"
fi

printf 'build=%s\ntag=%s\nprevious_tag=%s\ninputs=%s\nprevious_inputs=%s\nreason=%s\n' \
    "$build" "$tag" "$previous" "$inputs" "$last_inputs" "$reason"
