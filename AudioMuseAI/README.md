# AudioMuse-AI plugin for Lyrion Music Server

Adds an **AudioMuse-AI** entry under **My Music** in Lyrion that exposes:

- **Status header** — when analysis or clustering is running, the top of the submenu shows current task type and progress %.
- **Similar to current track** — extend or replace the queue with sonically similar tracks.
- **Similar to song...** — text-search by artist, pick a track, queue similar.
- **Similar to artist...** — pick an artist; queue a blend of music in that artist's vein.
- **Sonic Fingerprint** — playlist generated from your listening history.
- **Create an album** — AudioMuse Album Creation (v3.6.2) around the current track or from a description.
- **Explore around current track** — hyperbolic map: close neighbours, roots, niche (v3.3+).
- **Sonic moods / Lyric themes** — tap-only browsing of AudioMuse's mood clusters and lyrics axes.
- **Instant Playlist (text prompt)** — natural-language playlist via the AudioMuse CLAP model. Recent prompts are remembered per player.
- **Browse by Mood** — seven preset CLAP prompts (Energetic, Calm, Sad, Happy, Aggressive, Acoustic, Party) plus a custom prompt.
- **Song Alchemy** — per-player ADD/SUBTRACT lists of tracks, artists, Lyrion playlists and saved anchors; "Generate" calls AudioMuse alchemy with your selection.
- **Alchemy radios and anchors** — play a saved radio / anchor now, or rebuild the radio playlists.
- **Find Path** — sonic, lyrics + sound, or hyperbolic journey from the current track to a picked one.
- **Dynamic Playlists** — DSTM-style auto-extend (similar / SemGrove / album / fingerprint), with a per-player "Stop auto-extend". Never re-queues a song already queued or recently played.
- **Server Status / Admin** — show active task, last task, trigger analysis/clustering. Errors that mean "AudioMuse is busy" include live status inline.
- **Save current queue as playlist...** — name the queue and save it to Lyrion.
- **Open Music Map** — clickable link to the AudioMuse-AI web UI.

Backed by the AudioMuse-AI REST API. Bearer-token auth supported. Settings page includes a live server-status panel and a Test Connection button that polls the result via JSON-RPC without a manual page refresh.

## Install

Use the bundled extensions repository (one-line URL paste in Lyrion → Settings → Plugins → Additional Repositories):

```
https://raw.githubusercontent.com/JameZUK/lyrion-audiomuseai-plugin/main/extensions.xml
```

Or drop `Plugins/AudioMuseAI/` into your Lyrion plugin directory manually:

```bash
LYRION_PLUGINS=/var/lib/lyrion/Plugins   # adjust to your install
sudo rsync -av AudioMuseAI/ "$LYRION_PLUGINS/AudioMuseAI/"
sudo systemctl restart lyrion-music-server
```

## Configure

**Settings → Plugins → AudioMuse-AI**:

- **Server URL**: e.g. `http://localhost:8000` (auto-prefixes `http://` if you forget).
- **API token**: bearer token from the AudioMuse Administration UI. Whitespace and CR/LF are stripped.
- **Default count**: 5–100 (clamped). Per-player override available via CLI; see below.
- **Auto-extend**: enables DSTM-style queue refilling once a Dynamic Playlists mode is started.
- **Test connection** runs a live probe; the result updates in place via JSON-RPC polling.
- **Server status panel** shows progress, running time, and last log line; auto-refreshes every 10s while tasks are running.

## CLI / JSON-RPC reference

Every menu action has a CLI command, exposed via Lyrion's `/jsonrpc.js` endpoint. Useful for Material Skin custom buttons, Home Assistant automations, or the `slimp3 cli` interface.

### Player-required commands

Pass `<playerid>` as the first array element (the MAC address of the player, e.g. `bb:bb:55:90:9c:db`):

