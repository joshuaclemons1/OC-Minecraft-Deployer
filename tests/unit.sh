#!/usr/bin/env bash
# Unit tests for the pure helpers in lib/common.sh.
#
# These run anywhere bash does, including on a Windows dev box, which is the
# point: the logic that decides whether to refuse an install is worth testing
# somewhere cheaper than a cloud instance.
#
#   bash tests/unit.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCD_ROOT="$(mktemp -d)"
export MCD_ROOT
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$(( PASS + 1 ))
        printf '  ok   %s\n' "$desc"
    else
        FAIL=$(( FAIL + 1 ))
        printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' \
            "$desc" "$expected" "$actual"
    fi
}

check_true()  { if "${@:2}"; then check "$1" yes yes; else check "$1" yes no; fi; }
check_false() { if "${@:2}"; then check "$1" no yes;  else check "$1" no no;  fi; }

printf '\nversion_ge\n'
check_true  "4.11.0 >= 4.11.0 (equal)"        version_ge 4.11.0 4.11.0
check_true  "4.11.0 >= 4.10.8"                version_ge 4.11.0 4.10.8
check_true  "4.11.0 >= 4.9.9"                 version_ge 4.11.0 4.9.9
check_false "4.10.7 >= 4.11.0 (the CVE case)" version_ge 4.10.7 4.11.0
check_false "4.9.0 >= 4.10.0 (not string cmp)" version_ge 4.9.0 4.10.0
check_true  "4.10.8 >= 4.10.8 (exact floor)"  version_ge 4.10.8 4.10.8
check_false "4.10.7 >= 4.10.8 (just below)"   version_ge 4.10.7 4.10.8

printf '\nis_valid_ipv4\n'
check_true  "203.0.113.42"          is_valid_ipv4 203.0.113.42
check_true  "0.0.0.0"               is_valid_ipv4 0.0.0.0
check_true  "255.255.255.255"       is_valid_ipv4 255.255.255.255
check_false "256.1.1.1 (octet>255)" is_valid_ipv4 256.1.1.1
check_false "1.2.3 (too few)"       is_valid_ipv4 1.2.3
check_false "1.2.3.4.5 (too many)"  is_valid_ipv4 1.2.3.4.5
check_false "empty"                 is_valid_ipv4 ''
check_false "not-an-ip"             is_valid_ipv4 not-an-ip
check_false "1.2.3. (trailing dot)" is_valid_ipv4 '1.2.3.'

printf '\nsuggested_heap_mb (reserve=%s)\n' "$MCD_RESERVE_MB"
_heap_for() {
    # Fake /proc/meminfo by overriding total_mem_mb.
    local mb="$1"
    total_mem_mb() { printf '%d' "$mb"; }
    suggested_heap_mb
}
check "12 GB box leaves a whole-GB heap" 9216  "$(_heap_for 12288)"
check "24 GB box (pre-June-2026 shape)"  21504 "$(_heap_for 24288)"
check "4 GB box"                         1024  "$(_heap_for 4096)"
check "2 GB box yields nothing usable"   0     "$(_heap_for 2048)"
check "heap is always a whole GB"        9216  "$(_heap_for 12000)"

printf '\nrender\n'
_tmpl="$(mktemp)"; _out="$(mktemp)"
cat >"$_tmpl" <<'EOT'
host @@HOSTNAME@@ port @@PORT@@
repeated @@HOSTNAME@@
literal $VAR ${BRACE} {curly} and a $ sign
EOT
render "$_tmpl" "$_out" HOSTNAME mc.example.com PORT 25565 2>/dev/null
check "substitutes a placeholder"     "host mc.example.com port 25565" "$(sed -n 1p "$_out")"
check "substitutes every occurrence"  "repeated mc.example.com"        "$(sed -n 2p "$_out")"
check "leaves shell syntax untouched" 'literal $VAR ${BRACE} {curly} and a $ sign' "$(sed -n 3p "$_out")"

printf 'has-@@UNSET@@\n' >"$_tmpl"
render "$_tmpl" "$_out" HOSTNAME x 2>/dev/null
check "warns but still writes on unsubstituted" "has-@@UNSET@@" "$(cat "$_out")"
rm -f "$_tmpl" "$_out"

printf '\nconf_set\n'
MCD_CONF="$MCD_ROOT/mcd.conf"
conf_set FOO bar
conf_set BAZ qux
check "writes a key"            "bar" "$(. "$MCD_CONF"; printf '%s' "$FOO")"
conf_set FOO changed
check "replaces, not appends"   "changed" "$(. "$MCD_CONF"; printf '%s' "$FOO")"
check "leaves other keys alone" "qux" "$(. "$MCD_CONF"; printf '%s' "$BAZ")"
check "one line per key"        "1" "$(grep -c '^FOO=' "$MCD_CONF")"

printf '\ngen_password\n'
_pw="$(gen_password)"
check "24 characters"  "24" "${#_pw}"
check_true "alphanumeric only" grep -qE '^[A-Za-z0-9]+$' <<<"$_pw"
check_false "not repeatable" [ "$_pw" = "$(gen_password)" ]

rm -rf "$MCD_ROOT"

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
