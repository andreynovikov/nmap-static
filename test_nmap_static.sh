#!/usr/bin/env bash
#
# Smoke-test a static nmap build:
#
#   test_nmap_static.sh OUTPUT_DIR        e.g. output/7.993
#
# Works offline: it starts ncat HTTP and TLS listeners on 127.0.0.1 and scans
# them. Raw-socket tests (SYN/UDP scan, OS detection, nping) run only as root
# or with passwordless sudo, and are skipped otherwise. Exits non-zero if any
# test fails.
#
# An ncat listener using --ssl, -k and --sh-exec together can quit
# ("fselect error 9") when several clients connect at once. This is an upstream
# ncat bug, present in regular builds too. So that listener only gets single,
# sequential connections. Parallel TLS handshakes (ssl-enum-ciphers) go to a
# second TLS listener without --sh-exec, and -sV only probes the plain port.

set -uo pipefail

[ $# -eq 1 ] && [ -x "$1/bin/nmap" ] || { echo "usage: $(basename "$0") OUTPUT_DIR (containing bin/nmap)" >&2; exit 2; }
B="$(cd -- "$1" && pwd)/bin"
HTTP_PORT=${HTTP_PORT:-18080}      # plain HTTP (ncat --sh-exec)
TLS_PORT=${TLS_PORT:-18443}        # HTTP over TLS (ncat --ssl --sh-exec)
TLS_HS_PORT=${TLS_HS_PORT:-18444}  # TLS handshakes only (ncat --ssl, no exec)

PASS=0 FAIL=0 SKIP=0
WORK=$(mktemp -d)
PIDS=()
cleanup() {
    [ ${#PIDS[@]} -eq 0 ] || kill "${PIDS[@]}" 2>/dev/null
    wait 2>/dev/null
    rm -rf -- "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }
fail() {
    echo "FAIL  $1"
    [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      | /'
    FAIL=$((FAIL + 1))
}

# check NAME OUTPUT REGEX...: pass when OUTPUT matches every extended REGEX.
check() {
    local name=$1 out=$2 re; shift 2
    for re in "$@"; do
        grep -qE -- "$re" <<<"$out" || { fail "$name (expected: $re)" "$out"; return; }
    done
    pass "$name"
}

# --------------------------------------------------------------- binaries --

for bin in nmap ncat nping; do
    if command -v readelf >/dev/null; then
        if readelf -lW "$B/$bin" | grep -q -e INTERP -e DYNAMIC; then
            fail "$bin is statically linked" "$(readelf -lW "$B/$bin" | grep -e INTERP -e DYNAMIC)"
        else
            pass "$bin is statically linked"
        fi
    else
        check "$bin is statically linked" "$(file -L "$B/$bin")" 'statically linked'
    fi
done

check "nmap --version: all features compiled in" "$("$B/nmap" --version)" \
    'openssl-[0-9]' 'libssh2' 'nmap-liblua' '^Compiled without:[[:space:]]*$'

# ---------------------------------------------------------- test services --

"$B/ncat" -lk 127.0.0.1 "$HTTP_PORT" \
    --sh-exec 'printf "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n<title>plain test</title>"' \
    </dev/null >/dev/null 2>&1 &
PIDS+=($!)
"$B/ncat" --ssl -lk 127.0.0.1 "$TLS_PORT" \
    --sh-exec 'printf "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n<title>tls test</title>"' \
    </dev/null >/dev/null 2>&1 &
PIDS+=($!)
"$B/ncat" --ssl -lk 127.0.0.1 "$TLS_HS_PORT" </dev/null >/dev/null 2>&1 &
PIDS+=($!)
for port in "$HTTP_PORT" "$TLS_PORT" "$TLS_HS_PORT"; do
    for _ in $(seq 1 20); do
        "$B/ncat" -z 127.0.0.1 "$port" 2>/dev/null && break
        sleep 0.5
    done
done

# -------------------------------------------------------------------- TLS --

check "ncat TLS client" \
    "$(printf 'GET / HTTP/1.0\r\n\r\n' | timeout 30 "$B/ncat" --ssl 127.0.0.1 "$TLS_PORT" 2>&1)" \
    'tls test'

# "+" runs a script regardless of its port rule (these are not well-known TLS
# ports and -sV is not used here). One script per run keeps the connections
# to the --sh-exec TLS listener sequential.
check "nmap ssl-cert" \
    "$(timeout 120 "$B/nmap" -n -p "$TLS_PORT" --script '+ssl-cert' 127.0.0.1 2>&1)" \
    'ssl-cert: Subject: commonName='
check "nmap http-title over TLS" \
    "$(timeout 120 "$B/nmap" -n -p "$TLS_PORT" --script '+http-title' 127.0.0.1 2>&1)" \
    'http-title: tls test'
check "nmap ssl-enum-ciphers (TLS 1.2 and 1.3)" \
    "$(timeout 300 "$B/nmap" -n -p "$TLS_HS_PORT" --script '+ssl-enum-ciphers' 127.0.0.1 2>&1)" \
    'TLSv1\.2:' 'TLSv1\.3:'

# ------------------------------------------- scan, version detection, NSE --

check "nmap -sV + NSE (resolving localhost)" \
    "$(timeout 300 "$B/nmap" -sV -p "$HTTP_PORT" --script '+http-title' localhost 2>&1)" \
    "^$HTTP_PORT/tcp +open" 'http-title: plain test'

cat > "$WORK/legacy-crypto.nse" <<'EOF'
description = "MD4, DES and RC4 from the built-in OpenSSL legacy provider"
categories = {"safe"}
prerule = function() return true end
local openssl = require "openssl"
action = function()
  openssl.md4("x")
  openssl.encrypt("des-ecb", "12345678", nil, "abcdefgh", false)
  openssl.encrypt("rc4", "0123456789abcdef", nil, "x", false)
  return "MD4, DES, RC4: OK"
end
EOF
check "NSE legacy crypto (MD4, DES, RC4)" \
    "$(timeout 120 "$B/nmap" -sn -n --script "$WORK/legacy-crypto.nse" 2>&1)" \
    'legacy-crypto: MD4, DES, RC4: OK'

# ------------------------------------------------------------ raw sockets --

RAW=1 SUDO=()
if [ "$(id -u)" -eq 0 ]; then
    :
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    SUDO=(sudo -n)
else
    RAW=0
fi

if [ "$RAW" -eq 0 ]; then
    skip "raw sockets: SYN/UDP scan, OS detection (needs root or passwordless sudo)"
    skip "raw sockets: nping"
else
    check "raw sockets: SYN/UDP scan, OS detection" \
        "$(timeout 300 "${SUDO[@]}" "$B/nmap" -n -sS -sU -O -p "T:$HTTP_PORT,T:9,U:53" 127.0.0.1 2>&1)" \
        "^$HTTP_PORT/tcp +open" '^9/tcp +closed' '^53/udp' \
        '(OS details|Aggressive OS guesses|TCP/IP fingerprint|No exact OS matches)'
    check "raw sockets: nping" \
        "$(timeout 60 "${SUDO[@]}" "$B/nping" --tcp -p "$HTTP_PORT" -c 2 127.0.0.1 2>&1)" \
        '^RCVD .* SA '
fi

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
