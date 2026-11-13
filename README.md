# nmap-static

[![Static nmap release](https://github.com/andreynovikov/nmap-static/actions/workflows/release.yml/badge.svg)](https://github.com/andreynovikov/nmap-static/actions/workflows/release.yml)

This repository provides statically linked [nmap](https://nmap.org), ncat and nping
for x86_64 Linux. A workflow builds every new stable nmap release automatically.

The binaries need nothing at runtime: musl libc, OpenSSL 3.5 LTS, libssh2,
Lua/NSE and libpcap are all built in. They run on any x86_64 Linux system,
including ones without glibc.

## Download

Get the archive from [Releases](https://github.com/andreynovikov/nmap-static/releases).
Each release is tagged with the nmap version it was built from, such as `7.993`.
When OpenSSL or Alpine gets an update, the same nmap version is rebuilt and
published with a build number: `7.993-2`, `7.993-3`, and so on.

```sh
sudo tar -C /usr/local --strip-components=1 -xzf nmap-7.993-linux-x86_64-static.tar.gz
nmap --version
```

The binaries are built for `/usr/local`, but the archive also works unpacked
anywhere: `nmap-7.993/bin/nmap` finds its scripts and data next to itself.
ncat looks for its CA bundle only under `/usr/local`; elsewhere it falls back to
the system's CA certificates.

To verify a download:

```sh
sha256sum -c SHA256SUMS
gh attestation verify nmap-7.993-linux-x86_64-static.tar.gz -R andreynovikov/nmap-static
```

The second command checks GitHub's signed build provenance. It proves the
archive came from this repository's workflow, and needs GitHub CLI 2.49 or
newer.

## How releases are made

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs daily,
and also whenever the pins in `download_sources.sh` change on `main`:

1. It reads the latest stable version from https://nmap.org/download.html.
2. It decides whether to build ([`plan-release.sh`](.github/scripts/plan-release.sh)):
   - **no release of that version yet:** a first build, tagged `7.993`;
   - **the newest release was built with different OpenSSL or Alpine pins:**
     a rebuild, tagged `7.993-2` and so on (each release records its build
     inputs in a hidden comment in its notes);
   - **otherwise:** nothing to do.
3. It downloads the sources and checks the nmap tarball's GPG signature
   against the Nmap Project Signing Key.
4. It builds with `--prefix /usr/local`, runs `test_nmap_static.sh`, and
   publishes the archive and `SHA256SUMS` as a new release.

A failed build publishes nothing, and the next daily run tries again.

You can also run the workflow manually from the Actions tab:
- `version` builds a specific nmap release.
- Turning `publish` off builds and tests without releasing.

## Dependency updates

[`.github/workflows/update-dependencies.yml`](.github/workflows/update-dependencies.yml)
runs daily and looks for new patch releases of the pinned build inputs: OpenSSL
in its 3.5 LTS line, and the Alpine 3.22 branch. When it finds one, it
([`update-dependency.sh`](.github/scripts/update-dependency.sh)):

1. downloads the new release and checks its SHA-256 against every published
   checksum (GitHub and openssl.org; Alpine's release index and `.sha256` file);
2. updates the pin in `download_sources.sh` and the version mentions in the docs;
3. test-builds the latest nmap release with it and runs `test_nmap_static.sh`;
4. opens a pull request, only if the test build passed.

Merging that pull request triggers the release workflow, which publishes the
rebuild. Moving to a new OpenSSL or Alpine line (3.6, 3.23, ...) stays a manual
change of the pins at the top of `download_sources.sh`.

Dependabot can't track versions pinned in a shell script. It keeps the GitHub
Actions used by the workflows up to date instead ([`.github/dependabot.yml`](.github/dependabot.yml)).

After an Alpine update, delete your local `sources/alpine-3.22` before running
`download_sources.sh` again: its build packages belong to the old Alpine
release. The script stops with that hint rather than mixing them.

## Keeping the schedules alive

GitHub disables scheduled workflows in public repositories after 60 days
without activity. Both workflows re-enable themselves on every scheduled run
to prevent that. GitHub doesn't document whether this resets the timer; if it
doesn't, GitHub emails a warning first, and one click re-enables the workflow.

## Building it yourself

| File | Purpose |
|---|---|
| `download_sources.sh` | Fills `sources/` with the inputs (needs internet, run once) |
| `build_nmap_static.sh` | Builds into `output/<version>/` (fully offline) |
| `test_nmap_static.sh` | Smoke-tests a build |
| `nmap-signing-key.asc` | Nmap Project Signing Key, for checking nmap tarballs |

### Prerequisites

- x86_64 Linux with bash.
- Docker 23 or newer (BuildKit is the default there), and a user allowed to run
  it (for example, a member of the `docker` group).
- About 2 GB of free disk space.
- For `download_sources.sh` only: internet access, `curl` or `wget`, `gpg`
  and `bzip2`.

### Get the sources

```sh
./download_sources.sh                      # default nmap release (pinned in the script)
./download_sources.sh --nmap-version 7.993 # any other nmap release
```

The script downloads only what `sources/` is missing:

```
sources/
  nmap-7.993/                  nmap source; tarball GPG-checked against nmap-signing-key.asc
  openssl-3.5.9/               OpenSSL source; SHA-256 pinned in the script
  alpine-3.22/
    alpine-minirootfs-3.22.8-x86_64.tar.gz    build container base; SHA-256 pinned
    apk/                       build packages (gcc, make, perl, zlib, ...); apk checks signatures
```

- **Partial downloads:** an interrupted download never leaves partial files in
  `sources/`.
- **Re-fetching:** to fetch an item again, delete it and re-run the script.
- **Updating OpenSSL or Alpine:** change the version and its SHA-256 at the top
  of the script.
- **Offline machines:** copy `sources/` to the machine you build on.

### Build

```sh
./build_nmap_static.sh sources/nmap-7.993 sources/openssl-3.5.9
```

The build runs in Docker with networking disabled, so it works fully offline.
Nothing on the host changes except `output/` and some cached Docker images.
Source trees are only read. The first run takes about 4 minutes, because it
also prepares the images and builds OpenSSL; later runs take about 1.5 minutes.

| Option | Meaning |
|---|---|
| `-o DIR` | Install somewhere other than `output/<version>`. |
| `-p DIR` | Install prefix compiled into the binaries (default: the install directory itself). Release builds use `/usr/local`. |
| `-f` | Replace an earlier build. Only directories that contain this script's `.build-info` file can be replaced. |
| `-a DIR` | Use another Alpine directory (default `sources/alpine-3.22`). |
| `-j N` | Number of parallel make jobs. |

OpenSSL's legacy provider (MD4, DES, RC4) is compiled into libcrypto. A static
binary can't load the usual `legacy.so` module, and NSE needs these algorithms
for SMB, NTLM and similar scripts.

To remove the cached Docker images:

```sh
docker images 'nmap-static-*'
docker rmi $(docker images -q 'nmap-static-*')
```

### Test

```sh
./test_nmap_static.sh output/7.993
```

The tests work offline. The script starts ncat HTTP and TLS listeners on
127.0.0.1, then checks:

- static linking and the compiled-in features;
- the ncat TLS client;
- `ssl-cert`, `ssl-enum-ciphers` (TLS 1.2 and 1.3) and `http-title` over TLS;
- `-sV` with NSE;
- the OpenSSL legacy algorithms in NSE.

Run as root or with passwordless sudo, it also tests a SYN/UDP scan, OS
detection and nping.

Two more checks need a network around you:

```sh
sudo nmap -sn <host on the local LAN>          # ARP discovery: "MAC Address: ..."
nmap -p 22 --script ssh-auth-methods,ssh2-enum-algos <ssh-host>   # libssh2
```

## Known upstream issues

These affect regular nmap builds too:

- **ncat TLS listener quits:** a listener started with `ncat --ssl -k` plus
  `--sh-exec`, `--exec` or `--lua-exec` can quit with `fselect error 9` when
  several clients connect at once, as during a scan of it. The likely cause is
  in `post_handle_connection()` in `ncat_listen.c`, which keeps using a pointer
  into the fd list after `rm_fd()` has reordered that list.
- **`ssh-hostkey` prints nothing against OpenSSH 10 and newer** with default
  settings. nmap's SSH library only supports finite-field Diffie-Hellman key
  exchange, which those servers no longer offer.
