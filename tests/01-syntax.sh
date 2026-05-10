#!/usr/bin/env bash
# Static syntax check: perl -c (via require) on every .pm in the plugin.
# Requires only Perl 5.x — no Lyrion installation. tests/stubs/ satisfies
# every `use Slim::...` and friends with empty/minimal substitutes.
#
# WEBUI is a compile-time constant Lyrion injects into the main package;
# Plugin.pm references it as `main::WEBUI`, so we predefine it.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STUBS="$HERE/stubs"

fail=0
for f in "$ROOT/AudioMuseAI"/*.pm; do
    name="${f##*/}"
    out=$(PERL5LIB="$STUBS" perl -e '
        package main;
        use constant WEBUI => 0;
        eval { require $ARGV[0] };
        if ($@) { print STDERR $@; exit 1 }
    ' "$f" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf 'PASS  syntax  %s\n' "$name"
    else
        printf 'FAIL  syntax  %s\n      %s\n' "$name" "${out//$'\n'/$'\n      '}"
        fail=$((fail + 1))
    fi
done

echo
if [[ $fail -eq 0 ]]; then
    echo "01-syntax: all files compile cleanly"
    exit 0
fi
echo "01-syntax: $fail file(s) failed"
exit 1
