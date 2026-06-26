# Usage & menu reference

Everything under **My Music → AudioMuse-AI**, plus the two shortcuts that bypass the menu entirely. For settings see [SETTINGS.md](SETTINGS.md); for scripting see [CLI.md](CLI.md).

## The menu

Entries are ordered by how often you'll reach for them.

### One-tap actions

| Item | What it does | Needs |
|---|---|---|
| **Similar to current track** | Queues tracks sonically similar to whatever's playing now (audio only). | Clustering done. |
| **Similar (sound + lyrics) to current track** | Like the above, but matches on the **merged lyrics+audio** index (SemGrove) — considers what the words *mean*, not just how it sounds. | Lyrics + audio analysis for the seed. |
| **Sonic Fingerprint** | Replaces the queue with a personalised playlist built from your listening history. | A few hundred plays logged. |
| **Browse by Mood** | Seven preset CLAP prompts (Energetic, Calm, Sad, Happy, Aggressive, Acoustic, Party). Tap one to queue a matching playlist. | Analysis done (CLAP cache). |
| **Popular searches** | Community-popular search prompts pulled from your AudioMuse-AI server. Tap any phrase to queue. | Analysis done. |

### Browse & pick

Both of these start with a **"Search for an artist…"** box — type a name, or scroll the alphabetical, paged artist list below it.

| Item | Flow |
|---|---|
| **Similar to an artist (pick from library)…** | Search or pick an artist → queues tracks by the most similar artist. |
| **Similar to a song (pick artist, then track)…** | Search or pick an artist → pick one of their analyzed tracks → queues sonically similar tracks. |

### Sessions / advanced

| Item | What it does |
|---|---|
| **Dynamic Playlists** | Three modes: *Continuous similar to current track*, *Continuous from sonic fingerprint*, *Stop auto-extend*. Starting a mode keeps the queue refilled when it runs low. See [Auto-extend](#auto-extend) below. |
| **Song Alchemy** | Per-player ADD / SUBTRACT lists. Add the current track to ADD, add another to SUBTRACT, then **Generate** to get a sonic blend that leans toward the first set and away from the second. |
| **AudioMuse Radios** | Lists the saved "radios" (stations — anchor + size) you define in the AudioMuse-AI web UI. **Run all radios** asks AudioMuse to (re)build one Lyrion playlist per enabled radio, then you'll find them under Playlists. There's no per-radio "play now" — running rebuilds the playlists. |

### Tools

| Item | What it does |
|---|---|
| **Save current queue as playlist (auto-named)** | Saves the current queue. The name comes from your [auto-name setting](SETTINGS.md#auto-name-strategies); on the web UI / Material you can type a custom name instead. |

### Text input

These need an on-screen keyboard, and work on every controller (web UI, Material, iPeng, Squeezer).

| Item | What it does |
|---|---|
| **Instant Playlist** | Type a description (e.g. "low-energy late-night ambient"); AudioMuse's CLAP search returns matching tracks and replaces the queue. Optionally auto-saved as `AudioMuse: <prompt>`. |
| **AI Chat Playlist** | Same UX, but powered by the LLM configured on your AudioMuse-AI server (Gemini / OpenAI / Mistral / Ollama). Plain language → AI-generated SQL → tracks. Needs `AI_MODEL_PROVIDER` set server-side. |
| **Find tracks by lyric phrase** | Free-text search against the lyrics index — queues tracks whose lyrics match your phrase. |
| **Find Path between two songs** | Builds a sonic-transition playlist from the current track to a chosen end track. Niche but handy for smooth genre/mood segues. |

### Status / link-out

| Item | What it does |
|---|---|
| **Server Status / Admin** | Show active task, show last task, trigger analysis, trigger clustering, **cancel running task**. "Busy / unavailable" errors elsewhere include live status inline. |
| **Open Music Map** | Opens the AudioMuse-AI web UI on controllers that honour Jive `weblink` (Material, web UI, iPeng); shows the URL as text otherwise. |

## Two shortcuts that skip the menu

### Context menu

The plugin registers info-providers for artists, tracks, and albums. **Browse normally** (My Music → Artists, type to filter, tap an artist) and open the item's context menu — right-click (web UI), long-press or the **⋮** icon (Material), 3-dot (iPeng). It includes:

- **AudioMuse: similar artists** — on any artist
- **AudioMuse: similar tracks** — on any track (audio similarity)
- **AudioMuse: similar (sound + lyrics)** — on any track (lyrics+audio similarity)
- **AudioMuse: alchemy from this album** — on any album (seeds alchemy with all the album's tracks)

> **Material users — look under "More".** Material's context menu shows only the common actions (Play, Add to queue, Favourites…) at the top, then a **More** entry. The AudioMuse items are inside **More**, not on the first screen. So the path is: long-press (or **⋮**) → **More** → *AudioMuse: …*. (On the default web UI and iPeng they appear directly in the context menu.)

This gives you Lyrion's native filter / letter-jump for free — often the fastest path on any controller.

### Auto-extend

Two ways to keep the queue topped up automatically:

1. **Native Don't Stop The Music** *(recommended)* — Player Settings → Audio → **Don't Stop The Music** → pick **AudioMuse-AI: Similar to recent tracks** or **AudioMuse-AI: Sonic fingerprint**. LMS tops up the queue as it nears the end, exactly like MusicIP / SugarCube. Per-player.
2. **Plugin Dynamic Playlists** — start a mode from the **Dynamic Playlists** submenu. When the queue drops to ≤ 3 remaining, the plugin requests 10 more and appends them. (Starting a mode enables this automatically.)

If you've selected a native AudioMuse provider for a player, the plugin's own Dynamic Playlists auto-extend stands down for that player, so the queue isn't topped up twice.

## Per-controller behaviour

| Controller | Status |
|---|---|
| **Default Lyrion web UI** | Full feature set, including text-input items. |
| **Material Skin** | Full feature set. The settings status panel is theme-aware (works on light and dark). |
| **iPeng** | Full feature set. |
| **Squeezer (Android)** | Full feature set, including text-input items. |
| **SqueezePlay / Touch / Boom** | Built-in controllers; should work via the same Jive protocol. Untested. |

## How AudioMuse-AI features map to menu items

| AudioMuse feature | Plugin entry |
|---|---|
| Sonic similarity (audio) | Similar to current track / a song / an artist |
| SemGrove similarity (lyrics + audio) | Similar (sound + lyrics) — menu item + track context menu |
| Sonic fingerprint | Sonic Fingerprint |
| Instant playlist (CLAP) | Instant Playlist, Browse by Mood, Popular searches |
| Chat-driven playlist (LLM) | AI Chat Playlist |
| Lyrics search | Find tracks by lyric phrase |
| Song Alchemy | Song Alchemy |
| Alchemy radios (saved stations) | AudioMuse Radios |
| Song Paths | Find Path between two songs |
| Music Map | Open Music Map |
| Library coverage | Settings → Server Status panel |
| Analysis / clustering / cancel | Server Status / Admin |
| Auto-extend | Don't Stop The Music providers + Dynamic Playlists |
