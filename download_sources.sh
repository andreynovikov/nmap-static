#!/usr/bin/env bash
#
# Populate sources/ with everything build_nmap_static.sh needs, downloading
# only what is missing:
#
#   sources/nmap-<version>/            nmap release source
#   sources/openssl-<version>/         OpenSSL release source
#   sources/alpine-<branch>/           Alpine minirootfs tarball
#   sources/alpine-<branch>/apk/       signed build packages + all dependencies
#
# Run it on a machine with internet access, then copy sources/ to the offline
# build machine.
#
# The nmap tarball is checked against its GPG signature by the Nmap Project
# Signing Key (nmap-signing-key.asc, fingerprint pinned below), so any nmap
# release can be fetched with --nmap-version. OpenSSL and Alpine are pinned by
# SHA-256. Downloads go to a temporary directory first and are moved into place
# only when complete, so an interrupted run leaves nothing half-written.
#
# Requirements: bash, curl or wget, gpg, sha256sum, tar, bzip2, gzip; docker
# (only for fetching the Alpine packages).

set -euo pipefail

# --- pinned inputs ------------------------------------------------------------
# nmap release fetched unless --nmap-version is given.
NMAP_DEFAULT_VERSION=7.993
# Nmap Project Signing Key, see https://nmap.org/book/install.html#inst-integrity
NMAP_KEY_FPR=436D66AB9A798425FDA0E3F801AF9F036B9355D0
# OpenSSL and Alpine: change a version together with its SHA-256.
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
ALPINE_VERSION=3.22.8
ALPINE_SHA256=2d7f46af9b7e86ad64ebeba3fe9b75b62dd5b259e708afb2ab21268f627696e5
# Packages for the build container; their dependencies are fetched too.
APK_PACKAGES="build-base linux-headers perl zlib-dev zlib-static"
# -----------------------------------------------------------------------------

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NMAP_KEY="$SCRIPT_DIR/nmap-signing-key.asc"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-n NMAP_VERSION] [SOURCES_DIR]

Downloads whatever build_nmap_static.sh needs and SOURCES_DIR does not have yet
(default: ${SCRIPT_DIR}/sources):

  nmap (default ${NMAP_DEFAULT_VERSION}), OpenSSL ${OPENSSL_VERSION}, Alpine ${ALPINE_VERSION} minirootfs,
  Alpine packages: ${APK_PACKAGES}

Options:
  -n, --nmap-version VER   nmap release to fetch (GPG-verified), e.g. 7.993
  -h, --help               show this help

OpenSSL and Alpine versions and checksums are pinned at the top of this script.
EOF
}

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

NMAP_VERSION=$NMAP_DEFAULT_VERSION
SOURCES=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--nmap-version) [ $# -ge 2 ] || die "$1 needs an argument"; NMAP_VERSION=$2; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        -*)                usage >&2; die "unknown option: $1" ;;
        *)                 [ -z "$SOURCES" ] || die "only one sources directory may be given"
                           SOURCES=$1; shift ;;
    esac
done
[[ "$NMAP_VERSION" =~ ^[0-9]+\.[0-9]+[A-Za-z0-9]*$ ]] || die "invalid nmap version: $NMAP_VERSION"
SOURCES=$(realpath -m -- "${SOURCES:-$SCRIPT_DIR/sources}")

ALPINE_BRANCH=${ALPINE_VERSION%.*}
NMAP_URL="https://nmap.org/dist/nmap-${NMAP_VERSION}.tar.bz2"
NMAP_SIG_URL="https://nmap.org/dist/sigs/nmap-${NMAP_VERSION}.tar.bz2.asc"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
ROOTFS_NAME="alpine-minirootfs-${ALPINE_VERSION}-x86_64.tar.gz"
ROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_BRANCH}/releases/x86_64/${ROOTFS_NAME}"
BASE_IMAGE="nmap-static-base:alpine-${ALPINE_VERSION}"   # same name as build_nmap_static.sh

for tool in gpg sha256sum tar bzip2 gzip; do
    command -v "$tool" >/dev/null || die "$tool is not installed"
