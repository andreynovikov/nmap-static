#!/usr/bin/env bash
#
# update-dependency.sh openssl|alpine
#
# Look for a newer patch release of a build input pinned in
# download_sources.sh. If there is one, download it, check its SHA-256
# against every published checksum, and update the pin and the version
# mentions in the docs.
#
# Prints GitHub Actions outputs: changed, name, old, new, branch, title.
# Writes a pull request description to $PR_BODY_FILE (default: pr-body.md).
#
#   openssl  newest openssl-X.Y.* GitHub release for the pinned X.Y line;
#            checksum published on GitHub and on openssl.org
#   alpine   newest minirootfs of the pinned X.Y branch;
#            checksum from latest-releases.yaml and from the .sha256 file
#
# Needs: curl, gh (authenticated), sha256sum.

set -euo pipefail

DEP=${1:?usage: update-dependency.sh openssl|alpine}
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PR_BODY_FILE=${PR_BODY_FILE:-$ROOT/pr-body.md}
cd "$ROOT"

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }
pin() { sed -n "s/^$1=//p" download_sources.sh; }
set_pin() { sed -i "s/^$1=.*/$1=$2/" download_sources.sh; }
# newer OLD NEW: is NEW a later version than OLD?
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]; }
fetch() { curl -fsSL --retry 3 --connect-timeout 30 "$@"; }
# First field of a published checksum file, lowercased.
published_sha() { fetch "$1" | awk 'NR == 1 { print tolower($1) }'; }
# replace_all OLD NEW FILE...: replace a literal string (not followed by a digit).
replace_all() {
    local old=${1//./\\.} new=$2; shift 2
    sed -i -E "s/${old}([^0-9]|$)/${new}\1/g" "$@"
}

case "$DEP" in
openssl)
    name=OpenSSL
    old=$(pin OPENSSL_VERSION)
    line=${old%.*}
    new=$(gh api --paginate repos/openssl/openssl/releases \
            --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
          | sed -n -E "s/^openssl-(${line//./\\.}\.[0-9]+)$/\1/p" | sort -V | tail -n 1)
    [ -n "$new" ] || die "no OpenSSL $line.x releases found"
    if ! newer "$old" "$new"; then
        log "OpenSSL $old is the newest $line.x release"
        echo "changed=false"; exit 0
    fi
    url="https://github.com/openssl/openssl/releases/download/openssl-$new/openssl-$new.tar.gz"
    log "OpenSSL $old -> $new: downloading $url"
    fetch -o "$WORK/tarball" "$url"
    sha=$(sha256sum "$WORK/tarball" | cut -d' ' -f1)
    for sum_url in "$url.sha256" "https://www.openssl.org/source/openssl-$new.tar.gz.sha256"; do
        published=$(published_sha "$sum_url")
        [ "$published" = "$sha" ] \
            || die "SHA-256 mismatch: $sum_url says '${published}', the download is $sha"
    done
    set_pin OPENSSL_VERSION "$new"
    set_pin OPENSSL_SHA256 "$sha"
    replace_all "openssl-$old" "openssl-$new" README.md build_nmap_static.sh
    notes="https://github.com/openssl/openssl/releases/tag/openssl-$new"
    checked="its SHA-256 \`$sha\` matches the checksums published on GitHub and on openssl.org"
    ;;
alpine)
    name=Alpine
    old=$(pin ALPINE_VERSION)
    branch=${old%.*}
    base="https://dl-cdn.alpinelinux.org/alpine/v$branch/releases/x86_64"
    # Each "-" item of latest-releases.yaml is one image; pick the minirootfs.
    read -r new yaml_sha < <(fetch "$base/latest-releases.yaml" | awk '
        function flush() { if (flavor == "alpine-minirootfs") print version, sha; flavor = version = sha = "" }
        /^-/ { flush(); next }
        { gsub(/^[ \t]+|"/, "") }
        /^flavor:/  { flavor = $2 }
        /^version:/ { version = $2 }
        /^sha256:/  { sha = tolower($2) }
        END { flush() }') || true
    [[ "${new:-}" =~ ^${branch//./\\.}\.[0-9]+$ ]] \
        || die "cannot find the Alpine $branch minirootfs in $base/latest-releases.yaml"
    if ! newer "$old" "$new"; then
        log "Alpine $old is the newest $branch.x release"
        echo "changed=false"; exit 0
    fi
    url="$base/alpine-minirootfs-$new-x86_64.tar.gz"
    log "Alpine $old -> $new: downloading $url"
    fetch -o "$WORK/tarball" "$url"
    sha=$(sha256sum "$WORK/tarball" | cut -d' ' -f1)
    [ "$yaml_sha" = "$sha" ] || die "SHA-256 mismatch: latest-releases.yaml says '$yaml_sha', the download is $sha"
    published=$(published_sha "$url.sha256")
    [ "$published" = "$sha" ] || die "SHA-256 mismatch: $url.sha256 says '$published', the download is $sha"
    set_pin ALPINE_VERSION "$new"
    set_pin ALPINE_SHA256 "$sha"
    replace_all "alpine-minirootfs-$old" "alpine-minirootfs-$new" README.md
    notes="https://alpinelinux.org/releases/"
    checked="its SHA-256 \`$sha\` matches \`latest-releases.yaml\` and the published \`.sha256\` file; the build packages are refetched for the new release"
    ;;
*)
    die "unknown dependency: $DEP (expected openssl or alpine)"
    ;;
esac

title="Update $name to $new"
cat > "$PR_BODY_FILE" <<EOF
Updates the pinned $name from $old to $new ([release notes]($notes)).

- The new release was downloaded and $checked.
- \`download_sources.sh\` pins the new version and checksum; the version mentions in the docs follow.
- A test build of the latest nmap release with $name $new passed \`test_nmap_static.sh\` before this pull request was opened.

After this is merged, the release workflow rebuilds the current nmap release with $name $new and publishes it as \`<nmap version>-<build>\`.

<sub>Opened by the dependency update workflow (\`.github/workflows/update-dependencies.yml\`).</sub>
EOF

printf 'changed=true\nname=%s\nold=%s\nnew=%s\nbranch=%s\ntitle=%s\n' \
    "$name" "$old" "$new" "deps/$DEP-$new" "$title"
