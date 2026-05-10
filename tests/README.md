# Test suite

Four independent layers, run cheapest-first. Each layer can be invoked
on its own; `run-all.sh` chains them.

```
tests/
├── stubs/         Slim/Lyrion mocks so plugin .pm files load under plain
│                  perl 5.x. SimpleAsyncHTTP captures every GET/POST so
│                  payloads can be asserted on without a real server.
├── 01-syntax.sh   `perl -c` (via require) on every .pm
├── 02-payloads.pl Mocked-HTTP request shape tests — what the plugin
│                  PUTS ON THE WIRE for every API method
├── 03-extracts.pl Response-shape tests — _extractTracks against every
│                  shape AudioMuse actually returns
├── 04-live.sh     Live HTTP tests against a real AudioMuse server
└── run-all.sh     Run every layer; non-zero exit on any failure
```

## Running

```bash
# Offline — syntax + mocked unit tests only
bash tests/run-all.sh

# Full — picks up AUDIOMUSE_TOKEN from tests/.env automatically
bash tests/run-all.sh

# Or pass it explicitly
AUDIOMUSE_TOKEN=<paste> bash tests/run-all.sh
```

Set up the token once:

```bash
cp tests/.env.example tests/.env
# edit tests/.env, paste the token from AudioMuse → Administration → Tokens
```

`tests/.env` is `.gitignored` (the `!tests/.env.example` rule keeps the
template tracked). Pasting a token into any other script will probably
get caught by the broader `.env`, `.env.*`, and `*.token` excludes —
but `tests/.env` is the only "blessed" location.

`AUDIOMUSE_URL` defaults to `http://mediastream.int.jmuk.co.uk:8000`.
Override it via `tests/.env` or the env var for someone else's box.

## When something fails

| Layer | First place to look |
| --- | --- |
| `01-syntax`  | The compile error printed verbatim — usually a typo in the source file. |
| `02-payloads` | API.pm — request URL or JSON body changed. Update the test if the change is intentional, fix the API method otherwise. |
| `03-extracts` | Plugin.pm `_extractTracks` doesn't recognize a new response shape. Add a branch for it; add the fixture to this test. |
| `04-live`    | AudioMuse upstream API drifted. Read the swagger / source for the failing endpoint, update the request/extract code AND the matching test. |

## Adding a new API endpoint

The fastest path:

1. Add the call in `AudioMuseAI/API.pm` (`_get` / `_post`).
2. Add a request-shape test in `02-payloads.pl` — copy an existing
   block, adjust URL and payload assertions.
3. If the response is a NEW shape (not a bare array, `{results:[]}`,
   `{path:[]}`, or `{query_results:[]}`), extend `_extractTracks` in
   `Plugin.pm` AND add a fixture in `03-extracts.pl`.
4. Add a live-shape check in `04-live.sh` so future API drift is
   caught at the source.
5. `bash tests/run-all.sh` — must be all green before committing.

## Why not Test::More?

Self-contained shell + tiny perl is enough for ~50 checks and runs
without `cpanm`. If the suite grows past ~200 checks or starts needing
fixtures, port 02/03 to Test::More — the stubs will continue to work
unchanged.

## What the stubs cover

`tests/stubs/Slim/...` and friends provide just enough of the Lyrion
runtime for the plugin's `use` chain to resolve and for the modules to
load. They are NOT a behavioural model of Lyrion — anything beyond
"the .pm files compile and produce the expected outbound HTTP" needs
either an integration test (04-live) or an actual Lyrion install.

The mock you'll touch most often is
`tests/stubs/Slim/Networking/SimpleAsyncHTTP.pm` — it records every
request to `@captured_posts` / `@captured_gets` and fires the success
callback with whatever JSON has been stashed in `$next_response_body`.
Use `Slim::Networking::SimpleAsyncHTTP::reset_captures()` between
checks.
