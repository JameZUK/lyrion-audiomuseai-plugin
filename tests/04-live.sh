#!/usr/bin/env bash
# Live integration tests — verify the actual AudioMuse server still
# matches the request/response shapes the plugin expects.
#
# Required env vars:
#   AUDIOMUSE_URL    base URL (default: http://mediastream.int.jmuk.co.uk:8000)
#   AUDIOMUSE_TOKEN  bearer token (required; mint one in the AudioMuse web UI
#                    under Administration → Tokens)
#
# Exits 0 only if every endpoint returns the shape this plugin version
# parses. When the upstream API drifts, this script tells you which
# endpoint changed BEFORE users hit a silent breakage.
#
# Run via tests/run-all.sh, or directly:
#   AUDIOMUSE_TOKEN=... tests/04-live.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

# Pull AUDIOMUSE_TOKEN / AUDIOMUSE_URL from tests/.env if present, so
# devs don't have to prefix every invocation. The file is .gitignored
# (see /.gitignore) — never commit it.
if [[ -f "$HERE/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$HERE/.env"
    set +a
fi

URL="${AUDIOMUSE_URL:-http://mediastream.int.jmuk.co.uk:8000}"
TOK="${AUDIOMUSE_TOKEN:-}"

if [[ -z "$TOK" ]]; then
    cat <<MSG
SKIP  04-live: AUDIOMUSE_TOKEN not set.
      Either:
        - export AUDIOMUSE_TOKEN=... in your shell, or
        - copy tests/.env.example to tests/.env and paste the token there.
MSG
    exit 0
fi

pass=0
fail=0

# Helper: assert keys of a JSON object include all of the given names.
# usage: assert_keys "desc" "$json" "key1" "key2" ...
assert_keys() {
    local desc=$1 json=$2
    shift 2
    # Feed the body to python via stdin — NOT interpolated into the
    # source — so quotes/backslashes in real payloads can't break the
    # script (or, worse, make json.loads raise and the check silently
    # pass on empty output). Success prints the sentinel 'ok'; anything
    # else (bad-json / not-a-hash / missing keys / a python crash that
    # prints nothing) is a FAIL.
    local result
    result=$(printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('bad-json'); sys.exit(0)
want = sys.argv[1:]
if not isinstance(d, dict):
    print('not-a-hash'); sys.exit(0)
missing = [k for k in want if k not in d]
print(','.join(missing) if missing else 'ok')
" "$@")
    if [[ "$result" == "ok" ]]; then
        echo "PASS  $desc"
        pass=$((pass + 1))
    else
        echo "FAIL  $desc"
        echo "      problem: ${result:-python-error}"
        echo "      body: ${json:0:200}"
        fail=$((fail + 1))
    fi
}

# Helper: assert the response is a JSON ARRAY whose first item has all
# of the given keys.
assert_array_keys() {
    local desc=$1 json=$2
    shift 2
    # Same stdin-not-source-interpolation rule as assert_keys: a body
    # that won't parse must FAIL, never silently pass.
    local result
    result=$(printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('bad-json'); sys.exit(0)
want = sys.argv[1:]
if not isinstance(d, list):
    print('not-an-array'); sys.exit(0)
if not d:
    print('empty-array'); sys.exit(0)
first = d[0]
missing = [k for k in want if k not in first]
print(','.join(missing) if missing else 'ok')
" "$@")
    case "$result" in
      ok)
        echo "PASS  $desc"
        pass=$((pass + 1))
        ;;
      not-an-array|empty-array|bad-json)
        echo "FAIL  $desc ($result)"
        echo "      body: ${json:0:200}"
        fail=$((fail + 1))
        ;;
      *)
        echo "FAIL  $desc"
        echo "      missing key(s) on first item: ${result:-python-error}"
        echo "      body: ${json:0:200}"
        fail=$((fail + 1))
        ;;
    esac
}

H="Authorization: Bearer $TOK"
CT='Content-Type: application/json'

# --- 1. /api/health (no auth) ---
body=$(curl -sS "$URL/api/health")
assert_keys '/api/health: returns {status}' "$body" status

# --- 2. /api/dashboard/summary ---
body=$(curl -sS -H "$H" "$URL/api/dashboard/summary")
assert_keys '/api/dashboard/summary: has content + workers + recent_tasks' "$body" content workers recent_tasks

# --- 3. /api/active_tasks ---
body=$(curl -sS -H "$H" "$URL/api/active_tasks")
# may legitimately be {} or {task_id, status, ...} — just confirm it parses.
echo "$body" | python3 -c 'import json,sys;json.load(sys.stdin)' \
  && { echo 'PASS  /api/active_tasks: parses as JSON'; pass=$((pass+1)); } \
  || { echo 'FAIL  /api/active_tasks: not JSON'; fail=$((fail+1)); }

# --- 4. /api/clap/top_queries ---
body=$(curl -sS -H "$H" "$URL/api/clap/top_queries")
assert_keys '/api/clap/top_queries: has {queries, ready}' "$body" queries ready

# --- 5. /api/clap/search (the v0.3.0 fix — new `limit` param) ---
body=$(curl -sS -X POST -H "$H" -H "$CT" \
  -d '{"query":"upbeat summer songs","limit":3}' \
  "$URL/api/clap/search")
assert_keys '/api/clap/search: returns {query, count, results}' "$body" query count results

# --- 6. /api/clap/warmup (new in v0.3.0) ---
body=$(curl -sS -X POST -H "$H" "$URL/api/clap/warmup")
assert_keys '/api/clap/warmup: returns {loaded, expiry_seconds}' "$body" loaded expiry_seconds

# --- 7. /api/lyrics/search/text (new in v0.3.0) ---
# A "happy path" lyric phrase. If your library is small the server may
# return 404 with {error, query, results: []} — that's still a shape
# match, just check the keys.
body=$(curl -sS -X POST -H "$H" -H "$CT" \
  -d '{"query":"this is a placeholder lyric query","limit":3}' \
  "$URL/api/lyrics/search/text")
assert_keys '/api/lyrics/search/text: returns {query, results}' "$body" query results

# --- 8. /api/search_tracks (legacy `artist=` param) ---
# Note: the plugin no longer calls /api/similar_artists (the "Similar to an
# artist" flow now blends via /api/alchemy seeded from the artist's tracks),
# so there's no live check for it here.
body=$(curl -sS -G -H "$H" \
  --data-urlencode 'search_query=Frank Turner' "$URL/api/search_tracks")
assert_array_keys '/api/search_tracks: items carry {item_id, title, author}' "$body" item_id title author

# --- 10. /api/similar_tracks ---
TID=$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["item_id"] if d else "")')
if [[ -n "$TID" ]]; then
    sim=$(curl -sS -G -H "$H" \
      --data-urlencode "item_id=$TID" --data-urlencode 'n=3' \
      "$URL/api/similar_tracks")
    assert_array_keys '/api/similar_tracks: items carry {item_id, title}' "$sim" item_id title
