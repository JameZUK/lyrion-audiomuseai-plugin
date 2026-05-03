# lyrion-audiomuseai-plugin

A plugin for [Lyrion Music Server](https://lyrion.org) that adds an **AudioMuse-AI** entry under **My Music**, surfacing all of [AudioMuse-AI's](https://github.com/NeptuneHub/AudioMuse-AI) sonic-similarity features inside the standard Lyrion controllers (web UI, Material Skin, iPeng, Squeezer).

> **Why?** AudioMuse-AI's web UI is great, but you probably control playback from a Lyrion controller. This plugin makes its features tap-reachable from the same UI you already use to pick music.

## Install

In Lyrion's web UI:

**Settings → Plugins → Additional Repositories**, paste:

```
https://raw.githubusercontent.com/JameZUK/lyrion-audiomuseai-plugin/main/extensions.xml
```

Apply, scroll down to the third-party plugin list, tick **AudioMuse-AI**, click Apply, restart Lyrion when prompted.

Then **Settings → Plugins → AudioMuse-AI**:

- **Server URL** — your AudioMuse-AI Flask container, e.g. `http://localhost:8000`. The scheme `http://` is added automatically if you forget it.
- **API token** — generate one in the AudioMuse-AI web UI under Administration. Whitespace and CR/LF are stripped automatically.
- **Test connection** runs a live probe; the result updates in place via JSON-RPC polling.
- The settings page shows a **live server-status panel** (current task, progress %, running time, last log line) that auto-refreshes every 10 s while a task is running.

The plugin also adds **context-menu items** to Lyrion's standard browse — see [Pro tip](#pro-tip-the-fastest-paths) below.

## What's in the menu

Once installed, you'll see **My Music → AudioMuse-AI** with the following entries (ordered by typical use frequency):

### Tier 1 — One-tap actions

| Item | What it does | Requires |
|---|---|---|
| **Similar to current track** | Queues N tracks sonically similar to whatever's currently playing. | Clustering done. |
| **Sonic Fingerprint** | Replaces the queue with a personalised playlist generated from your listening history. | A few hundred plays in the database. |
| **Browse by Mood** | Submenu of seven preset CLAP prompts (Energetic, Calm, Sad, Happy, Aggressive, Acoustic, Party). Tapping one queues a matching playlist. | Analysis completed (CLAP cache loaded). |
| **Popular CLAP searches...** | Submenu of community-popular search prompts pulled from the AudioMuse-AI server. Pure discovery — tap any phrase to queue. Same auto-save behaviour as Browse by Mood. | Analysis completed. |

### Tier 2 — Tap-driven browse

| Item | Flow |
|---|---|
| **Similar to an artist (pick from library)...** | Paginated artist list from your Lyrion library → tap artist → queues tracks by the most similar artist. |
| **Similar to a song (pick artist, then track)...** | Paginated artist list → tap artist → list of that artist's analyzed tracks → tap track → queues sonically similar tracks. |

### Tier 3 — Sessions / advanced

| Item | What it does |
|---|---|
| **Dynamic Playlists** | Submenu with three modes: **Continuous similar to current track**, **Continuous from sonic fingerprint**, **Stop auto-extend**. With "Auto-extend the queue" enabled in settings, the chosen mode keeps the queue refilled when it runs low. |
| **Song Alchemy** | Per-player ADD/SUBTRACT track lists. Tap a song → "Add current to ADD" → tap another → "Add current to SUBTRACT" → "Generate" calls AudioMuse-AI's alchemy endpoint to produce a sonic blend. |

### Tier 4 — Tools (tap-only, work everywhere)

| Item | What it does |
|---|---|
| **Save current queue as playlist (auto-named)** | Saves the current Lyrion queue. The auto-name is configured by a settings dropdown — see [Auto-name strategies](#auto-name-strategies). On web UI / Material you can also type a custom name in the field; on Squeezer the auto-name is used. |

### Tier 5 — Text input required (web UI / Material only)

These items render but **can't be activated on Squeezer**, which doesn't render Jive `input` fields. Work fine on the default Lyrion web UI, Material Skin, and iPeng.

| Item | What it does |
|---|---|
| **Instant Playlist (text — needs typing)...** | Type a natural-language description (e.g. "low-energy late-night ambient") → AudioMuse's CLAP search returns matching tracks → queue is replaced. With **Auto-save Instant Playlist** enabled in settings, the result is saved as `AudioMuse: <your prompt>`. |
| **AI Chat Playlist (LLM, text — needs typing)...** | Same UX as Instant Playlist, but the backend is the LLM you've configured on the AudioMuse-AI server (Gemini / OpenAI / Mistral / Ollama). Plain language → AI-generated SQL → matching tracks. Requires `AI_MODEL_PROVIDER` to be set on the AudioMuse server. Same auto-save toggle as Instant Playlist. |
| **Find Path between two songs (text — needs typing)...** | Generates a sonic-transition playlist between your currently-playing track and a chosen end-track. Useful for smooth genre/mood transitions. |

### Tier 6 — Status / link-out

| Item | What it does |
|---|---|
| **Server Status / Admin** | Submenu: show active task, show last task, trigger analysis, trigger clustering, **cancel running task**. Errors elsewhere ("similarity service unavailable") include live status inline so you know what's blocking. |
| **Open Music Map (web UI link)** | Clickable link to the AudioMuse-AI web UI, opened in a browser on controllers that honour Jive's `weblink` field (Material, default web UI, iPeng). On other controllers it shows the URL as text. |

## Pro tip: the fastest paths

Two things you can do that aren't in the AudioMuse-AI menu:

### Context menu from Lyrion's standard browse

The plugin registers info-providers for artists, tracks, and albums. **Browse normally** (e.g. My Music → Artists, type to filter, tap an artist) and the context menu (right-click in web UI / long-press in Material / 3-dot in iPeng) will include:

- **AudioMuse: similar artists** — on any artist
- **AudioMuse: similar tracks** — on any track (works in My Music, in your queue, anywhere)
- **AudioMuse: alchemy from this album** — on any album (seeds AudioMuse alchemy with all of the album's tracks)

This bypasses the plugin's own menu entirely and gives you Lyrion's native filter / letter-jump for free. **Recommended path on Squeezer** (which can filter the standard browse but can't render Jive `input` fields inside the plugin menu).

### Auto-extend (DSTM)

Enable **Auto-extend the queue** in plugin settings. Then start any **Dynamic Playlists** mode (continuous similar / continuous fingerprint). When your queue drops to ≤ 3 remaining tracks, the plugin asks AudioMuse-AI for 10 more and appends them automatically — endless mood-matched listening without intervention.

## Settings reference

| Setting | What it does |
|---|---|
| **Server URL** | Where AudioMuse-AI is running. `http://` auto-prefixed; trailing slashes stripped. |
| **API token** | Bearer token. Trimmed of whitespace; CR/LF rejected. |
| **Default count** | How many tracks AudioMuse returns per request (5–100, clamped). |
| **Auto-extend the queue (DSTM)** | Refills the queue from AudioMuse when it drops to ≤ 3 remaining tracks. Mode is set per-player via the Dynamic Playlists submenu. |
| **Auto-name format** | How "Save current queue" titles its playlists when no name is typed. See below. |
| **Auto-save Instant Playlist results** | After every Instant Playlist action, save the queue as `AudioMuse: <your prompt>`. |
| **Auto-save Browse-by-Mood results** | After tapping a Mood preset, save as `AudioMuse: <mood> - <timestamp>`. |
| **Test connection** | Probes the server and reports OK / failure. Result polled in-place via JSON-RPC. |
| **Server Status panel** | Shows current task (status_message, state, progress %, running time, last log line) **and a Library coverage section** (artists / albums / CLAP-indexed track count / clustered track count / top moods). Auto-refreshes every 10 s while a task is running. |

### Auto-name strategies

| Strategy | Example |
|---|---|
| **Timestamp** (default) | `AudioMuse 2026-05-03 14:30` |
| **First track** | `AudioMuse: 1933 - Frank Turner` |
| **Artist mix** | `AudioMuse: Frank Turner, Phish, U2 (24t)` |
| **Mood-tagged** | `AudioMuse: Calm / Ambient - 2026-05-03 14:30` |
| **Last Instant prompt** | `AudioMuse: low-energy late-night ambient` |

> **No AI is used for naming.** AudioMuse-AI's CLAP search is an audio-embedding model, not an LLM. Names are derived from local data (timestamp / queue contents / your typed prompt / the mood label). True AI-generated names would require an upstream server endpoint AudioMuse-AI doesn't currently expose.

### Per-player default count override

The default count is server-global, but each player can override it via Lyrion's standard pref CLI (no UI yet):

```bash
# 'Living Room' player uses 50 instead of the global default
curl -X POST http://lyrion:9000/jsonrpc.js -H "Content-Type: application/json" \
  -d '{"id":1,"method":"slim.request","params":["bb:bb:55:90:9c:db",
       ["pref","plugin.audiomuseai:default_count","50"]]}'
```

## Per-controller behaviour

| Controller | Status |
|---|---|
| **Default Lyrion web UI** | Full feature set, including text-input items. |
| **Material Skin** | Full feature set. Theme-aware: status panel uses neutral `rgba(127,127,127,…)` overlays so it works on light AND dark themes. |
| **iPeng** | Full feature set. |
| **Squeezer (Android)** | Tap-only items work fine. Text-input items (Instant Playlist, Find Path) render but can't be activated — Squeezer doesn't render Jive `input` fields. **Use the context-menu shortcut** (My Music → Artists/Songs → tap → AudioMuse: similar) for typed-search-style flows. |
| **SqueezePlay / Touch / Boom** | Built-in player controllers — should work via the same Jive protocol. Untested. |

## CLI / JSON-RPC reference

Every menu action has a CLI command exposed via Lyrion's `/jsonrpc.js` endpoint, useful for Material Skin custom buttons, Home Assistant automations, scripting.

See [`AudioMuseAI/README.md`](AudioMuseAI/README.md#cli--json-rpc-reference) for the full list with example payloads.

Quick samples:

```bash
# Similar to whatever player <id> is currently playing
{"params":["bb:bb:55:90:9c:db",["audiomuseai","similar_now"]]}

# Sonic fingerprint
{"params":["bb:bb:55:90:9c:db",["audiomuseai","sonic_fp"]]}

# Instant playlist with a prompt
{"params":["bb:bb:55:90:9c:db",["audiomuseai","instant","prompt:low-energy ambient"]]}

# Save current queue (uses your auto-name format setting)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","save_playlist"]]}

# Get live server status (structured JSON for dashboards)
{"params":["",["audiomuseai","server_status"]]}

# Library coverage stats (artists, albums, CLAP-indexed, etc.)
{"params":["",["audiomuseai","library_summary"]]}

# Cancel the currently running AudioMuse task
{"params":["",["audiomuseai","cancel_active"]]}
```

## How AudioMuse-AI features map to plugin items

| AudioMuse feature | Plugin entry |
|---|---|
| Sonic similarity | **Similar to current track**, **Similar to a song**, **Similar to an artist** |
| Sonic fingerprint | **Sonic Fingerprint** |
| Instant playlist (CLAP) | **Instant Playlist (text)**, **Browse by Mood** (preset prompts), **Popular CLAP searches** (community queries) |
| Chat-driven playlist (LLM via AudioMuse's `AI_MODEL_PROVIDER`) | **AI Chat Playlist** |
| Song Alchemy | **Song Alchemy** submenu |
| Song Paths | **Build a sonic journey between two songs** |
| Music Map | **Open Music Map** (link to web UI) |
| Library coverage | Settings → Server Status panel (artists / albums / CLAP-indexed / clustered / top moods) |
| Analysis / clustering / cancel | **Server Status / Admin** submenu (incl. cancel running task) |
| Health probe | Internal — `/api/health` used for the startup connectivity log |

## Limitations and gotchas

- **Similarity needs clustering done.** Until your AudioMuse instance has completed analysis *and* run clustering at least once, `Similar to *` will return *"Service not ready"*. Sonic Fingerprint, Instant Playlist, and Browse-by-Mood work earlier (after analysis but before clustering) — they use CLAP embeddings rather than the similarity index.
- **Squeezer can't render Jive `input` fields.** Instant Playlist, Find Path, and the typed override for Save Playlist appear in the menu but won't react to taps. Use the context-menu items from My Music → Artists/Songs as the workaround.
- **Track IDs assumed stable.** AudioMuse stores track IDs as Lyrion gave them at scan time. If you re-scan and Lyrion reassigns IDs, you'll need to re-run AudioMuse analysis. (Rare in practice.)
- **Recent prompts** are remembered per-player but no longer surface in any UI menu (was simplified for Squeezer compat in v0.2.16). They're still readable via the `audiomuseai menu_instant` JSON-RPC command.
- **Find Path** is the most niche feature — only useful if you specifically want a sonic-transition mix between two tracks. Buried in Tier 5 for that reason.

## Troubleshooting

**"Service not ready" on every menu** — clustering hasn't completed. Check **Server Status → Show active tasks** for progress. Trigger analysis / clustering from the same submenu if needed.

**Test Connection fails** — check the URL has a scheme, the token is correct, and Lyrion can reach the host (try `curl <url>/api/active_tasks` from the Lyrion box).

**Squeezer menu flashes and disappears** — this should be fixed in v0.2.18+. If it recurs, check the Lyrion log (`server.log`) for `plugin.audiomuseai` entries to see whether the dispatcher is being reached and what's being returned.

**Logs**: tail Lyrion's `server.log` and grep for `plugin.audiomuseai`. Set the category to DEBUG via **Settings → Advanced → Logging** for verbose output.

## Manual install (without the repo URL)

```bash
LYRION_PLUGINS=/var/lib/lyrion/Plugins   # adjust to your install
sudo rsync -av AudioMuseAI/ "$LYRION_PLUGINS/AudioMuseAI/"
sudo systemctl restart lyrion-music-server
```

Common plugin-directory paths:

| Install style | Path |
|---|---|
| Debian/Ubuntu .deb | `/var/lib/squeezeboxserver/Plugins/` |
| Arch (`lyrion-music-server`) | `/var/lib/lyrion/Plugins/` |
| Container (lmscommunity/lyrion) | `/lms/Plugins/` (mount your own) |
| User install | `~/.lyrion/Plugins/` or `~/.squeezebox/Plugins/` |

## Iterating / contributing

Releases are managed via GitHub. The cycle:

1. Bump version in `AudioMuseAI/install.xml` and `AudioMuseAI/Plugin.pm` (`VERSION` constant).
2. Build the ZIP, compute SHA1, attach to a GitHub release.
3. Update `extensions.xml` with the new version + URL + SHA1.
4. Refresh the repo URL in Lyrion (↻ button next to the URL).

Issues and PRs welcome.

## License

MIT — see [LICENSE](LICENSE).

## Credits

- [AudioMuse-AI](https://github.com/NeptuneHub/AudioMuse-AI) by NeptuneHub — the upstream project providing all the sonic analysis.
- [Lyrion Music Server](https://lyrion.org) — the music server framework.
- Plugin development pattern cribbed from [AF-1's Dynamic Playlists 4](https://github.com/AF-1/lms-dynamicplaylists), the gold standard for LMS plugins.
