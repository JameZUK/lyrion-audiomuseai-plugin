package Plugins::AudioMuseAI::API;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.audiomuseai');
my $prefs = preferences('plugin.audiomuseai');
my $cache = Slim::Utils::Cache->new('plugin_audiomuseai', 1, 1);

# Per-call timeouts (seconds). CLAP / clustering / fingerprint can take a while.
use constant {
	TIMEOUT_FAST  => 15,
	TIMEOUT_QUERY => 60,
	TIMEOUT_LONG  => 180,
};

sub _trim {
	my $s = shift;
	return '' unless defined $s;
	$s =~ s/\A\s+//;
	$s =~ s/\s+\z//;
	return $s;
}

sub _base {
	my $u = _trim($prefs->get('url') // '');
	$u = 'http://localhost:8000' unless length $u;
	$u = "http://$u" unless $u =~ m{^https?://}i;
	$u =~ s{/+$}{};
	return $u;
}

sub _headers {
	my $token = _trim($prefs->get('token') // '');
	# Reject anything with embedded CR/LF: it would smuggle headers.
	$token = '' if $token =~ /[\r\n]/;
	my @h = ('Accept' => 'application/json');
	push @h, 'Authorization' => "Bearer $token" if length $token;
	return @h;
}

# Decode a response body. Returns ($data, $err). Either is undef on success.
# Recognises both 200-with-{error:...} and JSON parse failures.
sub _decode {
	my ($body, $url) = @_;
	$body //= '';
	my $data = eval { from_json($body) };
	if ($@) {
		my $frag = substr($body, 0, 200);
		$log->warn("Bad JSON from $url: $@ // body fragment: $frag");
		return (undef, 'Invalid JSON from server');
	}
	if (ref($data) eq 'HASH' && defined $data->{error} && length $data->{error}) {
		return (undef, $data->{error});
	}
	return ($data, undef);
}

# Optional AudioMuse multi-server selection (v3.0+). Blank = the AudioMuse
# default server, which is the right answer for a single-Lyrion install.
# Only needed when Lyrion is NOT AudioMuse's default server: without it,
# the ids AudioMuse returns belong to the default server, not Lyrion.
sub _server {
	my $s = _trim($prefs->get('server_name') // '');
	$s = '' if $s =~ /[\r\n]/;
	return $s;
}

sub _withServer {
	my $path = shift;
	my $s = _server();
	return $path unless length $s;
	return $path . ($path =~ /\?/ ? '&' : '?') . 'server=' . uri_escape_utf8($s);
}

sub _get {
	my ($path, $cb_ok, $cb_err, $timeout, $cache_for) = @_;
	my $url = _base() . _withServer($path);
	$timeout ||= TIMEOUT_QUERY;

	if ($cache_for) {
		if (my $hit = $cache->get("get:$url")) {
			$log->debug("cache hit: $url");
			# Defensive copy — callers may mutate, and the cache holds
			# a single shared reference for the cache_for window.
			return $cb_ok->(_clone($hit));
		}
	}

	$log->debug("GET $url (timeout ${timeout}s)");

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $resp = shift;
			my ($data, $err) = _decode($resp->content, $url);
			if ($err) {
				return $cb_err->($err) if $cb_err;
				return;
			}
			$cache->set("get:$url", $data, $cache_for) if $cache_for;
			$cb_ok->($data) if $cb_ok;
		},
		sub {
			my (undef, $err) = @_;
			$err //= 'unknown HTTP error';
			$log->warn("HTTP error $url: $err");
			$cb_err->($err) if $cb_err;
		},
		{ timeout => $timeout },
	);
	$http->get($url, _headers());
}

sub _post {
	my ($path, $payload, $cb_ok, $cb_err, $timeout) = @_;
	my $url = _base() . $path;
	$timeout ||= TIMEOUT_QUERY;
	$log->debug("POST $url (timeout ${timeout}s)");

	$payload ||= {};
	if (ref($payload) eq 'HASH' && length(my $srv = _server())) {
		$payload = { %$payload, server => $srv };
	}
	my $body = eval { to_json($payload) };
	if ($@) {
		$log->warn("Failed to encode payload for $url: $@");
		$cb_err->('Failed to serialise request body') if $cb_err;
		return;
	}

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $resp = shift;
			my ($data, $err) = _decode($resp->content, $url);
			if ($err) {
				return $cb_err->($err) if $cb_err;
				return;
			}
			$cb_ok->($data) if $cb_ok;
		},
		sub {
			my (undef, $err) = @_;
			$err //= 'unknown HTTP error';
			$log->warn("HTTP error $url: $err");
			$cb_err->($err) if $cb_err;
		},
		{ timeout => $timeout },
	);
	$http->post($url, _headers(), 'Content-Type' => 'application/json', $body);
}

