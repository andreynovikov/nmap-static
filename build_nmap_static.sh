#!/usr/bin/env bash
#
# Build fully static (musl) nmap, ncat and nping and install them into
# output/<nmap version>/. Works fully offline: every input is a local
# directory (see README.md):
#
#   NMAP_SOURCE_DIR     nmap source tree, e.g. sources/nmap-7.993
#   OPENSSL_SOURCE_DIR  OpenSSL 3.x source tree, e.g. sources/openssl-3.5.9
#   ALPINE_DIR          Alpine minirootfs tarball + apk/ build packages
#                       (default: sources/alpine-3.22)
#
# The build runs in Docker with networking disabled. Nothing on the host is
# changed apart from the output directory and cached Docker images. Source
# trees are only read (copied or bind-mounted into the build), so the same
# sources can be built again and again.
#
# OpenSSL is built with its legacy provider (MD4, DES, RC4, ...) compiled into
# libcrypto ("no-module"): a static binary cannot load legacy.so, and NSE needs
# those algorithms for SMB/NTLM and others.
#
# Requirements: bash, Docker with BuildKit (the default since Docker 23).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] NMAP_SOURCE_DIR OPENSSL_SOURCE_DIR

Builds statically linked nmap, ncat and nping (musl libc, OpenSSL 3) inside
Docker, without network access, and installs them into OUTPUT_DIR.

Options:
  -o, --output DIR   install directory (default: ${SCRIPT_DIR}/output/<nmap version>)
  -p, --prefix DIR   install prefix compiled into the binaries, i.e. where they
                     will finally live (default: OUTPUT_DIR); e.g. /usr/local
  -a, --alpine DIR   Alpine minirootfs + apk/ packages (default: ${SCRIPT_DIR}/sources/alpine-3.22)
  -j, --jobs N       parallel make jobs (default: $(nproc))
  -f, --force        replace OUTPUT_DIR if it holds an earlier build made by this script
  -h, --help         show this help

Example:
  $(basename "$0") sources/nmap-7.993 sources/openssl-3.5.9
EOF
}

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

# ---------------------------------------------------------------- arguments --

ARGS=()
OUTPUT_DIR=""
PREFIX=""
ALPINE_DIR="$SCRIPT_DIR/sources/alpine-3.22"
JOBS=$(nproc)
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) [ $# -ge 2 ] || die "$1 needs an argument"; OUTPUT_DIR=$2; shift 2 ;;
        -p|--prefix) [ $# -ge 2 ] || die "$1 needs an argument"; PREFIX=$2; shift 2 ;;
        -a|--alpine) [ $# -ge 2 ] || die "$1 needs an argument"; ALPINE_DIR=$2; shift 2 ;;
        -j|--jobs)   [ $# -ge 2 ] || die "$1 needs an argument"; JOBS=$2; shift 2 ;;
        -f|--force)  FORCE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          usage >&2; die "unknown option: $1" ;;
        *)           ARGS+=("$1"); shift ;;
    esac
