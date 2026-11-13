#!/usr/bin/env bash
#
# Copyright (c) 2026 Andrey Novikov
# Licensed under the Nmap Public Source License v0.95; see LICENSE and NOTICE.
#
# build-and-test.sh NMAP_VERSION
#
# CI helper: fetch the sources pinned in download_sources.sh (plus the given
# nmap release), build a release-style binary (--prefix /usr/local) into
# output/NMAP_VERSION, and run the smoke tests on it.

set -euo pipefail

VERSION=${1:?usage: build-and-test.sh NMAP_VERSION}
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

pin() { sed -n "s/^$1=//p" download_sources.sh; }
openssl_dir="sources/openssl-$(pin OPENSSL_VERSION)"
alpine_version=$(pin ALPINE_VERSION)
alpine_dir="sources/alpine-${alpine_version%.*}"

./download_sources.sh --keep-archives --nmap-version "$VERSION"
./build_nmap_static.sh --prefix /usr/local --alpine "$alpine_dir" "sources/nmap-$VERSION" "$openssl_dir"
./test_nmap_static.sh "output/$VERSION"
