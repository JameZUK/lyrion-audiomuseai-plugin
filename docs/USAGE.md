# Usage & menu reference

Everything under **My Music → AudioMuse-AI**, plus the two shortcuts that bypass the menu entirely. For settings see [SETTINGS.md](SETTINGS.md); for scripting see [CLI.md](CLI.md).

## The menu

Entries are ordered by how often you'll reach for them.

### One-tap actions

| Item | What it does | Needs |
|---|---|---|
| **Similar to current track** | Queues tracks sonically similar to whatever's playing now. | Clustering done. |
| **Sonic Fingerprint** | Replaces the queue with a personalised playlist built from your listening history. | A few hundred plays logged. |
| **Browse by Mood** | Seven preset CLAP prompts (Energetic, Calm, Sad, Happy, Aggressive, Acoustic, Party). Tap one to queue a matching playlist. | Analysis done (CLAP cache). |
| **Popular searches** | Community-popular search prompts pulled from your AudioMuse-AI server. Tap any phrase to queue. | Analysis done. |

### Browse & pick

Both of these start with a **"Search for an artist…"** box (on controllers that render a text field — Material, web UI, iPeng) followed by an alphabetical, paged artist list (the fallback for Squeezer).

| Item | Flow |
|---|---|
| **Similar to an artist (pick from library)…** | Search or pick an artist → queues tracks by the most similar artist. |
| **Similar to a song (pick artist, then track)…** | Search or pick an artist → pick one of their analyzed tracks → queues sonically similar tracks. |

### Sessions / advanced

| Item | What it does |
|---|---|
| **Dynamic Playlists** | Three modes: *Continuous similar to current track*, *Continuous from sonic fingerprint*, *Stop auto-extend*. Starting a mode keeps the queue refilled when it runs low. See [Auto-extend](#auto-extend) below. |
| **Song Alchemy** | Per-player ADD / SUBTRACT lists. Add the current track to ADD, add another to SUBTRACT, then **Generate** to get a sonic blend that leans toward the first set and away from the second. |

### Tools

| Item | What it does |
|---|---|
| **Save current queue as playlist (auto-named)** | Saves the current queue. The name comes from your [auto-name setting](SETTINGS.md#auto-name-strategies); on the web UI / Material you can type a custom name instead. |

### Text input (web UI / Material / iPeng)

These render but **can't be activated on Squeezer**, which doesn't draw Jive `input` fields. Use the [context menu](#context-menu) instead there.

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

The plugin registers info-providers for artists, tracks, and albums. **Browse normally** (My Music → Artists, type to filter, tap an artist) and the context menu — right-click (web UI), long-press (Material), 3-dot (iPeng) — includes:

- **AudioMuse: similar artists** — on any artist
- **AudioMuse: similar tracks** — on any track (in My Music, in the queue, anywhere)
- **AudioMuse: alchemy from this album** — on any album (seeds alchemy with all the album's tracks)

This gives you Lyrion's native filter / letter-jump for free, and is the **recommended path on Squeezer** (which can filter the standard browse but can't render text-input fields inside the plugin menu).

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
| **Squeezer (Android)** | Tap-only items work. Text-input items render but can't be activated (no Jive `input` field) — use the [context menu](#context-menu) for typed-search flows. |
| **SqueezePlay / Touch / Boom** | Built-in controllers; should work via the same Jive protocol. Untested. |

## How AudioMuse-AI features map to menu items

| AudioMuse feature | Plugin entry |
|---|---|
| Sonic similarity | Similar to current track / a song / an artist |
| Sonic fingerprint | Sonic Fingerprint |
| Instant playlist (CLAP) | Instant Playlist, Browse by Mood, Popular searches |
| Chat-driven playlist (LLM) | AI Chat Playlist |
| Lyrics search | Find tracks by lyric phrase |
| Song Alchemy | Song Alchemy |
| Song Paths | Find Path between two songs |
| Music Map | Open Music Map |
| Library coverage | Settings → Server Status panel |
| Analysis / clustering / cancel | Server Status / Admin |
| Auto-extend | Don't Stop The Music providers + Dynamic Playlists |
