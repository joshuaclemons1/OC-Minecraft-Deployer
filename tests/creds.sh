#!/usr/bin/env bash
# Tests for parsing Crafty's default-creds.txt.
#
# Regression test for a real bug: the first version used grep and printed the
# password with a trailing quote and comma attached, because the generated
# password contains no whitespace and the regex ran to the end of the JSON line.
#
#   bash tests/creds.sh

set -uo pipefail

PASS=0
FAIL=0
check() {
    if [ "$2" = "$3" ]; then
        PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"
    else
        FAIL=$(( FAIL + 1 ))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# The parser, lifted verbatim in behaviour from lib/80-finalize.sh.
parse_creds() {
    local creds="$1" user='' pass=''
    if have jq && jq -e . "$creds" >/dev/null 2>&1; then
        user="$(jq -r '.username // empty' "$creds" 2>/dev/null)"
        pass="$(jq -r '.password // empty' "$creds" 2>/dev/null)"
    fi
    if [ -z "$pass" ]; then
        user="$(sed -nE 's/.*"?username"?[[:space:]]*[:=][[:space:]]*"?([^"]*).*/\1/p' "$creds" | head -n1)"
        pass="$(sed -nE 's/.*"?password"?[[:space:]]*[:=][[:space:]]*"?([^"]*).*/\1/p' "$creds" | head -n1)"
    fi
    printf '%s\n%s' "${user:-admin}" "$pass"
}

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT

printf '\ndefault-creds.txt parsing\n'

# Exactly the file a real install produced, password and all.
REAL_PW='Xq#7v^Tz@9mK*2!p&4Rb$6Nd%8Gs#1Hw^3Jf@5Lk*7Zc&9Vx$2Qy%4Mn#6Bt^8Pr'
cat >"$TMP/real.json" <<EOT
{
    "username": "admin",
    "password": "$REAL_PW",
    "info": "This is NOT where you change your password. This file is only a means to give you a default password."
}
EOT
got="$(parse_creds "$TMP/real.json")"
check "username from real file" "admin"    "$(sed -n 1p <<<"$got")"
check "password from real file" "$REAL_PW" "$(sed -n 2p <<<"$got")"

# The actual regression: no trailing quote or comma.
case "$(sed -n 2p <<<"$got")" in
    *'",'|*'"') check "no trailing quote/comma (the bug)" "clean" "trailing junk" ;;
    *)          check "no trailing quote/comma (the bug)" "clean" "clean" ;;
esac

# Compact JSON, no pretty printing.
printf '{"username":"operator","password":"p@ss w0rd!"}' >"$TMP/compact.json"
got="$(parse_creds "$TMP/compact.json")"
check "compact JSON username"          "operator"   "$(sed -n 1p <<<"$got")"
check "password containing a space"    'p@ss w0rd!' "$(sed -n 2p <<<"$got")"

# Not JSON at all: the fallback path must still work.
printf 'username: admin\npassword: "plain-text-style"\n' >"$TMP/loose.txt"
got="$(parse_creds "$TMP/loose.txt")"
check "falls back on non-JSON" "plain-text-style" "$(sed -n 2p <<<"$got")"

# Missing username defaults to admin rather than empty.
printf '{"password":"only-a-password"}' >"$TMP/nouser.json"
got="$(parse_creds "$TMP/nouser.json")"
check "username defaults to admin" "admin"           "$(sed -n 1p <<<"$got")"
check "password still parsed"      "only-a-password" "$(sed -n 2p <<<"$got")"

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