# Shallow-deep clone via JSON round-trip — safe because all our cached
# payloads are JSON-shaped (no blessed objects, no code refs).
sub _clone {
	my $data = shift;
	return $data unless ref $data;
	return eval { from_json(to_json($data)) } // $data;
}

# ---------- public API surface ----------

sub ping {
	my ($cb_ok, $cb_err) = @_;
	# Lightweight liveness probe — returns {"status":"ok"}. Falls back
	# to active_tasks for old AudioMuse builds that don't have /api/health.
	_get('/api/health', $cb_ok, sub {
		my $err = shift;
		# Fallback if /api/health doesn't exist (404). Distinguish from
		# auth/timeout errors so we don't mask real problems.
		if (defined $err && $err =~ /\b404\b/) {
			_get('/api/active_tasks', $cb_ok, $cb_err, TIMEOUT_FAST, 5);
		} else {
			$cb_err->($err) if $cb_err;
		}
	}, TIMEOUT_FAST, 5);
}

sub health {
	my ($cb_ok, $cb_err) = @_;
	_get('/api/health', $cb_ok, $cb_err, TIMEOUT_FAST);
}

sub dashboard_summary {
	my ($cb_ok, $cb_err) = @_;
	# 30s cache: library counts don't change minute-to-minute and the
	# settings page may poll every 10s while a task is running.
	_get('/api/dashboard/summary', $cb_ok, $cb_err, TIMEOUT_FAST, 30);
}

sub clap_top_queries {
	my ($cb_ok, $cb_err) = @_;
	# 5min cache: top-queries data is community-aggregated and slow-moving.
	_get('/api/clap/top_queries', $cb_ok, $cb_err, TIMEOUT_FAST, 300);
}

# LLM-driven playlist generation. The chat blueprint is mounted at
# /chat upstream, so the URL is /chat/api/chatPlaylist (NOT /api/...).
# Response shape:
#   { response: {
#       message:           '...AI processing log...',
#       original_request:  '<userInput>',
#       ai_provider_used:  'OPENAI'|'GEMINI'|'OLLAMA'|'MISTRAL'|'NONE',
#       ai_model_selected: '...',
#       executed_query:    '<SQL>',
#       query_results:     [ { item_id, title, artist }, ... ] | null
#   } }
# When ai_provider_used is NONE the server refuses with a message
# explaining no provider is configured — surfaced verbatim to the user.
sub chat_playlist {
	my ($user_input, $n, $cb_ok, $cb_err) = @_;
	# LLM round-trips can take 30s+. Use the long timeout. `n` (v3.5.2+)
	# sets the playlist length; older servers ignore it.
	my %body = (userInput => $user_input);
	$body{n} = int($n) if $n;
	_post('/chat/api/chatPlaylist', \%body, $cb_ok, $cb_err, TIMEOUT_LONG);
}

sub cancel_task {
	my ($task_id, $cb_ok, $cb_err) = @_;
	_post('/api/cancel/' . uri_escape_utf8($task_id), {},
		$cb_ok, $cb_err, TIMEOUT_FAST);
}

sub cancel_all_tasks {
	my ($prefix, $cb_ok, $cb_err) = @_;
	_post('/api/cancel_all/' . uri_escape_utf8($prefix), {},
		$cb_ok, $cb_err, TIMEOUT_FAST);
}

sub active_tasks {
	my ($cb_ok, $cb_err) = @_;
	# 5s cache so the top-menu status header and inline error-with-status
	# don't hammer the server when the user navigates quickly.
	_get('/api/active_tasks', $cb_ok, $cb_err, TIMEOUT_FAST, 5);
}

# Synchronous peek into the active_tasks cache. Returns undef if no
# fresh entry is available. Used by code paths that want to decorate
# UI without waiting for a network round-trip.
sub peek_active_tasks {
	return $cache->get('get:' . _base() . _withServer('/api/active_tasks'));
}