done
[ -f "$NMAP_KEY" ] || die "$NMAP_KEY is missing"
if command -v curl >/dev/null; then
    download() { curl -fL --retry 3 --connect-timeout 30 --progress-bar -o "$2" "$1"; }
elif command -v wget >/dev/null; then
    download() { wget -q --show-progress --tries=3 --timeout=30 -O "$2" "$1"; }
else
    die "neither curl nor wget is installed"
fi

mkdir -p -- "$SOURCES"
# Scratch space on the same filesystem, so finished results move in atomically.
WORK=$(mktemp -d -- "$SOURCES/.download.XXXXXX")
CID=""
cleanup() {
    [ -z "$CID" ] || docker rm -f "$CID" >/dev/null 2>&1 || true
    [ ! -d "$WORK/gnupg" ] || gpgconf --homedir "$WORK/gnupg" --kill all >/dev/null 2>&1 || true
    rm -rf -- "$WORK"
}
trap cleanup EXIT

SUMMARY=()

# verify_sha256 SHA256 FILE
verify_sha256() {
    echo "$1  $2" | sha256sum -c --quiet - || die "SHA-256 mismatch for ${2##*/} (expected $1)"
}

# verify_nmap_signature FILE
#   FILE must carry a valid signature by the pinned Nmap Project Signing Key.
#   Uses a throwaway GnuPG home, so the user's keyring is never touched.
verify_nmap_signature() {
    local file=$1 sig="$1.asc" gnupg="$WORK/gnupg"
    log "downloading $NMAP_SIG_URL"
    download "$NMAP_SIG_URL" "$sig" || die "download failed: $NMAP_SIG_URL"
    mkdir -m 700 "$gnupg"
    GNUPGHOME=$gnupg gpg --batch --quiet --import "$NMAP_KEY" 2>/dev/null \
        || die "cannot import $NMAP_KEY"
    GNUPGHOME=$gnupg gpg --batch --with-colons --fingerprint \
        | grep -q "^fpr:::::::::${NMAP_KEY_FPR}:" \
        || die "$NMAP_KEY is not the Nmap Project Signing Key ($NMAP_KEY_FPR)"
    # VALIDSIG's last field is the fingerprint of the signer's primary key.
    GNUPGHOME=$gnupg gpg --batch --status-fd 1 --verify "$sig" "$file" 2>/dev/null \
        | awk -v fpr="$NMAP_KEY_FPR" '$2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }' \
        || die "GPG signature check failed for ${file##*/}"
    log "good signature by the Nmap Project Signing Key"
    gpgconf --homedir "$gnupg" --kill all >/dev/null 2>&1 || true
    rm -rf -- "$gnupg" "$sig"
}

# source_tree NAME URL MARKER_FILE VERIFIER [VERIFIER_ARGS...]
#   Makes sure $SOURCES/NAME exists, from the release tarball at URL, which
#   must unpack to a single NAME/ directory containing MARKER_FILE. The
#   tarball is checked by running: VERIFIER [VERIFIER_ARGS...] TARBALL.
source_tree() {
    local name=$1 url=$2 marker=$3; shift 3
    local dest="$SOURCES/$name"
    if [ -f "$dest/$marker" ]; then
        SUMMARY+=("present     $dest"); return
    fi
    [ ! -e "$dest" ] || die "$dest exists but is incomplete (no $marker); move it away and re-run"

    local tarball="$WORK/${url##*/}"
    log "downloading $url"
    download "$url" "$tarball" || die "download failed: $url"
    "$@" "$tarball"
    mkdir "$WORK/$name.x"
    tar -C "$WORK/$name.x" -xf "$tarball"
    [ -f "$WORK/$name.x/$name/$marker" ] || die "${url##*/} did not unpack to $name/"
    mv -- "$WORK/$name.x/$name" "$dest"
    rm -rf -- "$tarball" "$WORK/$name.x"
    SUMMARY+=("downloaded  $dest")
}

# ------------------------------------------------------------- source trees --

source_tree "nmap-$NMAP_VERSION" "$NMAP_URL" nmap.h verify_nmap_signature
source_tree "openssl-$OPENSSL_VERSION" "$OPENSSL_URL" VERSION.dat verify_sha256 "$OPENSSL_SHA256"

