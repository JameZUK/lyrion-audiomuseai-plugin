#!/usr/bin/env python3
"""End-to-end test of the AudioMuse-AI Lyrion plugin on a REAL player.

Drives one player over Lyrion's JSON-RPC, saves/restores its state (queue,
playing position, power, volume, Don't Stop The Music provider, dynamic mode), mutes it, and for
every plugin function checks: it responds, the queue changes as expected
(load / append), and the resulting queue has no repeated track ids or songs.
Also runs eight long auto-extend sessions (~150 tracks each: four menu
Dynamic Playlists modes + four native Don't Stop The Music providers).

NOT part of run-all.sh: it plays music (muted) on a real player, takes
~20 minutes, and needs the plugin installed on the target Lyrion.

Usage:
    LYRION_URL=http://lyrion:9000 tests/06-lms-e2e.py <player-mac> [test-prefix ...]

Library-specific seeds (defaults are the maintainer's library) can be set via
env: E2E_SEED (track id), E2E_SEED2 / E2E_SEED3 (two other DISTINCT songs),
E2E_ARTIST_ID + E2E_ARTIST (a library artist), E2E_TYPED_ARTIST,
E2E_PATH_ARTIST (destination artist for Find Path), E2E_GENRE (a big genre), E2E_STALE_ID (a track
AudioMuse knows under an old id; renumbered-track tests skip if unset).
Admin actions (analysis / clustering / cancel / rebuild radios) are never run.
"""
import json, os, re, sys, time, urllib.request
from collections import Counter

LMS = os.environ.get('LYRION_URL', 'http://localhost:9000').rstrip('/') + '/jsonrpc.js'
if len(sys.argv) < 2:
    sys.exit(__doc__)
P = sys.argv[1]
ONLY = set(sys.argv[2:])
ENV = os.environ.get