sub last_task {
	my ($cb_ok, $cb_err) = @_;
	_get('/api/last_task', $cb_ok, $cb_err, TIMEOUT_FAST);
}

sub task_status {
	my ($task_id, $cb_ok, $cb_err) = @_;
	_get('/api/status/' . uri_escape_utf8($task_id), $cb_ok, $cb_err, TIMEOUT_FAST);
}

sub similar_tracks {
	my ($item_id, $n, $cb_ok, $cb_err, $strict) = @_;
	$n ||= 20;
	my $path = sprintf('/api/similar_tracks?item_id=%s&n=%d&eliminate_duplicates=true',
		uri_escape_utf8($item_id), $n);
	# "Stricter similarity": also require similar mood features and stay
	# within the similarity radius (as AudioMuse Mixer does).
	$path .= '&mood_similarity=true&radius_similarity=true' if $strict;
	_get($path, $cb_ok, $cb_err, TIMEOUT_QUERY);
}

sub search_tracks {
	my ($artist, $cb_ok, $cb_err) = @_;
	my $path = '/api/search_tracks?artist=' . uri_escape_utf8($artist);
	# Cache search results for 60s — same artist often searched twice
	# during alchemy / find-path flows.
	_get($path, $cb_ok, $cb_err, TIMEOUT_QUERY, 60);
}

# Free-text track search (title / artist / album words). Bare array of
# { item_id, title, author, album }.
sub search_query {
	my ($query, $cb_ok, $cb_err) = @_;
	_get('/api/search_tracks?search_query=' . uri_escape_utf8($query) . '&end=20',
		$cb_ok, $cb_err, TIMEOUT_QUERY, 60);
}

