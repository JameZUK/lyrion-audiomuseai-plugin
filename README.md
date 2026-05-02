# lyrion-audiomuseai-plugin

Lyrion Music Server plugin that adds an **AudioMuse-AI** entry under My Music with sonic similarity, sonic fingerprint, instant text-prompt playlists, song alchemy hooks, and DSTM-style auto-extend.

Backs onto a self-hosted [AudioMuse-AI](https://github.com/NeptuneHub/AudioMuse-AI) instance.

## Install via Lyrion's repository system

1. In Lyrion, go to **Settings → Plugins → Additional Repositories**.
2. Paste this URL into the "Add Repository URL" field:

   ```
   https://raw.githubusercontent.com/JameZUK/lyrion-audiomuseai-plugin/main/extensions.xml
   ```

3. Apply, then scroll down — **AudioMuse-AI** appears in the third-party plugin list.
4. Tick to install, click **Apply**, restart Lyrion when prompted.

## Configure

After install, open **Settings → Plugins → AudioMuse-AI** and set:

- **Server URL** — your AudioMuse-AI Flask container, e.g. `http://localhost:8000`
- **API token** — generate one in the AudioMuse web UI (Administration). Leave blank if `AUTH_ENABLED=false`.
- Click **Test connection** — should report ✓.

The new menu lives under **My Music → AudioMuse-AI** on every controller (web UI, Material Skin, iPeng, squeezelite-controller, etc.).

## Manual install (without the repo URL)

Drop the `AudioMuseAI/` directory into Lyrion's plugin folder and restart:

```bash
LYRION_PLUGINS=/var/lib/lyrion/Plugins   # adjust to your install
sudo cp -r AudioMuseAI "$LYRION_PLUGINS/"
sudo systemctl restart lyrion-music-server
```

See [`AudioMuseAI/README.md`](AudioMuseAI/README.md) for plugin internals, feature list, and known limitations.

## License

MIT — see [LICENSE](LICENSE).
