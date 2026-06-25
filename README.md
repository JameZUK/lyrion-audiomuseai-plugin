# lyrion-audiomuseai-plugin

A plugin for [Lyrion Music Server](https://lyrion.org) that brings [AudioMuse-AI's](https://github.com/NeptuneHub/AudioMuse-AI) sonic-similarity features into the standard Lyrion controllers (web UI, Material Skin, iPeng, Squeezer) — under **My Music → AudioMuse-AI**.

> You already control playback from a Lyrion controller; this plugin makes AudioMuse-AI's playlists tap-reachable from the same place, instead of a separate web UI.

Requires a running [AudioMuse-AI](https://github.com/NeptuneHub/AudioMuse-AI) instance.

## Install

1. In Lyrion: **Settings → Plugins → Additional Repositories**, paste this URL:

   ```
   https://raw.githubusercontent.com/JameZUK/lyrion-audiomuseai-plugin/main/extensions.xml
   ```

2. Apply, tick **AudioMuse-AI** in the third-party plugin list, Apply, and restart Lyrion when prompted.
3. Open **Settings → Plugins → AudioMuse-AI**, set your **Server URL** (e.g. `http://localhost:8000`) and **API token** (from the AudioMuse-AI web UI → Administration), then hit **Test connection**.

Prefer to install by hand? See [docs/TROUBLESHOOTING.md → Manual install](docs/TROUBLESHOOTING.md#manual-install).

## What you get

Under **My Music → AudioMuse-AI**:

- **One-tap playlists** — Similar to current track, Sonic Fingerprint, Browse by Mood, Popular searches.
- **Browse & pick** — find tracks similar to any artist or song, with a search box to jump straight to a name.
- **Text prompts** — Instant Playlist, AI Chat Playlist (LLM), Lyrics search, and Find Path between two songs. *(web UI / Material / iPeng — these need a keyboard.)*
- **Sessions** — Song Alchemy (blend tracks) and Dynamic Playlists (keep the queue topped up).
- **Save & admin** — save the queue as a playlist, plus server status / analysis / clustering controls.

It also adds **context-menu items** to Lyrion's normal browse (*AudioMuse: similar artists / similar tracks / alchemy from album*) and registers two native **Don't Stop The Music** providers.

→ Full menu walkthrough: **[docs/USAGE.md](docs/USAGE.md)**

## Two shortcuts worth knowing

- **Context menu** — browse to any artist, track, or album normally and use the context menu (right-click in the web UI / long-press in Material / 3-dot in iPeng) → **AudioMuse: similar…**. You get Lyrion's native filtering and letter-jump for free. This is the recommended path on Squeezer.
- **Auto-extend** — pick an **AudioMuse-AI** entry under Player Settings → Audio → *Don't Stop The Music* (or start a **Dynamic Playlists** mode), and the queue refills itself with matching tracks as it runs low.

## Documentation

| Doc | Covers |
|---|---|
| **[Usage & menu reference](docs/USAGE.md)** | Every menu item, the fastest paths, per-controller behaviour, feature map. |
| **[Settings](docs/SETTINGS.md)** | All settings, auto-name strategies, Don't Stop The Music, per-player overrides. |
| **[CLI / JSON-RPC](docs/CLI.md)** | Drive every action from scripts, Home Assistant, or Material custom buttons. |
| **[Troubleshooting](docs/TROUBLESHOOTING.md)** | Common issues, limitations, manual install. |

## License

MIT — see [LICENSE](LICENSE).

## Credits

- [AudioMuse-AI](https://github.com/NeptuneHub/AudioMuse-AI) by NeptuneHub — the upstream project providing all the sonic analysis.
- [Lyrion Music Server](https://lyrion.org) — the music-server framework.
- Plugin development patterns cribbed from [AF-1's Dynamic Playlists 4](https://github.com/AF-1/lms-dynamicplaylists), a gold-standard LMS plugin.
