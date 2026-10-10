# Troubleshooting, limitations & manual install

## Common issues

**"Service not ready" on the similarity items** — your AudioMuse-AI instance hasn't finished analysis *and* run clustering at least once. Check **Server Status → Show active tasks** for progress, and trigger analysis / clustering from the same submenu if needed. (Sonic Fingerprint, Instant Playlist, and Browse-by-Mood work earlier — they use CLAP embeddings rather than the similarity index.)

**Can't find the "AudioMuse: similar…" context-menu items in Material** — they're there, just under **More**. Material's long-press / **⋮** menu lists the common actions first (Play, Add to queue, Favourites…) and tucks plugin items into a **More** submenu. Path: long-press (or **⋮**) → **More** → *AudioMuse: …*. On the default web UI and iPeng they appear directly in the context menu.

**Fewer tracks than requested, or "not analysed" on a song you know AudioMuse has** — AudioMuse remembers your tracks by the id Lyrion gave them when it analysed them. A Lyrion rescan / wipe-and-rescan renumbers tracks, and until AudioMuse re-maps them its ids point at tracks Lyrion no longer has (on a busy library this can be a quarter of results). Since v0.6.0 the plugin copes: it re-finds each stale result in your library by title + artist, and if AudioMuse doesn't know the id of the song you're seeding from, it looks the song up by title + artist and retries. `server.log` then says *"N result id(s) not in the Lyrion library (stale AudioMuse mapping...)"*. To fix it at the source, in AudioMuse-AI run **Setup → Music Servers → Align music servers** (or a per-server *Sweep*), then a **Cleaning** run with *delete orphans* enabled.

**Test connection fails** — check the URL has a scheme, the token is correct, and Lyrion can reach the host. From the Lyrion box: `curl <url>/api/active_tasks`. If you've set **AudioMuse music server name**, Test connection also checks AudioMuse actually has a server by that name (case doesn't matter) and lists the ones it has if not.

**Every action says "AudioMuse-AI rejected the request - check the AudioMuse music server name setting"** — the server name in the plugin settings doesn't match any music server in AudioMuse-AI's Setup page. Fix the spelling (Test connection shows the valid names) or clear it if Lyrion is AudioMuse's default server.

**AudioMuse-AI isn't on the default web interface's Home page** — it is since v0.6.1 (under My Music, near Random Mix); update the plugin. Actions need a player selected at the top right of the page.

**A menu flashes and disappears (Squeezer)** — should be fixed in recent versions. If it recurs, check `server.log` for `plugin.audiomuseai` entries to see what the dispatcher returned.

**A confirmation shows raw `<div …>` text (Material)** — fixed in v0.3.2; update the plugin.

**Logs** — tail Lyrion's `server.log` and grep for `plugin.audiomuseai`. Set that category to **Debug** under **Settings → Advanced → Logging** for verbose output.

## Limitations & gotchas

- **Similarity needs clustering done.** Until analysis *and* clustering have completed once, `Similar to *` returns "Service not ready". CLAP-based features (Fingerprint, Instant, Mood) work after analysis alone.
- **Track IDs drift after a Lyrion rescan.** See *Fewer tracks than requested* above — the plugin works around it, but an AudioMuse *Align music servers* run fixes it properly.
- **Anti-repeat history is in memory.** The "recently played" list (1000 songs per player) resets when Lyrion restarts; songs already in the queue are always excluded regardless.
- **Album Creation** needs AudioMuse v3.6.2 with MusiCNN, DCLAP and lyrics analysis all enabled; **Explore** needs the hyperbolic index (an analysis run on v3.3+). Otherwise those items explain what's missing.
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
