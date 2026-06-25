# CLI / JSON-RPC reference

Every menu action is exposed as a command on Lyrion's `/jsonrpc.js` endpoint — handy for Material Skin custom buttons, Home Assistant automations, and scripting.

Commands take the form:

```json
{"id":1,"method":"slim.request","params":["<player-id-or-empty>",["audiomuseai","<command>", "<param>:<value>", ...]]}
```

Player-scoped commands need a player MAC as the first param; server-wide commands take an empty string.

## Common examples

```bash
# Similar to whatever player <id> is currently playing
{"params":["bb:bb:55:90:9c:db",["audiomuseai","similar_now"]]}

# Sonic fingerprint
{"params":["bb:bb:55:90:9c:db",["audiomuseai","sonic_fp"]]}

# Instant playlist from a text prompt
{"params":["bb:bb:55:90:9c:db",["audiomuseai","instant","prompt:low-energy ambient"]]}

# Mood preset (CLAP prompt + label)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","mood","prompt:calm, ambient, peaceful","mood_label:Calm"]]}

# Save current queue (uses your auto-name format setting)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","save_playlist"]]}

# Live server status (structured JSON, good for dashboards)
{"params":["",["audiomuseai","server_status"]]}

# Library coverage stats (artists, albums, CLAP-indexed, clustered, top moods)
{"params":["",["audiomuseai","library_summary"]]}

# Cancel the currently running AudioMuse task
{"params":["",["audiomuseai","cancel_active"]]}
```

## Full command list

Every player-scoped and server-wide command, with example payloads, is documented in the plugin's own README:

→ [`AudioMuseAI/README.md` → CLI / JSON-RPC reference](../AudioMuseAI/README.md#cli--json-rpc-reference)

That list is the canonical reference because it ships inside the plugin package and tracks the dispatch table directly.
