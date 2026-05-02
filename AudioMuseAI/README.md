# AudioMuse-AI plugin for Lyrion Music Server

Adds an **AudioMuse-AI** entry under **My Music** in Lyrion that exposes:

- **Similar to current track** — replace nothing-playing or extend the queue with sonically similar tracks.
- **Sonic Fingerprint** — load a playlist generated from your listening history.
- **Instant Playlist (text prompt)** — natural-language playlist via the AudioMuse CLAP model (e.g. "low-energy late-night ambient").
- **Similar to artist...** — pick an artist, get the top similar artist's tracks queued.
- **Dynamic Playlists** — the same flows but with auto-extend (Don't Stop The Music style) when the queue runs low.
- **Open Music Map** — link to the AudioMuse web UI for visual exploration.

Works against the AudioMuse-AI REST API (`/api/similar_tracks`, `/api/sonic_fingerprint/generate`, `/api/clap/search`, `/api/similar_artists`, `/api/search_tracks`). Bearer-token auth supported.

> **Note:** Similarity (`/api/similar_tracks`, `/api/similar_artists`) requires AudioMuse to have completed analysis **and** clustering at least once. Until that's done, those menu items return *"Similarity service not ready"*. Sonic Fingerprint, Instant Playlist, and Search work earlier.

## Install

Plugin lives at `Plugins/AudioMuseAI/` inside Lyrion's plugin directory. Common locations:

| Install style              | Path                                       |
|----------------------------|--------------------------------------------|
| Debian/Ubuntu .deb         | `/var/lib/squeezeboxserver/Plugins/`       |
| Arch (`lyrion-music-server`) | `/var/lib/lyrion/Plugins/`               |
| Container (lmscommunity/lyrion) | `/lms/Plugins/` (mount your own)      |
| User install               | `~/.lyrion/Plugins/` or `~/.squeezebox/Plugins/` |

To deploy from the build directory in `/home/james/temp/lyrion-plugin/`:

```bash
# adjust LYRION_PLUGINS to your install
LYRION_PLUGINS=/var/lib/lyrion/Plugins
sudo rsync -av /home/james/temp/lyrion-plugin/AudioMuseAI/ "$LYRION_PLUGINS/AudioMuseAI/"
sudo systemctl restart lyrion       # or `lyrion-music-server`, `squeezeboxserver`
```

If Lyrion is in a Docker/LXC, copy the directory in and restart the container.

After restart:

1. Open Lyrion's web UI.
2. **Settings → Plugins** — confirm AudioMuse-AI is enabled.
3. **Settings → Advanced → AudioMuse-AI** (or **Plugins** tab) — set:
   - **AudioMuse-AI server URL**: `http://localhost:8000`
   - **API token**: paste your Bearer token from AudioMuse's admin UI.
   - Click **Test connection** — should report `✓ Connected`.
4. Open **My Music** → **AudioMuse-AI** to use it.

## Operation notes

- **Track ID compatibility**: AudioMuse stores tracks by the same numeric ID Lyrion gives them at scan time, so no mapping table is needed. If you re-scan and Lyrion reassigns IDs (rare), you'll need to re-run AudioMuse analysis.
- **DSTM (auto-extend)**: enable in plugin settings. When a player's queue drops to ≤ 3 remaining tracks, the plugin asks AudioMuse for 10 more similar/fingerprint tracks (whichever mode you last triggered) and appends them. Using **Dynamic Playlists → Continuous similar / Continuous fingerprint** sets the mode for that player.
- **Logs**: tail Lyrion's server log (`server.log` in the prefs directory) and look for `plugin.audiomuseai`. Set the category to DEBUG via **Settings → Advanced → Logging** for verbose output.

## Limitations / not yet implemented

- **Song Alchemy** and **Find Path** UI — backend calls are wired in `API.pm` (`alchemy()`, `find_path()`) but no menu yet. Use the AudioMuse web UI for these.
- **Material skin native theming** — menus render via the standard Jive bridge, which Material picks up automatically. No special-cased Material UI.
- **Per-player default counts** — the count pref is server-global. Per-player override is straightforward to add (`$prefs->client($client)->get('default_count')`) if needed.
- **Dynamic Playlists 4 integration** — the standalone "Dynamic Playlists" submenu provides DSTM-style auto-extend without DP4 installed. For full DP4 provider integration (smart playlists like "20 high-energy from artist X"), a follow-up `Plugins::AudioMuseAI::DPL` provider module would register with DP4.

## File layout

```
AudioMuseAI/
├── install.xml                                 plugin metadata for Lyrion
├── Plugin.pm                                   menu registration + CLI dispatch
├── Settings.pm                                 web settings page handler
├── API.pm                                      async HTTP wrapper for AudioMuse REST
├── strings.txt                                 i18n
├── README.md                                   this file
└── HTML/EN/plugins/AudioMuseAI/settings/
    └── basic.html                              settings page template
```
