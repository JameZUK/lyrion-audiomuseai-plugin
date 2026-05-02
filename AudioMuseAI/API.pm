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

# Per-call timeouts (seconds). CLAP / clustering can take a while.
use constant {
	TIMEOUT_FAST  => 15,
	TIMEOUT_QUERY => 60,
	TIMEOUT_LONG  => 180,
};

sub _base {
	my $url = $prefs->get('url') || 'http://localhost:8000';
	$url =~ s{/+$}{};
	return $url;
}

sub _headers {
	my $token = $prefs->get('token');
	my @h = ('Accept' => 'application/json');
	push @h, 'Authorization' => "Bearer $token" if $token;
	return @h;
}

sub _decode {
	my ($body, $url) = @_;
	my $data = eval { from_json($body) };
	if ($@) {
		$log->warn("Bad JSON from $url: $@ // body fragment: " . substr($body || '', 0, 200));
		return (undef, "Invalid JSON from server");
	}
	if (ref($data) eq 'HASH' && $data->{error}) {
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
			return $cb_ok->($hit);
		}
	}

	$log->debug("GET $url (timeout ${timeout}s)");

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my ($data, $err) = _decode($http->content, $url);
			return $cb_err->($err) if $err && $cb_err;
			$cache->set("get:$url", $data, $cache_for) if $cache_for && !$err;
			$cb_ok->($data) if $cb_ok && !$err;
		},
		sub {
			my ($http, $err) = @_;
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

	my $body = to_json($payload || {});
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my ($data, $err) = _decode($http->content, $url);
			return $cb_err->($err) if $err && $cb_err;
			$cb_ok->($data) if $cb_ok && !$err;
		},
		sub {
			my ($http, $err) = @_;
			$log->warn("HTTP error $url: $err");
			$cb_err->($err) if $cb_err;
		},
		{ timeout => $timeout },
	);
	$http->post($url, _headers(), 'Content-Type' => 'application/json', $body);
}

# ---------- public API surface ----------

sub ping {
	my ($cb_ok, $cb_err) = @_;
	# Reuse active_tasks as a liveness probe; cache 5s so the settings page
	# and startup health check don't thrash it.
	_get('/api/active_tasks', $cb_ok, $cb_err, TIMEOUT_FAST, 5);
}

sub active_tasks {
	my ($cb_ok, $cb_err) = @_;
	_get('/api/active_tasks', $cb_ok, $cb_err, TIMEOUT_FAST);
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
	# Cache search results for 60s — same artist tends to be searched
	# repeatedly during alchemy / find-path flows.
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
	_post('/api/clap/search', { query => $prompt, n => $n },
		$cb_ok, $cb_err, TIMEOUT_LONG);
}

sub alchemy {
	my ($add_ids, $sub_ids, $n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	_post('/api/alchemy', {
		add => $add_ids || [],
		sub => $sub_ids || [],
		n   => $n,
	}, $cb_ok, $cb_err, TIMEOUT_LONG);
}

sub start_analysis  {
	my ($cb_ok, $cb_err) = @_;
	_post('/api/analysis/start', {}, $cb_ok, $cb_err, TIMEOUT_FAST);
}

sub start_clustering {
	my ($cb_ok, $cb_err) = @_;
	_post('/api/clustering/start', {}, $cb_ok, $cb_err, TIMEOUT_FAST);
}

1;