else
    echo 'SKIP  /api/similar_tracks: no track id from search_tracks'
fi

# --- 11. /api/alchemy (v0.3.0 fix — items[] payload + wrapped results) ---
if [[ -n "$TID" ]]; then
    al=$(curl -sS -X POST -H "$H" -H "$CT" \
      -d "{\"items\":[{\"id\":\"$TID\",\"op\":\"ADD\",\"type\":\"song\"}],\"n\":5}" \
      "$URL/api/alchemy")
    assert_keys '/api/alchemy: returns {results, filtered_out, ...}' "$al" results filtered_out
fi

# --- 12. /api/find_path (v0.3.0 fix — {path} unwrap) ---
TID2=$(curl -sS -G -H "$H" --data-urlencode 'search_query=The Beatles' "$URL/api/search_tracks" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["item_id"] if d else "")')
if [[ -n "$TID" && -n "$TID2" && "$TID" != "$TID2" ]]; then
    fp=$(curl -sS -G -H "$H" \
      --data-urlencode "start_song_id=$TID" --data-urlencode "end_song_id=$TID2" \
      --data-urlencode 'max_steps=5' "$URL/api/find_path")
    assert_keys '/api/find_path: returns {path, total_distance}' "$fp" path total_distance
fi

echo
if [[ $fail -eq 0 ]]; then
    echo "04-live: all $pass live checks passed"
    exit 0
fi
echo "04-live: $fail of $((pass + fail)) checks failed"
exit 1
