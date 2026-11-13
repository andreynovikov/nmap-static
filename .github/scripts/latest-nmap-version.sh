#!/usr/bin/env bash
#
# Print the latest stable nmap version announced on https://nmap.org/download.html
# (the "Latest stable Nmap release tarball" link). Fails loudly if the page
# no longer looks as expected, so a format change never goes unnoticed.

set -euo pipefail

URL=https://nmap.org/download.html

html=$(curl -fsSL --retry 3 --connect-timeout 30 "$URL")

# Skip commented-out lines: the page keeps an old "development release" link
# inside <!-- ... -->.
version=$(printf '%s\n' "$html" \
    | grep -v '<!--' \
    | grep -i 'stable</u> Nmap release tarball' \
    | grep -oE 'nmap-[0-9]+\.[0-9]+[A-Za-z0-9]*\.tar\.bz2' \
    | head -n 1 \
    | sed -E 's/^nmap-(.*)\.tar\.bz2$/\1/' || true)

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+[A-Za-z0-9]*$ ]]; then
    echo "error: cannot find the latest stable nmap release on $URL" >&2
    exit 1
fi
echo "$version"
