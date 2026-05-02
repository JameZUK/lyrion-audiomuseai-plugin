package Plugins::AudioMuseAI::API;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.audiomuseai');
my $prefs = preferences('plugin.audiomuseai');

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

sub _get {
	my ($path, $cb_ok, $cb_err) = @_;
	my $url = _base() . $path;
	$log->debug("GET $url");

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $body = $http->content;
			my $data = eval { from_json($body) };
			if ($@ || !defined $data) {
				$log->warn("bad JSON from $url: $@ // body: $body");
				return $cb_err->("Invalid JSON from server") if $cb_err;
			}
			if (ref $data eq 'HASH' && $data->{error}) {
				return $cb_err->($data->{error}) if $cb_err;
			}
			$cb_ok->($data);
		},
		sub {
			my ($http, $err) = @_;
			$log->warn("HTTP error $url: $err");
			$cb_err->($err) if $cb_err;
		},
		{ timeout => 30 },
	);
	$http->get($url, _headers());
}

sub _post {
	my ($path, $payload, $cb_ok, $cb_err) = @_;
	my $url = _base() . $path;
	$log->debug("POST $url");

	my $body = to_json($payload || {});
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $resp = $http->content;
			my $data = eval { from_json($resp) };
			if ($@) {
				$log->warn("bad JSON from $url: $@");
				return $cb_err->("Invalid JSON from server") if $cb_err;
			}
			if (ref $data eq 'HASH' && $data->{error}) {
				return $cb_err->($data->{error}) if $cb_err;
			}
			$cb_ok->($data);
		},
		sub {
			my ($http, $err) = @_;
			$log->warn("HTTP error $url: $err");
			$cb_err->($err) if $cb_err;
		},
		{ timeout => 60 },
	);
	$http->post($url, _headers(), 'Content-Type' => 'application/json', $body);
}

# --- Public endpoints used by the plugin ---

sub ping {
	my ($cb_ok, $cb_err) = @_;
	_get('/api/active_tasks', $cb_ok, $cb_err);
}

sub similar_tracks {
	my ($item_id, $n, $cb_ok, $cb_err) = @_;
	$n ||= 20;
	my $path = sprintf('/api/similar_tracks?item_id=%s&n=%d&eliminate_duplicates=true',
		uri_escape_utf8($item_id), $n);
	_get($path, $cb_ok, $cb_err);
}

sub similar_artists {
	my ($artist, $n, $cb_ok, $cb_err) = @_;
	$n ||= 10;
	my $path = sprintf('/api/similar_artists?artist=%s&n=%d',
		uri_escape_utf8($artist), $n);
	_get($path, $cb_ok, $cb_err);
}

sub search_tracks {
	my ($artist, $cb_ok, $cb_err) = @_;
	my $path = '/api/search_tracks?artist=' . uri_escape_utf8($artist);
	_get($path, $cb_ok, $cb_err);
}

sub sonic_fingerprint {
	my ($n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	_get("/api/sonic_fingerprint/generate?n=$n", $cb_ok, $cb_err);
}

sub find_path {
	my ($start_id, $end_id, $max_steps, $cb_ok, $cb_err) = @_;
	$max_steps ||= 10;
	my $path = sprintf('/api/find_path?start_song_id=%s&end_song_id=%s&max_steps=%d',
		uri_escape_utf8($start_id), uri_escape_utf8($end_id), $max_steps);
	_get($path, $cb_ok, $cb_err);
}

sub clap_search {
	my ($prompt, $n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	_post('/api/clap/search', { query => $prompt, n => $n }, $cb_ok, $cb_err);
}

sub alchemy {
	my ($add_ids, $sub_ids, $n, $cb_ok, $cb_err) = @_;
	$n ||= 25;
	_post('/api/alchemy', {
		add => $add_ids || [],
		sub => $sub_ids || [],
		n   => $n,
	}, $cb_ok, $cb_err);
}

sub start_analysis  { my ($cb_ok, $cb_err) = @_; _post('/api/analysis/start',   {}, $cb_ok, $cb_err); }
sub start_clustering { my ($cb_ok, $cb_err) = @_; _post('/api/clustering/start', {}, $cb_ok, $cb_err); }

1;