```bash
# similar to currently-playing track
curl -X POST http://lyrion:9000/jsonrpc.js -H "Content-Type: application/json" -d '
  {"id":1,"method":"slim.request","params":["bb:bb:55:90:9c:db",["audiomuseai","similar_now"]]}'

# instant playlist (text prompt → queue)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","instant","prompt:low-energy late night ambient"]]}

# mood (preset prompt)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","mood","prompt:energetic, upbeat, high tempo"]]}

# similar to a specific track id (Lyrion track ID, integer)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","similar_track","track_id:2042418"]]}

# "music like this artist" — one shot, a blend in the artist's vein.
# Pass artist_id (Lyrion contributor id) for a picked library artist so its
# tracks resolve locally; a free-typed `artist:` name uses AudioMuse's search.
{"params":["bb:bb:55:90:9c:db",["audiomuseai","similar_artist","artist:Olivia Rodrigo"]]}
{"params":["bb:bb:55:90:9c:db",["audiomuseai","similar_artist","artist_id:184394"]]}

# sonic fingerprint (player's listening-history-based playlist)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","sonic_fp"]]}

# alchemy (per-player ADD / SUBTRACT)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","alchemy_add_now"]]}      # adds current track to ADD
{"params":["bb:bb:55:90:9c:db",["audiomuseai","alchemy_sub_now"]]}      # adds current track to SUBTRACT
{"params":["bb:bb:55:90:9c:db",["audiomuseai","alchemy_show"]]}         # show current selection
{"params":["bb:bb:55:90:9c:db",["audiomuseai","alchemy_reset"]]}        # clear
{"params":["bb:bb:55:90:9c:db",["audiomuseai","alchemy_generate"]]}     # call AudioMuse alchemy

# alchemy with artists / playlists / anchors (v3)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","alchemy_add_artist"]]}   # current track's artist -> ADD
{"params":["bb:bb:55:90:9c:db",["audiomuseai","alchemy_sub_artist"]]}   # current track's artist -> SUBTRACT
{"params":["bb:bb:55:90:9c:db",["audiomuseai","alchemy_add_ref","ref:playlist:2205630"]]}  # or ref:anchor:<id>

# find path (current -> end track id). method: sonic | lyrics | hyperbolic
{"params":["bb:bb:55:90:9c:db",["audiomuseai","findpath_search","artist:Phish","method:hyperbolic"]]}  # picker
{"params":["bb:bb:55:90:9c:db",["audiomuseai","findpath_to","start_id:N","end_id:M","method:lyrics"]]}

# album creation (v3.6.2)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","album_now"]]}
{"params":["bb:bb:55:90:9c:db",["audiomuseai","album_track","track_id:2112964"]]}
{"params":["bb:bb:55:90:9c:db",["audiomuseai","album_text","prompt:jazz piano female voice"]]}

# hyperbolic explore (v3.3+). mode: similar | roots | niche
{"params":["bb:bb:55:90:9c:db",["audiomuseai","explore_now","mode:niche"]]}
{"params":["bb:bb:55:90:9c:db",["audiomuseai","explore_track","track_id:2112964","mode:roots"]]}

# sonic mood cluster / lyric theme / saved anchor or radio
{"params":["bb:bb:55:90:9c:db",["audiomuseai","sonic_mood","mood:happy","index:0"]]}
{"params":["bb:bb:55:90:9c:db",["audiomuseai","lyric_theme","axis:AXIS_1_SETTING","label:URBAN"]]}
{"params":["bb:bb:55:90:9c:db",["audiomuseai","anchor_play","anchor_id:1","n:50"]]}

# instant playlist with DCLAP concept steering (v3.5.1)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","instant","prompt:jazz with viola | +viola x3, -drums"]]}

# dynamic playlists (sets DSTM mode + does an immediate fill)
{"params":["bb:bb:55:90:9c:db",["audiomuseai","dyn_similar"]]}
{"params":["bb:bb:55:90:9c:db",["audiomuseai","dyn_semgrove"]]}
{"params":["bb:bb:55:90:9c:db",["audiomuseai","dyn_album"]]}
{"params":["bb:bb:55:90:9c:db",["audiomuseai","dyn_fingerprint"]]}
{"params":["bb:bb:55:90:9c:db",["audiomuseai","dyn_stop"]]}

# save current Lyrion queue as a playlist
{"params":["bb:bb:55:90:9c:db",["audiomuseai","save_playlist","name:Late Night Mix"]]}
```

### Server-wide commands (no player required)

```bash
# admin
{"params":["",["audiomuseai","run_analysis"]]}
{"params":["",["audiomuseai","run_clustering"]]}

# status / introspection
{"params":["",["audiomuseai","status_active"]]}
{"params":["",["audiomuseai","status_last"]]}
{"params":["",["audiomuseai","server_status"]]}    # structured fields
{"params":["",["audiomuseai","test_result"]]}      # last connection test outcome
{"params":["",["audiomuseai","open_map"]]}
```

### Per-player default count override

The plugin's default count (5–100) is server-global, but each player can have its own override via Lyrion's standard player-pref command. There's no UI for this yet:

```bash
# set Living Room player to use 50 by default
curl -X POST http://lyrion:9000/jsonrpc.js -H "Content-Type: application/json" -d '
  {"id":1,"method":"slim.request","params":["bb:bb:55:90:9c:db",
    ["pref","plugin.audiomuseai:default_count","50"]]}'

# clear it (revert to global default)
{"params":["bb:bb:55:90:9c:db",["pref","plugin.audiomuseai:default_count",""]]}
```

The plugin will use the per-player value when set; otherwise it falls back to the global default.

## Operation notes

- **Track ID compatibility**: AudioMuse returns Lyrion's numeric track ids. After a Lyrion rescan some can be stale; the plugin re-finds those by title + artist, and translates seeds AudioMuse doesn't know (see docs/TROUBLESHOOTING.md).
- **No repeats**: every append / auto-extend filters out tracks already in the queue, the player's last 1000 played songs, and other copies of the same song (same primary artist + title, ignoring "(Live)", "(Remastered)" etc.).
- **DSTM (auto-extend)**: enable in plugin settings. When a player's queue drops to ≤ 3 remaining tracks, the plugin asks AudioMuse for 10 more new tracks (similar / SemGrove / album / fingerprint, whichever mode is active for that player) and appends them. Use **Dynamic Playlists → Continuous similar / Continuous fingerprint** to set the mode for the current player; **Stop auto-extend** clears it.
- **Recent prompts**: the last 5 prompts you typed into Instant Playlist are remembered per player and offered as quick-pick items inside the Instant Playlist submenu.
- **Server-busy handling**: when AudioMuse returns 503 ("similarity service unavailable") or 409 ("already running"), the plugin fetches live server state and shows it in the same popup so you know what's going on without navigating to Server Status.
- **Logs**: tail Lyrion's server log (`server.log` in the prefs directory) and look for `plugin.audiomuseai`. Set the category to DEBUG via **Settings → Advanced → Logging** for verbose output.

## File layout

```
AudioMuseAI/
├── install.xml          plugin metadata for Lyrion
├── Plugin.pm            menu registration, CLI dispatch, DSTM hook
├── Settings.pm          web settings page handler
├── API.pm               async HTTP wrapper for AudioMuse REST
├── strings.txt          i18n strings
├── README.md            this file
└── HTML/EN/plugins/AudioMuseAI/settings/
    └── basic.html       settings page template (incl. live status panel)
```