done
[ ${#ARGS[@]} -eq 2 ] || { usage >&2; exit 1; }
NMAP_SRC=${ARGS[0]}
OPENSSL_SRC=${ARGS[1]}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"

# nmap: version as nmap itself reports it, MAJOR.MINOR + SPECIAL (e.g. "7.993").
[ -f "$NMAP_SRC/nmap.h" ] && [ -x "$NMAP_SRC/configure" ] \
    || die "$NMAP_SRC does not look like an nmap source tree (no nmap.h or configure)"
NMAP_SRC=$(cd -- "$NMAP_SRC" && pwd)
nmap_define() { sed -n "s/^#define $1 *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" "$NMAP_SRC/nmap.h"; }
NMAP_VERSION="$(nmap_define NMAP_MAJOR).$(nmap_define NMAP_MINOR)$(nmap_define NMAP_SPECIAL)"
[[ "$NMAP_VERSION" =~ ^[0-9]+\.[0-9]+ ]] || die "cannot read the nmap version from $NMAP_SRC/nmap.h"

# OpenSSL: 3.x or later (VERSION.dat exists since 3.0).
[ -x "$OPENSSL_SRC/Configure" ] && [ -f "$OPENSSL_SRC/VERSION.dat" ] \
    || die "$OPENSSL_SRC does not look like an OpenSSL 3.x source tree (no Configure or VERSION.dat)"
OPENSSL_SRC=$(cd -- "$OPENSSL_SRC" && pwd)
openssl_field() { sed -n "s/^$1=//p" "$OPENSSL_SRC/VERSION.dat"; }
OPENSSL_VERSION="$(openssl_field MAJOR).$(openssl_field MINOR).$(openssl_field PATCH)"
[ -z "$(openssl_field PRE_RELEASE_TAG)" ] || OPENSSL_VERSION+="-$(openssl_field PRE_RELEASE_TAG)"
[[ "$OPENSSL_VERSION" =~ ^[3-9]\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] \
    || die "unsupported OpenSSL version '$OPENSSL_VERSION' in $OPENSSL_SRC (need 3.x or later)"

# Alpine: exactly one minirootfs tarball plus the .apk build packages.
[ -d "$ALPINE_DIR" ] || die "Alpine directory $ALPINE_DIR not found (run download_sources.sh)"
ALPINE_DIR=$(cd -- "$ALPINE_DIR" && pwd)
shopt -s nullglob
ROOTFS_FOUND=("$ALPINE_DIR"/alpine-minirootfs-*-x86_64.tar.gz)
APKS=("$ALPINE_DIR"/apk/*.apk)
shopt -u nullglob
[ ${#ROOTFS_FOUND[@]} -eq 1 ] || die "need exactly one alpine-minirootfs-*-x86_64.tar.gz in $ALPINE_DIR"
[ ${#APKS[@]} -gt 0 ] || die "no .apk packages in $ALPINE_DIR/apk (run download_sources.sh)"
ROOTFS=${ROOTFS_FOUND[0]}
ALPINE_VERSION=$(basename -- "$ROOTFS" -x86_64.tar.gz)
ALPINE_VERSION=${ALPINE_VERSION#alpine-minirootfs-}

BASE_IMAGE="nmap-static-base:alpine-${ALPINE_VERSION}"
TOOLS_IMAGE="nmap-static-tools:alpine-${ALPINE_VERSION}"
BUILDER_IMAGE="nmap-static-builder:alpine-${ALPINE_VERSION}-openssl-${OPENSSL_VERSION}"

# Output directory.
OUTPUT_DIR=$(realpath -m -- "${OUTPUT_DIR:-$SCRIPT_DIR/output/$NMAP_VERSION}")
# Both paths end up in Makefiles (DESTDIR staging, --prefix); keep them make-safe.
[[ "$OUTPUT_DIR" =~ ^/[A-Za-z0-9._+@/-]+$ ]] \
    || die "output path contains characters that break the build: $OUTPUT_DIR"
# The prefix is a path on the machine the binaries will run on, so it is not
# resolved against this host's filesystem.
PREFIX=${PREFIX:-$OUTPUT_DIR}
PREFIX=${PREFIX%/}
[[ "$PREFIX" =~ ^/[A-Za-z0-9._+@/-]+$ ]] \
    || die "--prefix must be an absolute path of plain characters: ${PREFIX:-/}"

# Every install made by this script carries this file; --force will only ever
# delete a directory that has it, never anything else.
MARKER=.build-info

check_output_dir_replaceable() {
    if [ -e "$OUTPUT_DIR" ] && [ -n "$(ls -A -- "$OUTPUT_DIR" 2>/dev/null)" ]; then
        [ "$FORCE" = 1 ] || die "$OUTPUT_DIR already exists and is not empty (use --force to replace it)"
        [ -d "$OUTPUT_DIR" ] && [ -f "$OUTPUT_DIR/$MARKER" ] \
            || die "refusing to replace $OUTPUT_DIR: it was not created by this script (no $MARKER file)"
    fi
}
check_output_dir_replaceable

command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is it running, and may you use it?)"

log "nmap ${NMAP_VERSION}:    ${NMAP_SRC}"
log "OpenSSL ${OPENSSL_VERSION}: ${OPENSSL_SRC}"
log "Alpine ${ALPINE_VERSION}: ${ALPINE_DIR}"
log "install dir:    ${OUTPUT_DIR}"
[ "$PREFIX" = "$OUTPUT_DIR" ] || log "prefix:         ${PREFIX}"

# ---------------------------------------------------------- builder images --
#
# Three cached layers; each is rebuilt only when its input changes:
#   base     the Alpine minirootfs, imported as a local image (never pulled)
#   tools    + compilers etc. installed from the local, signed .apk files
#   builder  + OpenSSL built from the local source tree
# RUN steps have no network, so a missing input fails instead of downloading.

if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    log "importing $(basename -- "$ROOTFS") as ${BASE_IMAGE}"
    docker import "$ROOTFS" "$BASE_IMAGE" >/dev/null
fi

# The zlib dev .so symlink is removed so that every configure script
# (including libssh2's, which prefers shared libs) links the static libz.a.
log "preparing ${TOOLS_IMAGE}"
docker build --network=none -t "$TOOLS_IMAGE" -f - "$ALPINE_DIR/apk" <<EOF
FROM ${BASE_IMAGE}
RUN --mount=type=bind,target=/apk \\
    apk add --no-network --no-cache --repositories-file=/dev/null /apk/*.apk \\
 && rm -f /usr/lib/libz.so
EOF

# OPENSSLDIR is /etc/ssl, where most distros keep openssl.cnf and CA certs.
# The source is bind-mounted read-write: build files are discarded afterwards.
log "preparing ${BUILDER_IMAGE} (builds OpenSSL the first time)"
docker build --network=none -t "$BUILDER_IMAGE" -f - "$OPENSSL_SRC" <<EOF
FROM ${TOOLS_IMAGE}
RUN --mount=type=bind,target=/openssl-src,rw \\
    set -eu; \\
    cd /openssl-src; \\
    ./config no-shared no-module no-tests no-docs \\
        --prefix=/opt/openssl --libdir=lib --openssldir=/etc/ssl; \\
    make -j"\$(nproc)"; \\
    make install_sw; \\
    /opt/openssl/bin/openssl list -providers -provider legacy | grep -q legacy
EOF

# ------------------------------------------------- build inside a container --
#
# Runs as root inside the container, on the container's own copy of the
# sources. Installs into /stage${PREFIX} (DESTDIR). PREFIX is compiled in as
# the data directory location (nmap's NSE scripts and databases, ncat's CA
# bundle); by default it is the output directory itself, so a local build
# works in place. nmap also finds its data relative to the binary
# (<bindir>/../share/nmap), so the tree can be moved anyway.

# shellcheck disable=SC2016  # expanded inside the container, not here
INNER_BUILD='
set -eu
cd /nmap-src

./configure \
    --build="$(gcc -dumpmachine)" \
    --prefix="$PREFIX" \
    --without-zenmap \
    --without-ndiff \
    --with-openssl=/opt/openssl \
    --with-libz=/usr \
    --with-libpcap=included \
    --with-libpcre=included \
    --with-libssh2=included \
    --with-liblua=included \
    --with-libdnet=included \
    --with-liblinear=included \
    LDFLAGS="-static"

make -j"$JOBS"
make install DESTDIR=/stage

echo "==> checking that the binaries are static"
for bin in nmap ncat nping; do
    f="/stage$PREFIX/bin/$bin"
    if readelf -lW "$f" | grep -q -e INTERP -e DYNAMIC; then
        echo "error: $bin is dynamically linked" >&2
        exit 1
    fi
done
"/stage$PREFIX/bin/nmap" --version
'

CID=""
TMP_OUT=""
cleanup() {
    [ -z "$CID" ] || docker rm -f "$CID" >/dev/null 2>&1 || true
    [ -z "$TMP_OUT" ] || rm -rf -- "$TMP_OUT"
}
trap cleanup EXIT

CID=$(docker create --network=none -e PREFIX="$PREFIX" -e JOBS="$JOBS" \
      "$BUILDER_IMAGE" /bin/sh -c "$INNER_BUILD")

log "copying nmap sources into the build container"
docker cp -q "$NMAP_SRC" "$CID:/nmap-src"

log "building nmap (make -j${JOBS})"
docker start -a "$CID" || die "build failed, see the output above"

# -------------------------------------------------------------- install --

mkdir -p -- "$(dirname -- "$OUTPUT_DIR")"
TMP_OUT=$(mktemp -d -- "${OUTPUT_DIR}.tmp.XXXXXX")
log "copying the install tree out of the container"
docker cp -q "$CID:/stage${PREFIX}/." "$TMP_OUT"
chmod 755 "$TMP_OUT"   # mktemp creates it 0700

"$TMP_OUT/bin/nmap" --version >/dev/null || die "the built nmap does not run on this host"

cat > "$TMP_OUT/$MARKER" <<EOF
# Created by $(basename "$0"). Its presence lets --force replace this directory.
nmap_version=${NMAP_VERSION}
nmap_source=${NMAP_SRC}
openssl_version=${OPENSSL_VERSION}
openssl_source=${OPENSSL_SRC}
alpine_version=${ALPINE_VERSION}
prefix=${PREFIX}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

if [ -e "$OUTPUT_DIR" ]; then
    check_output_dir_replaceable   # again: it may have changed during the build
    rm -rf -- "$OUTPUT_DIR"
fi
mv -- "$TMP_OUT" "$OUTPUT_DIR"
TMP_OUT=""

echo
log "done: nmap ${NMAP_VERSION} installed in ${OUTPUT_DIR}"
for bin in nmap ncat nping; do
    file -- "$OUTPUT_DIR/bin/$bin" 2>/dev/null || ls -l -- "$OUTPUT_DIR/bin/$bin"
done
"$OUTPUT_DIR/bin/nmap" --version