sub sonic_fingerprint {
	my ($n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	_get("/api/sonic_fingerprint/generate?n=$n", $cb_ok, $cb_err, TIMEOUT_LONG);
}

sub find_path {
	my ($start_id, $end_id, $max_steps, $cb_ok, $cb_err, $space) = @_;
	$max_steps ||= 10;
	my $path = sprintf('/api/find_path?start_song_id=%s&end_song_id=%s&max_steps=%d',
		uri_escape_utf8($start_id), uri_escape_utf8($end_id), $max_steps);
	# path_space=lyrics walks the merged lyrics+audio (SemGrove) index.
	$path .= '&path_space=lyrics' if ($space // '') eq 'lyrics';
	_get($path, $cb_ok, $cb_err, TIMEOUT_LONG);
}

sub clap_search {
	my ($prompt, $n, $cb_ok, $cb_err, $steering) = @_;
	$n ||= 25;
	# Server param is `limit`, not `n`. Response is wrapped:
	# { query, count, results: [...] } — _queueResults / _extractTracks
	# in Plugin.pm unwraps the `results` key. $steering (v3.5.1+) is an
	# optional [ { term, weight, direction: more|less }, ... ] list of
	# DCLAP concepts (terms must come from /api/clap/concepts).
	my %body = (query => $prompt, limit => $n);
	$body{steering} = $steering if ref($steering) eq 'ARRAY' && @$steering;
	_post('/api/clap/search', \%body, $cb_ok, $cb_err, TIMEOUT_LONG);
}

# Build the alchemy payload. Items are passed as
# { items: [{ id, op: ADD|SUBTRACT, type: song|artist }, ... ], n, ... }.
# Plugin code uses song IDs only (alchemy_add / alchemy_sub lists are
# populated from the player's currently-playing track), so type defaults
# to 'song'. Response is wrapped: { results: [...], filtered_out: [...],
# centroid_2d: ... } — the unwrap happens in _extractTracks.
#
# An id may also be a typed reference "type:id" (v2.3+/v3.x): artist:<Lyrion
# contributor id or name>, playlist:<Lyrion playlist id>, anchor:<anchor id>,
# mood:<mood name>. Plain ids are songs.
sub alchemy_items {
	my ($add_ids, $sub_ids) = @_;
	my @items;
	for my $pair ([ADD => $add_ids], [SUBTRACT => $sub_ids]) {
		my ($op, $list) = @$pair;
		for my $id (@{ $list || [] }) {
			next unless defined $id && length $id;
			my ($type, $val) = ('song', "$id");
			if ($id =~ /\A(artist|playlist|anchor|mood|song):(.+)\z/s) {
				($type, $val) = ($1, $2);
			}
			push @items, { id => $val, op => $op, type => $type };
		}
	}
	return \@items;
}

sub alchemy {
	my ($add_ids, $sub_ids, $n, $cb_ok, $cb_err, $temperature) = @_;
	$n ||= 25;
	my $items = alchemy_items($add_ids, $sub_ids);
	my %body = (items => $items, n => $n);
	$body{temperature} = $temperature + 0 if defined $temperature;
	_post('/api/alchemy', \%body, $cb_ok, $cb_err, TIMEOUT_LONG);
}

# Pre-warm the CLAP text-search model so the first Instant Playlist
# isn't slow (the model otherwise loads on first query). Idempotent —
# also resets the server's 10-minute idle-eviction timer.
sub clap_warmup {
	my ($cb_ok, $cb_err) = @_;
	_post('/api/clap/warmup', {}, $cb_ok, $cb_err, TIMEOUT_FAST);
}

# Free-text lyrics search via /api/lyrics/search/text. Returns the same
# wrapped { query, count, results: [...] } shape as clap_search.
sub lyrics_search {
	my ($prompt, $n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	_post('/api/lyrics/search/text', { query => $prompt, limit => $n },
		$cb_ok, $cb_err, TIMEOUT_LONG);
}

sub start_analysis {
	my ($cb_ok, $cb_err) = @_;
	_post('/api/analysis/start', {}, $cb_ok, $cb_err, TIMEOUT_FAST);
}

sub start_clustering {
	my ($cb_ok, $cb_err) = @_;
	_post('/api/clustering/start', {}, $cb_ok, $cb_err, TIMEOUT_FAST);
}

# SemGrove: similarity by seed song over the MERGED lyrics+audio index —
# a different notion of "similar" than /api/similar_tracks (audio only).
# Response: { results: [ { item_id, title, author, similarity, is_seed }, ... ],
# count }. results[0] is the seed itself (is_seed=true) and must be filtered
# out before queueing. 404 if the seed lacks both lyrics + audio analysis.
sub sem_grove {
	my ($item_id, $n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	_post('/api/sem_grove/search', { item_id => "$item_id", limit => $n },
		$cb_ok, $cb_err, TIMEOUT_LONG);
}

# Saved "alchemy radios" (anchor + temperature + n_results, named). List is
# cheap and slow-moving — cache 30s. Response: { radios: [ { id, anchor_id,
# name, temperature, n_results, enabled }, ... ] }.
sub list_radios {
	my ($cb_ok, $cb_err) = @_;
	_get('/api/radios', $cb_ok, $cb_err, TIMEOUT_FAST, 30);
}

# Run every enabled radio — AudioMuse upserts one playlist per radio in the
# configured media server (Lyrion), reusing existing playlists by name.
# Generating can take a while. Response: { message, radios_enabled,
# playlists_created, failed: [...] }.
sub run_radios {
	my ($cb_ok, $cb_err) = @_;
	_post('/api/radios/run', {}, $cb_ok, $cb_err, TIMEOUT_LONG);
}

# ---------- v3.x additions ----------

# Which analysis models are enabled / how much of the library they cover.
# Drives which feature menus are shown (Album Creation needs musicnn + clap
# + lyrics). Response: { models: { musicnn|clap|lyrics|neural-fingerprint:
# { enabled, global: { count, percentage, total } } }, server_id }.
sub models {
	my ($cb_ok, $cb_err) = @_;
	_get('/api/models', $cb_ok, $cb_err, TIMEOUT_FAST, 300);
}

# Configured music servers (v3.0+): { default_id, servers: [ { server_id,
# name, server_type, is_default } ] }. Used to validate the server_name pref.
sub list_servers {
	my ($cb_ok, $cb_err) = @_;
	# Raw: no `server=` here — validating that value is the point.
	my $url = _base() . '/api/servers';
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my ($data, $err) = _decode(shift->content, $url);
			return $cb_err->($err) if $err && $cb_err;
			$cb_ok->($data) if $cb_ok && !$err;
		},
		sub { my (undef, $err) = @_; $cb_err->($err // 'unknown HTTP error') if $cb_err; },
		{ timeout => TIMEOUT_FAST },
	);
	$http->get($url, _headers());
}

sub version {
	my ($cb_ok, $cb_err) = @_;
	_get('/api/version', $cb_ok, $cb_err, TIMEOUT_FAST, 300);
}

# Album Creation (v3.6.2): a sequenced, CD-like album from one seed song or a
# few words. Response: { suggested_name, seed, tracks: [ { item_id, title, author, slot,
# role, ... } ], stats: {...} }. The seed song is part of the album.
sub album_creation {
	my ($seed_type, $seed, $cb_ok, $cb_err) = @_;
	my %body = (seed_type => $seed_type);
	if ($seed_type eq 'song') { $body{item_id} = "$seed"; }
	else                      { $body{query}   = "$seed"; }
	_post('/api/album_creation/generate', \%body, $cb_ok, $cb_err, TIMEOUT_LONG);
}

# Hyperbolic Explorer (v3.3+): similar | roots (more general / mainstream
# neighbourhood) | niche (more specific / deeper cuts) around a seed song.
# Response: { results: [ { item_id, title, author, ... } ], count, ... }.
sub hyperbolic_similar {
	my ($item_id, $mode, $n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	_post('/api/hyperbolic/similar',
		{ item_id => "$item_id", mode => ($mode || 'similar'), limit => $n },
		$cb_ok, $cb_err, TIMEOUT_LONG);
}

# Hyperbolic Path (v3.5): geodesic journey between two songs through their
# shared musical "ancestor". `length` counts both endpoints.
# Response: { results: [ { item_id, title, author, step, ... } ], ... }.
sub hyperbolic_journey {
	my ($start_id, $end_id, $length, $cb_ok, $cb_err) = @_;
	my %body = (start_item_id => "$start_id", end_item_id => "$end_id");
	$body{length} = int($length) if $length;
	_post('/api/hyperbolic/journey', \%body, $cb_ok, $cb_err, TIMEOUT_LONG);
}

# Sonic mood clusters: { <mood>: [ { index, n_songs, top_tags: [...] }, ... ] }.
sub mood_centroids {
	my ($cb_ok, $cb_err) = @_;
	_get('/api/mood_centroids', $cb_ok, $cb_err, TIMEOUT_FAST, 600);
}

# Songs nearest one mood centroid (similar_tracks in centroid mode).
sub similar_by_mood {
	my ($mood, $index, $n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	my $path = sprintf('/api/similar_tracks?mood=%s&centroid_index=%d&n=%d&eliminate_duplicates=true',
		uri_escape_utf8($mood), int($index // 0), $n);
	_get($path, $cb_ok, $cb_err, TIMEOUT_QUERY);
}

# Saved alchemy anchors: { anchors: [ { id, name }, ... ] }.
sub list_anchors {
	my ($cb_ok, $cb_err) = @_;
	_get('/api/anchors', $cb_ok, $cb_err, TIMEOUT_FAST, 30);
}

# Songs nearest a saved anchor (similar_tracks in anchor mode).
sub similar_by_anchor {
	my ($anchor_id, $n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	my $path = sprintf('/api/similar_tracks?anchor_id=%d&n=%d&eliminate_duplicates=true',
		int($anchor_id), $n);
	_get($path, $cb_ok, $cb_err, TIMEOUT_QUERY);
}

# Lyrics "themes": { axes: { AXIS_x: { description, labels: { KEY: desc } } } }.
sub lyrics_axes {
	my ($cb_ok, $cb_err) = @_;
	_get('/api/lyrics/axes', $cb_ok, $cb_err, TIMEOUT_FAST, 600);
}

# Lyrics search by axis label(s): targets = { AXIS_x => LABEL, ... }.
sub lyrics_search_axes {
	my ($targets, $n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	_post('/api/lyrics/search/axes', { targets => $targets, limit => $n },
		$cb_ok, $cb_err, TIMEOUT_LONG);
}

# DCLAP concept vocabulary for steering: { available, alpha_steps,
# categories: [ { category, label, terms: [ { term } ] } ] }.
sub clap_concepts {
	my ($cb_ok, $cb_err) = @_;
	_get('/api/clap/concepts', $cb_ok, $cb_err, TIMEOUT_FAST, 600);
}

1;