# ----------------------------------------------------------- Alpine rootfs --

ALPINE_DIR="$SOURCES/alpine-$ALPINE_BRANCH"
ROOTFS="$ALPINE_DIR/$ROOTFS_NAME"
mkdir -p -- "$ALPINE_DIR"
if [ -f "$ROOTFS" ]; then
    echo "$ALPINE_SHA256  $ROOTFS" | sha256sum -c --quiet - \
        || die "$ROOTFS does not match its pinned SHA-256; move it away and re-run"
    SUMMARY+=("present     $ROOTFS")
else
    # After the Alpine pin changes, the old minirootfs and the packages
    # fetched for it must not be mixed with the new release.
    OLD_ROOTFS=$(compgen -G "$ALPINE_DIR/alpine-minirootfs-*-x86_64.tar.gz" | head -n 1 || true)
    [ -z "$OLD_ROOTFS" ] || die "$ALPINE_DIR holds $(basename -- "$OLD_ROOTFS"), but Alpine $ALPINE_VERSION is pinned now; delete $ALPINE_DIR and re-run"
    log "downloading $ROOTFS_URL"
    download "$ROOTFS_URL" "$WORK/$ROOTFS_NAME" || die "download failed: $ROOTFS_URL"
    verify_sha256 "$ALPINE_SHA256" "$WORK/$ROOTFS_NAME"
    mv -- "$WORK/$ROOTFS_NAME" "$ROOTFS"
    SUMMARY+=("downloaded  $ROOTFS")
fi

# --------------------------------------------------------- Alpine packages --
#
# Fetched with apk inside the minirootfs itself, so the versions match it;
# apk verifies every package's signature against the Alpine keys shipped in
# the minirootfs. To refetch (e.g. after changing APK_PACKAGES), delete apk/.

APK_DIR="$ALPINE_DIR/apk"
if compgen -G "$APK_DIR/*.apk" >/dev/null; then
    SUMMARY+=("present     $APK_DIR/ ($(compgen -G "$APK_DIR/*.apk" | wc -l) packages)")
else
    [ ! -e "$APK_DIR" ] || [ -z "$(ls -A -- "$APK_DIR")" ] \
        || die "$APK_DIR exists but has no .apk files; move it away and re-run"
    command -v docker >/dev/null || die "docker is needed to fetch the Alpine packages"
    docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon"

    if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        log "importing $ROOTFS_NAME as $BASE_IMAGE"
        docker import "$ROOTFS" "$BASE_IMAGE" >/dev/null
    fi
    log "fetching Alpine packages: $APK_PACKAGES (+ dependencies)"
    # shellcheck disable=SC2016  # expanded inside the container
    CID=$(docker create -e PKGS="$APK_PACKAGES" "$BASE_IMAGE" /bin/sh -c '
        set -eu
        apk update -q
        mkdir /apk
        apk fetch -q --recursive --output /apk $PKGS
        apk verify -q /apk/*.apk
        echo "$(ls /apk | wc -l) packages fetched and signature-checked"')
    docker start -a "$CID" || die "fetching the Alpine packages failed"
    mkdir "$WORK/apk"
    docker cp -q "$CID:/apk/." "$WORK/apk"
    docker rm -f "$CID" >/dev/null; CID=""
    rmdir -- "$APK_DIR" 2>/dev/null || true
    mv -- "$WORK/apk" "$APK_DIR"
    SUMMARY+=("downloaded  $APK_DIR/ ($(compgen -G "$APK_DIR/*.apk" | wc -l) packages)")
fi

# ------------------------------------------------------------------- done --

echo
log "sources ready in $SOURCES"
printf '    %s\n' "${SUMMARY[@]}"
echo
BUILD_CMD="$SCRIPT_DIR/build_nmap_static.sh"
# build_nmap_static.sh looks in sources/alpine-3.22 unless told otherwise.
[ "$ALPINE_DIR" = "$SCRIPT_DIR/sources/alpine-3.22" ] || BUILD_CMD+=" -a $ALPINE_DIR"
echo "Build with:"
echo "    $BUILD_CMD $SOURCES/nmap-$NMAP_VERSION $SOURCES/openssl-$OPENSSL_VERSION"
