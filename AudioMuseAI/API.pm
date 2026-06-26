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

sub _get {
	my ($path, $cb_ok, $cb_err, $timeout, $cache_for) = @_;
	my $url = _base() . $path;
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

	my $body = eval { to_json($payload || {}) };
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
	my ($user_input, $cb_ok, $cb_err) = @_;
	# LLM round-trips can take 30s+. Use the long timeout.
	_post('/chat/api/chatPlaylist', { userInput => $user_input },
		$cb_ok, $cb_err, TIMEOUT_LONG);
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
	return $cache->get('get:' . _base() . '/api/active_tasks');
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
	my ($item_id, $n, $cb_ok, $cb_err) = @_;
	$n ||= 20;
	my $path = sprintf('/api/similar_tracks?item_id=%s&n=%d&eliminate_duplicates=true',
		uri_escape_utf8($item_id), $n);
	_get($path, $cb_ok, $cb_err, TIMEOUT_QUERY);
}

sub similar_artists {
	my ($artist, $n, $cb_ok, $cb_err) = @_;
	$n ||= 10;
	my $path = sprintf('/api/similar_artists?artist=%s&n=%d',
		uri_escape_utf8($artist), $n);
	_get($path, $cb_ok, $cb_err, TIMEOUT_QUERY);
}

sub search_tracks {
	my ($artist, $cb_ok, $cb_err) = @_;
	my $path = '/api/search_tracks?artist=' . uri_escape_utf8($artist);
	# Cache search results for 60s — same artist often searched twice
	# during alchemy / find-path flows.
	_get($path, $cb_ok, $cb_err, TIMEOUT_QUERY, 60);
}

sub sonic_fingerprint {
	my ($n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	_get("/api/sonic_fingerprint/generate?n=$n", $cb_ok, $cb_err, TIMEOUT_LONG);
}

sub find_path {
	my ($start_id, $end_id, $max_steps, $cb_ok, $cb_err) = @_;
	$max_steps ||= 10;
	my $path = sprintf('/api/find_path?start_song_id=%s&end_song_id=%s&max_steps=%d',
		uri_escape_utf8($start_id), uri_escape_utf8($end_id), $max_steps);
	_get($path, $cb_ok, $cb_err, TIMEOUT_LONG);
}

sub clap_search {
	my ($prompt, $n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	# Server param is `limit`, not `n`. Response is wrapped:
	# { query, count, results: [...] } — _queueResults / _extractTracks
	# in Plugin.pm unwraps the `results` key.
	_post('/api/clap/search', { query => $prompt, limit => $n },
		$cb_ok, $cb_err, TIMEOUT_LONG);
}

# Build the alchemy payload. Items are passed as
# { items: [{ id, op: ADD|SUBTRACT, type: song|artist }, ... ], n, ... }.
# Plugin code uses song IDs only (alchemy_add / alchemy_sub lists are
# populated from the player's currently-playing track), so type defaults
# to 'song'. Response is wrapped: { results: [...], filtered_out: [...],
# centroid_2d: ... } — the unwrap happens in _extractTracks.
sub alchemy {
	my ($add_ids, $sub_ids, $n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	my @items;
	for my $id (@{ $add_ids || [] }) {
		next unless defined $id && length $id;
		push @items, { id => "$id", op => 'ADD', type => 'song' };
	}
	for my $id (@{ $sub_ids || [] }) {
		next unless defined $id && length $id;
		push @items, { id => "$id", op => 'SUBTRACT', type => 'song' };
	}
	_post('/api/alchemy', {
		items => \@items,
		n     => $n,
	}, $cb_ok, $cb_err, TIMEOUT_LONG);
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

1;
