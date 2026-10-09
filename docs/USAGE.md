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
| **Create an album around current track** | AudioMuse *Album Creation* (v3.6.2): a sequenced, CD-like album (about 12 tracks, opener to closer) built around the playing song using MusiCNN + DCLAP + lyrics together. Replaces the queue; optionally auto-saved under AudioMuse's suggested album name. | MusiCNN, DCLAP and lyrics analysis all enabled and run. |
| **Explore around current track** | The *hyperbolic* music map (v3.3+): **Close neighbours**, **Roots** (broader, more foundational sound — toward the centre of the map) or **Niche** (deeper, more specific cuts — toward the edge). | An analysis run on v3.3+ (builds the hyperbolic index). |
| **Browse by Mood** | Seven preset CLAP prompts (Energetic, Calm, Sad, Happy, Aggressive, Acoustic, Party), plus **Sonic moods** — AudioMuse's own analysed mood clusters, each mood split into flavours labelled by their top tags (e.g. *Happy: indie, pop, rock*) — and the **Steering concepts** reference list. | Analysis done (CLAP cache). |
| **Lyric themes** | Tap-only lyrics search: pick an axis (Setting, Social dynamic, Emotional valence, Narrative temporality, Thematic weight) then a label (Urban, Wilderness, Melancholic...). | Lyrics analysis. |
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
| **Dynamic Playlists** | Four modes: *Continuous similar to current track*, *Continuous: lyrics + sound (SemGrove)*, *Continuous: mix by album (broader)*, *Continuous from sonic fingerprint* — plus *Stop auto-extend*. Starting a mode keeps the queue refilled when it runs low. See [Auto-extend](#auto-extend) below. |
| **Song Alchemy** | Per-player ADD / SUBTRACT lists. Add the current **track** or the current **artist**, a **Lyrion playlist**, or a saved **anchor**; subtract tracks or artists; then **Generate** a sonic blend that leans toward the first set and away from the second. **Show** lists what's in each set. |
| **Alchemy radios and anchors** | Your saved radios and anchors from the AudioMuse-AI web UI. Tap one to **play it now** (the songs nearest its anchor, radio size honoured). **Run all radios** asks AudioMuse to (re)build one Lyrion playlist per enabled radio. |

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
| **Create an album from a description** | Type a few words (*"jazz piano female voice"*) — AudioMuse Album Creation builds a sequenced album from them. |
| **Find a path between two songs** | Three kinds, each starting from the current track: a **sonic** path (audio similarity), a **lyrics + sound** path (SemGrove index — both songs need lyrics analysis), or a **hyperbolic journey** that dips through the two songs' shared musical "ancestor" before climbing to the destination. Type an artist, pick the destination song. |

### Concept steering

AudioMuse v3.5.1+ lets you push an Instant Playlist toward (or away from) specific musical concepts. Put the concepts after a `|`, comma-separated:

```
jazz with viola | +viola x3, -drums, female vocals
```

- `+term` (or just `term`) = more of it; `-term` = less of it.
- `xN` or `*N` = weight; AudioMuse snaps it to 1, 2, 3, 5 or 10 (default 3). Higher sharpens a concept already in your words; 10 is the strongest.
- Only terms from AudioMuse's validated vocabulary work — browse them under **Browse by Mood → Steering concepts**. An unknown term gets a clear message instead of a playlist.

### Status / link-out

| Item | What it does |
|---|---|
| **Server Status / Admin** | Show active task, show last task, trigger analysis, trigger clustering, **cancel running task**. "Busy / unavailable" errors elsewhere include live status inline. |
| **Open Music Map** | Opens the AudioMuse-AI web UI on controllers that honour Jive `weblink` (Material, web UI, iPeng); shows the URL as text otherwise. |

## Two shortcuts that skip the menu

### Context menu

The plugin registers info-providers for artists, tracks, and albums. **Browse normally** (My Music → Artists, type to filter, tap an artist) and open the item's context menu — right-click (web UI), long-press or the **⋮** icon (Material), 3-dot (iPeng). It includes:

- **AudioMuse: music like this artist** — on any artist
- **AudioMuse: similar tracks** — on any track (audio similarity)
- **AudioMuse: similar (sound + lyrics)** — on any track (lyrics+audio similarity)
- **AudioMuse: create an album around this track** — on any track (Album Creation)
- **AudioMuse: niche deep cuts like this track** — on any track (hyperbolic *niche* explore)
- **AudioMuse: alchemy from this album** — on any album (seeds alchemy with all the album's tracks)

> **Material users — look under "More".** Material's context menu shows only the common actions (Play, Add to queue, Favourites…) at the top, then a **More** entry. The AudioMuse items are inside **More**, not on the first screen. So the path is: long-press (or **⋮**) → **More** → *AudioMuse: …*. (On the default web UI and iPeng they appear directly in the context menu.)

This gives you Lyrion's native filter / letter-jump for free — often the fastest path on any controller.

### Auto-extend

Two ways to keep the queue topped up automatically:

1. **Native Don't Stop The Music** *(recommended)* — Player Settings → Audio → **Don't Stop The Music** → pick one of **AudioMuse-AI: Similar to recent tracks**, **Lyrics + sound mix (SemGrove)**, **Mix by recent album (broader)** or **Sonic fingerprint**. LMS tops up the queue as it nears the end, exactly like MusicIP / SugarCube. Per-player. (With only one track in the queue, Lyrion itself waits until that track is half played before topping up.)
2. **Plugin Dynamic Playlists** — start a mode from the **Dynamic Playlists** submenu. When the queue drops to ≤ 3 remaining, the plugin adds 10 more. (Starting a mode enables this automatically.)

If you've selected a native AudioMuse provider for a player, the plugin's own Dynamic Playlists auto-extend stands down for that player, so the queue isn't topped up twice.

#### No repeats

AudioMuse answers every request on its own, so naively chaining "similar to the last track" goes round in circles — the same few dozen songs come back again and again (and Sonic Fingerprint returns the identical list every time). Since v0.6.0 every path that **adds** to a queue — both auto-extend styles, *Similar to current track*, *Similar to an artist*, track-menu *similar tracks* — only adds songs that are:

- not already anywhere in the player's queue,
- not among the last 1000 songs that player actually played (kept in memory; cleared when Lyrion restarts), and
- not another copy of a song already there — the same title by the same (primary) artist on a different album, as a single, *(Live)*, *(Remastered)*, *- 2011 Remaster*, etc.

It asks AudioMuse for extra candidates so a full batch survives the filtering, and when one seed is exhausted it falls back to a blend of the last few queued tracks, then an earlier seed — so a long session keeps drifting to new music instead of stopping. Playlists that **replace** the queue (moods, instant, album creation...) are de-duplicated within themselves the same way.

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
| Album Creation (v3.6.2) | Create an album around current track / from a description; track context menu |
| Hyperbolic Explorer (v3.3) | Explore around current track (neighbours / roots / niche); track context menu |
| Hyperbolic Path (v3.5) | Find a path → Hyperbolic journey |
| Mood centroids | Browse by Mood → Sonic moods |
| Lyrics axes | Lyric themes |
| DCLAP concept weights (v3.5.1) | Instant Playlist `|` steering syntax; Steering concepts list |
| Alchemy anchors | Alchemy radios and anchors (play now); Song Alchemy → ADD a saved anchor |
| SemGrove similarity (lyrics + audio) | Similar (sound + lyrics) — menu item + track context menu |
| Sonic fingerprint | Sonic Fingerprint |
| Instant playlist (CLAP) | Instant Playlist, Browse by Mood, Popular searches |
| Chat-driven playlist (LLM) | AI Chat Playlist |
| Lyrics search | Find tracks by lyric phrase |
| Song Alchemy | Song Alchemy |
| Alchemy radios (saved stations) | Alchemy radios and anchors |
| Song Paths (audio / lyrics) | Find a path → Sonic / Lyrics + sound |
| Music Map | Open Music Map |
| Library coverage | Settings → Server Status panel |
| Analysis / clustering / cancel | Server Status / Admin |
| Auto-extend | Don't Stop The Music providers + Dynamic Playlists |
