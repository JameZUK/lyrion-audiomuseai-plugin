# Troubleshooting, limitations & manual install

## Common issues

**"Service not ready" on the similarity items** — your AudioMuse-AI instance hasn't finished analysis *and* run clustering at least once. Check **Server Status → Show active tasks** for progress, and trigger analysis / clustering from the same submenu if needed. (Sonic Fingerprint, Instant Playlist, and Browse-by-Mood work earlier — they use CLAP embeddings rather than the similarity index.)

**Can't find the "AudioMuse: similar…" context-menu items in Material** — they're there, just under **More**. Material's long-press / **⋮** menu lists the common actions first (Play, Add to queue, Favourites…) and tucks plugin items into a **More** submenu. Path: long-press (or **⋮**) → **More** → *AudioMuse: …*. On the default web UI and iPeng they appear directly in the context menu.

**Test connection fails** — check the URL has a scheme, the token is correct, and Lyrion can reach the host. From the Lyrion box: `curl <url>/api/active_tasks`.

**A menu flashes and disappears (Squeezer)** — should be fixed in recent versions. If it recurs, check `server.log` for `plugin.audiomuseai` entries to see what the dispatcher returned.

**A confirmation shows raw `<div …>` text (Material)** — fixed in v0.3.2; update the plugin.

**Logs** — tail Lyrion's `server.log` and grep for `plugin.audiomuseai`. Set that category to **Debug** under **Settings → Advanced → Logging** for verbose output.

## Limitations & gotchas

- **Similarity needs clustering done.** Until analysis *and* clustering have completed once, `Similar to *` returns "Service not ready". CLAP-based features (Fingerprint, Instant, Mood) work after analysis alone.
- **Squeezer can't render Jive `input` fields.** Instant Playlist, AI Chat, Lyrics search, Find Path, and the typed name for Save Playlist appear but won't react to taps. Use the context-menu items from My Music → Artists / Songs as the workaround.
- **Track IDs are assumed stable.** AudioMuse stores track IDs as Lyrion assigned them at scan time. If you re-scan and Lyrion reassigns IDs, re-run AudioMuse analysis. (Rare in practice.)
- **Recent prompts** are remembered per-player but no longer surface in a menu (simplified for Squeezer compatibility). Still readable via the `audiomuseai menu_instant` JSON-RPC command.
- **Find Path** is the most niche feature — only useful for a deliberate sonic transition between two specific tracks.

## Manual install

Without the repository URL, copy the plugin folder into Lyrion's plugins directory and restart:

```bash
LYRION_PLUGINS=/var/lib/lyrion/Plugins   # adjust to your install
sudo rsync -av AudioMuseAI/ "$LYRION_PLUGINS/AudioMuseAI/"
sudo systemctl restart lyrion-music-server
```

Common plugin-directory paths:

| Install style | Path |
|---|---|
| Debian/Ubuntu `.deb` | `/var/lib/squeezeboxserver/Plugins/` |
| Arch (`lyrion-music-server`) | `/var/lib/lyrion/Plugins/` |
| Container (lmscommunity/lyrion) | `/lms/Plugins/` (mount your own) |
| User install | `~/.lyrion/Plugins/` or `~/.squeezebox/Plugins/` |

(On a packaged install the repo-managed copy lives under `…/cache/InstalledPlugins/Plugins/AudioMuseAI/`.)
