#!/usr/bin/env bash
# Run every test layer in order. Lower-numbered scripts come first so a
# failure surfaces at the cheapest layer (syntax → mocked unit tests →
# live integration).
#
# Exits non-zero on any failure. Live tests SKIP gracefully (exit 0) when
# AUDIOMUSE_TOKEN isn't set, so this script is safe to run offline.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
STUBS="$HERE/stubs"
OK=0
NUM=0

run() {
    local label=$1 cmd=$2
    NUM=$((NUM + 1))
    echo
    echo "=========================================="
    echo "  $label"
    echo "=========================================="
    if bash -c "$cmd"; then
        OK=$((OK + 1))
    fi
}

run '01-syntax  (perl -c on every .pm, with stubs)' \
    "bash '$HERE/01-syntax.sh'"

run '02-payloads (request payload shapes — mocked HTTP)' \
    "PERL5LIB='$STUBS' perl '$HERE/02-payloads.pl'"

run '03-extracts (response unwrap shapes)' \
    "PERL5LIB='$STUBS' perl '$HERE/03-extracts.pl'"

run '04-live    (against $AUDIOMUSE_URL — skipped if no token)' \
    "bash '$HERE/04-live.sh'"

echo
echo "=========================================="
if [[ $OK -eq $NUM ]]; then
    echo "  ALL TEST LAYERS PASSED  ($OK/$NUM)"
    echo "=========================================="
    exit 0
fi
echo "  FAILURES  ($OK/$NUM layers passed)"
echo "=========================================="
exit 1