def rpc(cmd, player=P, timeout=300):
    body = json.dumps({'id': 1, 'method': 'slim.request', 'params': [player, cmd]}).encode()
    r = urllib.request.Request(LMS, data=body, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(r, timeout=timeout) as f:
        return json.load(f).get('result', {})

def am(*args, **params):
    cmd = ['audiomuseai'] + list(args) + [f'{k}:{v}' for k, v in params.items()]
    return rpc(cmd)

def texts(res):
    return [i.get('text', '') for i in res.get('item_loop', [])]

def queue():
    res = rpc(['status', '0', '2000', 'tags:atl'])
    return res.get('playlist_loop', []), res

def norm(t, a):
    t = re.sub(r'\s*[\(\[][^\)\]]*[\)\]]', '', (t or '').lower())
    t = re.sub(r'\s+-\s+.*\b(remaster\w*|live|version|edit|mix|mono|stereo|demo|acoustic)\b.*$', '', t)
    return re.sub(r'\W+', '', a.lower()) + '|' + re.sub(r'\W+', '', t)

def dupes(q):
    ids = Counter(str(x['id']) for x in q)
    # Punctuation-only titles ("?", ".") normalise to nothing: key by id instead.
    keys = Counter((norm(x.get('title'), x.get('artist', '')) if re.sub(r'\W+', '', x.get('title') or '') else 'id:' + str(x['id'])) for x in q)
    return ([k for k, v in ids.items() if v > 1], [k for k, v in keys.items() if v > 1])

results = []
def record(name, ok, detail=''):
    results.append((name, ok, detail))
    print(('PASS  ' if ok else 'FAIL  ') + name + ('  -- ' + detail if detail else ''), flush=True)

def check_queue(name, before_ids, mode, msg, min_tracks=5):
    q, _ = queue()
    ids = [str(x['id']) for x in q]
    di, dk = dupes(q)
    if mode == 'load':
        changed = ids != before_ids
        added = len(ids)
    else:
        changed = ids[:len(before_ids)] == before_ids and len(ids) > len(before_ids)
        added = len(ids) - len(before_ids)
    ok = changed and added >= min_tracks and not di and not dk
    detail = f'{mode}: +{added} (queue {len(ids)}) dupIds={len(di)} dupSongs={len(dk)} msg={msg[:90]!r}'
    if dk:
        detail += ' e.g. ' + ', '.join(dk[:3])
    record(name, ok, detail)
    return q

def run(_label, qmode, *args, min_tracks=5, **params):
    name = _label
    if ONLY and name.split()[0] not in ONLY:
        return None
    before = [str(x['id']) for x in queue()[0]]
    t0 = time.time()
    try:
        res = am(*args, **params)
    except Exception as e:
        record(name, False, f'exception {e}')
        return None
    msg = ' | '.join(texts(res))
    settle()
    q = check_queue(name, before, qmode, f'{msg} ({time.time()-t0:.1f}s)', min_tracks)
    return q

def settle(timeout=30):
    # LMS adds track lists asynchronously: wait until the queue stops growing.
    last, stable, t0 = -1, 0, time.time()
    while time.time() - t0 < timeout:
        n = len(queue()[0])
        stable = stable + 1 if n == last else 0
        if stable >= 3:
            return n
        last = n
        time.sleep(1)
    return last

def seed(track_id):
    rpc(['playlistcontrol', 'cmd:load', f'track_id:{track_id}'])
    time.sleep(2)

def menu(_label, *args, expect=1, **params):
    name = _label
    if ONLY and name.split()[0] not in ONLY:
        return []
    try:
        res = am(*args, **params)
    except Exception as e:
        record(name, False, f'exception {e}')
        return []
    items = res.get('item_loop', [])
    record(name, len(items) >= expect, f'{len(items)} items: ' + ' | '.join(texts(res))[:160])
    return items

def go_params(item):
    return ((item.get('actions') or {}).get('go') or {}).get('params') or {}

def extend_run(label, start_cmd, provider=None, target=150, max_steps=80):
    """Skip through the queue, letting auto-extend top it up, and check the
    accumulated queue never repeats a track or a song."""
    if ONLY and label.split()[0] not in ONLY:
        return
    if provider:
        rpc(['playlistcontrol', 'cmd:load', f'track_id:{SEED},{SEED2},{SEED3}']); time.sleep(2)
    else:
        seed(SEED)
    if provider:
        rpc(['playerpref', 'plugin.dontstopthemusic:provider', provider])
        rpc(['playerpref', 'plugin.dontstopthemusic:provider', '?'])
    else:
        am(*start_cmd)
        settle()
    steps = 0
    stalls = 0
    while len(queue()[0]) < target and steps < max_steps:
        n = len(queue()[0])
        # Jump to the last-but-one track: <=3 remaining -> extend fires.
        rpc(['playlist', 'index', str(max(n - 2, 0))])
        time.sleep(2)
        settle(timeout=40)
        if len(queue()[0]) == n:
            stalls += 1
            if stalls >= 4:
                break
        else:
            stalls = 0
        steps += 1
    q = queue()[0]
    di, dk = dupes(q)
    # Artist spacing (mix filter, default 10): count same-artist repeats
    # within 10 tracks among the auto-added part of the queue.
    added = q[3:]
    close = sum(1 for i, x in enumerate(added)
                if any(y.get('artist') == x.get('artist') for y in added[max(0, i - 10):i]))
    ok = len(q) >= target and not di and not dk and close <= len(added) // 10
    record(label, ok, f'queue grew to {len(q)} in {steps} skips; dupIds={len(di)} dupSongs={len(dk)}; '
           f'same artist within 10: {close}'
           + (' e.g. ' + ', '.join(dk[:3]) if dk else ''))
    if provider:
        rpc(['playerpref', 'plugin.dontstopthemusic:provider', '0'])
    else:
        am('dyn_stop')

SEED   = ENV('E2E_SEED', '2112964')       # Frank Turner - Recovery
SEED2  = ENV('E2E_SEED2', '2152710')
SEED3  = ENV('E2E_SEED3', '2203589')
ARTIST_ID = ENV('E2E_ARTIST_ID', '184394')
ARTIST = ENV('E2E_ARTIST', 'Frank Turner')
TYPED_ARTIST = ENV('E2E_TYPED_ARTIST', 'Foo Fighters')
PATH_ARTIST = ENV('E2E_PATH_ARTIST', 'Biffy Clyro')
STALE_ID = ENV('E2E_STALE_ID', '')

if __name__ == '__main__':
    state = rpc(['status', '-', '1', 'tags:'])
    was_playing = state.get('mode') == 'play'
    play_index = state.get('playlist_cur_index')
    play_time = state.get('time')
    vol = rpc(['mixer', 'volume', '?']).get('_volume')
    power = state.get('power')
    dstm_prov = rpc(['playerpref', 'plugin.dontstopthemusic:provider', '?']).get('_p2')
    glob_dstm = rpc(['pref', 'plugin.audiomuseai:dstm_enabled', '?'], player='').get('_p2')
    dyn_mode = rpc(['playerpref', 'plugin.audiomuseai:dstm_active', '?']).get('_p2')
    am('dyn_stop')
    print(f'saved state: power={power} volume={vol} dstm_provider={dstm_prov!r} dstm_enabled={glob_dstm!r}')
    rpc(['playlist', 'save', '__amtest_backup'])
    rpc(['mixer', 'volume', '0'])
    rpc(['playerpref', 'plugin.dontstopthemusic:provider', '0'])
    # Wake the player and let it start streaming before timing-sensitive tests.
    rpc(['power', '1']); seed(SEED); time.sleep(8)

    try:
        # ---- menus ----
        menu('menu top', 'menu', expect=15)
        menu('menu_mood', 'menu_mood', expect=8)
        menu('menu_dynamic', 'menu_dynamic', expect=5)
        menu('menu_explore', 'menu_explore', expect=3)
        menu('menu_findpath', 'menu_findpath', expect=3)
        menu('menu_alchemy', 'menu_alchemy', expect=9)
        menu('menu_status', 'menu_status', expect=5)
        menu('menu_top_queries', 'menu_top_queries', expect=1)
        concepts = menu('menu_concepts', 'menu_concepts', expect=2)
        cat = next((go_params(i).get('category') for i in concepts if go_params(i).get('category')), None)
        if cat:
            menu('menu_concepts category', 'menu_concepts', category=cat, expect=3)
        st = menu('status_active', 'status_active', expect=1)
        if st: record('status_active detects a running task (if any)',
               any(re.search(r'RUNNING|no task', i.get('text', '')) for i in st), ' | '.join(i.get('text','') for i in st)[:120])
        menu('status_last', 'status_last', expect=1)
        menu('browse_artists', 'browse_artists', target='similar_artist', start='0', expect=10)
        fa = menu('filter_artists', 'filter_artists', query=ARTIST, target='similar_artist', expect=2)
        ls = am('library_summary')
        record('library_summary top_moods non-zero', bool(re.search(r'=[1-9]', ls.get('top_moods', ''))), ls.get('top_moods', ''))
        ss = am('server_status')
        record('server_status reachable', ss.get('reachable') == 1, f"status={ss.get('status')}")

        # ---- load-style generators ----
        seed(SEED)
        run('similar_now (append)', 'append', 'similar_now')
        run('similar_now again (append, no repeats)', 'append', 'similar_now')
        seed(SEED); run('semgrove_now', 'load', 'semgrove_now')
        run('sonic_fp', 'load', 'sonic_fp')
        seed(SEED); run('album_now', 'load', 'album_now')
        for mode in ('similar', 'roots', 'niche'):
            seed(SEED); run(f'explore_now {mode}', 'load', 'explore_now', mode=mode)
        run('mood preset', 'load', 'mood', prompt='calm, ambient, peaceful, relaxing', mood_label='Calm')
        run('instant', 'load', 'instant', prompt='upbeat summer songs')
        run('instant steering', 'load', 'instant', prompt='jazz | +piano x3')
        r = am('instant', prompt='jazz | +notaconcept')
        record('instant steering unknown term rejected', 'Unknown steering' in ' '.join(texts(r)), ' '.join(texts(r))[:100])
        run('chat_playlist', 'load', 'chat_playlist', prompt='upbeat 80s synth pop')
        run('lyrics_search', 'load', 'lyrics_search', prompt='heartbreak in the rain')
        run('album_text', 'load', 'album_text', prompt='jazz piano female voice')

        moods = menu('menu_sonic_moods', 'menu_sonic_moods', expect=3)
        if moods:
            clusters = menu('menu_sonic_mood', 'menu_sonic_mood', **go_params(moods[0]), expect=1)
            if clusters:
                run('sonic_mood', 'load', 'sonic_mood', **go_params(clusters[0]))
        axes = menu('menu_lyric_themes', 'menu_lyric_themes', expect=3)
        if axes:
            labels = menu('menu_lyric_themes axis', 'menu_lyric_themes', **go_params(axes[0]), expect=2)
            if labels:
                run('lyric_theme', 'load', 'lyric_theme', **go_params(labels[0]))
        radios = menu('menu_radios', 'menu_radios', expect=1)
        play = [i for i in radios if (i.get('actions') or {}).get('go', {}).get('cmd', [None, None])[1] == 'anchor_play']
        if play:
            run('anchor_play (radio)', 'load', 'anchor_play', **go_params(play[0]))

        # ---- track / artist / album context ----
        seed(SEED2)   # unrelated current song so appends are visible
        run('similar_track (append)', 'append', 'similar_track', track_id=SEED)
        run('album_track', 'load', 'album_track', track_id=SEED)
        run('explore_track niche', 'load', 'explore_track', track_id=SEED, mode='niche')
        run('similar_artist by id (append)', 'append', 'similar_artist', artist=ARTIST, artist_id=ARTIST_ID)
        run('similar_artist typed (append)', 'append', 'similar_artist', artist=TYPED_ARTIST)
        pick = menu('similar_song_search', 'similar_song_search', artist=ARTIST, artist_id=ARTIST_ID, expect=5)
        if pick:
            run('similar_track from pick (append)', 'append', 'similar_track', **go_params(pick[0]))
        alb = rpc(['albums', '0', '1', f'artist_id:{ARTIST_ID}'], player='').get('albums_loop', [{}])[0].get('id')
        if alb:
            run('alchemy_album', 'load', 'alchemy_album', album_id=alb)

        # ---- a track Lyrion renumbered (AudioMuse doesn't know its id) ----
        if STALE_ID:
            seed(STALE_ID)
            run('similar_now on renumbered track (append)', 'append', 'similar_now')
            seed(STALE_ID); run('semgrove_now on renumbered track', 'load', 'semgrove_now')

        # ---- alchemy builder ----
        seed(SEED)
        am('alchemy_reset')
        menu('alchemy_add_now', 'alchemy_add_now')
        menu('alchemy_add_artist', 'alchemy_add_artist')
        seed(SEED2); menu('alchemy_sub_artist', 'alchemy_sub_artist')
        pls = menu('alchemy_pick playlist', 'alchemy_pick', kind='playlist', expect=1)
        if pls:
            menu('alchemy_add_ref playlist', 'alchemy_add_ref', **go_params(pls[0]))
        anc = menu('alchemy_pick anchor', 'alchemy_pick', kind='anchor', expect=1)
        menu('alchemy_show', 'alchemy_show', expect=4)
        run('alchemy_generate', 'load', 'alchemy_generate')
        am('alchemy_reset')

        # ---- find path, 3 methods ----
        for method in ('sonic', 'lyrics', 'hyperbolic'):
            seed(SEED)
            picks = menu(f'findpath_search {method}', 'findpath_search', artist=PATH_ARTIST, method=method, expect=3)
            if picks:
                run(f'findpath_to {method}', 'load', 'findpath_to', **go_params(picks[0]))

        # ---- auto-extend (the repeat-songs bug) ----
        rpc(['playlist', 'repeat', '0']); rpc(['playlist', 'shuffle', '0'])
        extend_run('dyn_similar long run', ['dyn_similar'])
        extend_run('dyn_fingerprint long run', ['dyn_fingerprint'])
        extend_run('dyn_semgrove long run', ['dyn_semgrove'])
        extend_run('dyn_album long run', ['dyn_album'])
        extend_run('dyn_hyperbolic long run', ['dyn_hyperbolic'])
        for prov in ('SIMILAR', 'ALBUM', 'FINGERPRINT', 'SEMGROVE', 'HYPERBOLIC'):
            extend_run(f'native_dstm {prov} long run', None, provider=f'PLUGIN_AUDIOMUSEAI_DSTM_{prov}')

        # ---- 0.7.0: mixes from artist / album / genre / track ----
        alb = rpc(['albums', '0', '1', f'artist_id:{ARTIST_ID}'], player='').get('albums_loop', [{}])[0].get('id')
        GENRE = ENV('E2E_GENRE', 'Rock')
        gen = next((g.get('id') for g in rpc(['genres', '0', '200', f'search:{GENRE}'], player='').get('genres_loop', [])
                    if (g.get('genre') or '').lower() == GENRE.lower()), None)
        run('mix artist', 'load', 'mix', artist_id=ARTIST_ID, count=20)
        q = queue()[0]
        record('mix artist: includes the seed artist', any(ARTIST.lower() in (x.get('artist') or '').lower() for x in q[:1]),
               (q[0].get('artist') if q else '') or '')
        if alb:
            run('mix album', 'load', 'mix', album_id=alb, count=20)
        if gen:
            run('mix genre', 'load', 'mix', genre_id=gen, count=20)
        run('mix track', 'load', 'mix', track_id=SEED, count=15)
        q = queue()[0]
        record('mix track: starts with the seed track', bool(q) and str(q[0]['id']) == SEED, str(q[0]['id']) if q else '')

        # ---- 0.7.0: audiomuse:// favourites URL ----
        if not ONLY or 'audiomuse_url' in ONLY:
            before = [str(x['id']) for x in queue()[0]]
            rpc(['playlist', 'play', f'audiomuse://?artist={ARTIST.replace(" ", "%20")}&count=15'])
            settle(timeout=60)
            q = queue()[0]; di, dk = dupes(q)
            ok = [str(x['id']) for x in q] != before and len(q) >= 10 and not di and not dk
            record('audiomuse_url plays a mix', ok, f'queue {len(q)} dupIds={len(di)} dupSongs={len(dk)}')

        # ---- 0.7.0: Don't Stop The Music only mode hides the menus ----
        if not ONLY or 'ui_mode' in ONLY:
            def has_menu():
                return any(i.get('id') == 'pluginAudioMuseAI'
                           for i in rpc(['menu', '0', '500', 'direct:1']).get('item_loop', []))
            orig = rpc(['pref', 'plugin.audiomuseai:ui_mode', '?'], player='').get('_p2') or 'full'
            rpc(['pref', 'plugin.audiomuseai:ui_mode', 'dstm'], player=''); time.sleep(1)
            hidden = not has_menu()
            rpc(['pref', 'plugin.audiomuseai:ui_mode', 'full'], player=''); time.sleep(1)
            back = has_menu()
            rpc(['pref', 'plugin.audiomuseai:ui_mode', orig], player='')
            record('ui_mode dstm hides the My Music entry, full restores it', hidden and back,
                   f'hidden={hidden} restored={back}')

        # ---- save playlist ----
        r = am('save_playlist', name='__amtest_save')
        record('save_playlist', 'saved' in ' '.join(texts(r)).lower(), ' '.join(texts(r))[:100])
    finally:
        rpc(['playlist', 'clear'])
        rpc(['playlist', 'resume', '__amtest_backup', 'noplay:1'])
        for p in rpc(['playlists', '0', '1000'], player='').get('playlists_loop', []):
            if p.get('playlist') in ('__amtest_backup', '__amtest_save'):
                rpc(['playlists', 'delete', f"playlist_id:{p['id']}"], player='')
        rpc(['mixer', 'volume', str(vol)])
        rpc(['playerpref', 'plugin.dontstopthemusic:provider', dstm_prov if dstm_prov else '0'])
        if power in (0, '0'):
            rpc(['power', '0'])
        elif was_playing:
            # Someone was listening: put them back where they were.
            if play_index is not None:
                rpc(['playlist', 'index', str(play_index)])
            if play_time:
                rpc(['time', str(play_time)])
            rpc(['play'])
        if dyn_mode:
            rpc(['playerpref', 'plugin.audiomuseai:dstm_active', dyn_mode])
        print(f'restored player state (dynamic mode {dyn_mode!r})')

    fails = [r for r in results if not r[1]]
    print(f'\n==== {len(results) - len(fails)} passed, {len(fails)} failed ====')
    for f in fails:
        print('FAIL', f[0], f[2])
    sys.exit(1 if fails else 0)
