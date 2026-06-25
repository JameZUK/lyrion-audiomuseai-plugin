# Settings

**Settings → Plugins → AudioMuse-AI.**

| Setting | What it does |
|---|---|
| **Server URL** | Where AudioMuse-AI is running. `http://` is auto-prefixed; trailing slashes are stripped. |
| **API token** | Bearer token from the AudioMuse-AI web UI → Administration. Whitespace trimmed; CR/LF rejected. |
| **Default count** | How many tracks AudioMuse returns per request (clamped 5–100). |
| **Auto-extend the queue (DSTM)** | Lets the plugin's own Dynamic Playlists modes refill the queue when it drops to ≤ 3 remaining. (Auto-enabled the first time you start a Dynamic Playlists mode.) See also [Don't Stop The Music](#dont-stop-the-music). |
| **Auto-name format** | How "Save current queue" names playlists when you don't type a name. See [below](#auto-name-strategies). |
| **Auto-save Instant Playlist results** | After every Instant Playlist, save the queue as `AudioMuse: <prompt>`. |
| **Auto-save Browse-by-Mood results** | After tapping a Mood preset, save as `AudioMuse: <mood> - <timestamp>`. |
| **Test connection** | Probes the server; result is polled in-place via JSON-RPC. |

The settings page also shows a live **Server Status panel** — current task (status message, state, progress %, running time, last log line) plus a **Library coverage** section (artists, albums, CLAP-indexed tracks, clustered tracks, top moods). It auto-refreshes every 10 s while a task is running.

## Auto-name strategies

How **Save current queue as playlist** titles a playlist when no name is typed:

| Strategy | Example |
|---|---|
| **Timestamp** (default) | `AudioMuse 2026-05-03 14:30` |
| **First track** | `AudioMuse: 1933 - Frank Turner` |
| **Artist mix** | `AudioMuse: Frank Turner, Phish, U2 (24t)` |
| **Mood-tagged** | `AudioMuse: Calm / Ambient - 2026-05-03 14:30` |
| **Last Instant prompt** | `AudioMuse: low-energy late-night ambient` |

> **No AI is used for naming.** AudioMuse-AI's CLAP search is an audio-embedding model, not an LLM. Names are derived from local data — timestamp, queue contents, your typed prompt, or the mood label.

## Don't Stop The Music

The plugin registers two native **Don't Stop The Music** providers, so AudioMuse-AI appears in the per-player dropdown alongside MusicIP / SugarCube / LastMix:

- **AudioMuse-AI: Similar to recent tracks** — extends the queue with tracks similar to what was just playing.
- **AudioMuse-AI: Sonic fingerprint** — extends from your library's sonic fingerprint.

Set it under **Player Settings → Audio → Don't Stop The Music**. It's per-player, and when active it takes over auto-extend for that player (the plugin's own Dynamic Playlists auto-extend stands down to avoid double-filling).

This is independent of the **Auto-extend the queue** checkbox above, which only governs the plugin's own menu-based Dynamic Playlists modes.

## Per-player default count override

The default count is server-global, but each player can override it via Lyrion's standard pref CLI (no dedicated UI):

```bash
# 'Living Room' player uses 50 instead of the global default
curl -X POST http://lyrion:9000/jsonrpc.js -H "Content-Type: application/json" \
  -d '{"id":1,"method":"slim.request","params":["bb:bb:55:90:9c:db",
       ["pref","plugin.audiomuseai:default_count","50"]]}'
```

Clear it (revert to the global default) by setting the value to an empty string.
