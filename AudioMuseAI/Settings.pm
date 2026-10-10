package Plugins::AudioMuseAI::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::AudioMuseAI::API;

my $log   = logger('plugin.audiomuseai');
my $prefs = preferences('plugin.audiomuseai');

sub name { 'PLUGIN_AUDIOMUSEAI' }
sub page { 'plugins/AudioMuseAI/settings/basic.html' }

sub prefs {
	return ($prefs, qw(
		url token default_count dstm_enabled
		save_playlist_format auto_save_instant auto_save_mood
		auto_save_album server_name
		mix_no_repeat_artist mix_no_repeat_album mix_min_duration mix_max_duration
		mix_filter_xmas mix_exclude_artists mix_exclude_albums mix_filter_genres
		mix_genre_groups mix_use_track_genre mix_match_all_genres mix_shuffle
		mix_strict_similarity history_max
		dstm_tracks dstm_seed_tracks dstm_seed_strict dstm_lastmix_fallback
		ui_mode
	));
}

sub _trim {
	my $s = shift;
	return '' unless defined $s;
	$s =~ s/\A\s+//;
	$s =~ s/\s+\z//;
	return $s;
}

sub _normalizeUrl {
	my $u = _trim(shift // '');
	return $u unless length $u;
	$u = "http://$u" unless $u =~ m{^https?://}i;
	$u =~ s{/+$}{};
	return $u;
}

sub handler {
	my ($class, $client, $params) = @_;

	# Normalize submitted values BEFORE SUPER::handler persists them.
	if (defined $params->{pref_url}) {
		$params->{pref_url} = _normalizeUrl($params->{pref_url});
	}
	if (defined $params->{pref_token}) {
		my $t = _trim($params->{pref_token});
		$t = '' if $t =~ /[\r\n]/;        # reject header-smuggling input
		$params->{pref_token} = $t;
	}
	if (defined $params->{pref_server_name}) {
		my $n = _trim($params->{pref_server_name});
		$n = '' if $n =~ /[\r\n]/;
		$params->{pref_server_name} = $n;
	}
	if (defined $params->{pref_default_count}) {
		my $n = $params->{pref_default_count} || 25;
		$n = 5   if $n < 5;
		$n = 100 if $n > 100;
		$params->{pref_default_count} = int($n);
	}

	# Mix filter / DSTM numbers: whole numbers, clamped to sane ranges.
	my %range = (
		mix_no_repeat_artist => [0, 200],  mix_no_repeat_album => [0, 200],
		mix_min_duration     => [0, 3600], mix_max_duration    => [0, 7200],
		history_max          => [10, 5000],
		dstm_tracks          => [1, 50],   dstm_seed_tracks    => [1, 10],
	);
	for my $k (keys %range) {
		next unless defined $params->{"pref_$k"};
		my ($lo, $hi) = @{ $range{$k} };
		my $n = $params->{"pref_$k"};
		$n = ($n =~ /\A\s*(\d+)\s*\z/) ? $1 : $lo;
		$n = $lo if $n < $lo;
		$n = $hi if $n > $hi;
		$params->{"pref_$k"} = int($n);
	}
	for my $k (qw(mix_exclude_artists mix_exclude_albums mix_genre_groups)) {
		next unless defined $params->{"pref_$k"};
		# One entry per line; drop blank lines and stray whitespace.
		$params->{"pref_$k"} = join("\n", grep { length }
			map { my $l = $_; $l =~ s/\A\s+|\s+\z//g; $l } split /\r?\n/, $params->{"pref_$k"});
	}
	if (defined $params->{pref_ui_mode}) {
		$params->{pref_ui_mode} = 'full' unless $params->{pref_ui_mode} eq 'dstm';
	}

	# Whitelist for save_playlist_format — guards against form-tampering.
	if (defined $params->{pref_save_playlist_format}) {
		my %ok = map { $_ => 1 }
			qw(timestamp first_track artist_mix mood_tagged prompt);
		$params->{pref_save_playlist_format} = 'timestamp'
			unless $ok{ $params->{pref_save_playlist_format} };
	}

	my $is_post = grep { /^pref_/ } keys %$params;

	if ($params->{'test_connection'}) {
		# Start the async probe. The page renders 'Testing…' and a JS
		# poller (in basic.html) polls audiomuseai test_result via
		# JSON-RPC every 500ms until this changes to ok / fail:.
		$prefs->set('last_test_result', 'in_progress');
		Plugins::AudioMuseAI::API::ping(
			sub {
				# Only write if the test we kicked off is still the
				# current outstanding one; the user may have saved
				# different settings since.
				my $set = sub {
					$prefs->set('last_test_result', shift)
						if ($prefs->get('last_test_result') // '') eq 'in_progress';
				};
				my $name = $prefs->get('server_name') // '';
				$name =~ s/\A\s+|\s+\z//g;
				return $set->('ok') unless length $name;
				# Multi-server: check the configured name exists, or
				# every request would fail with a bare 400 later.
				Plugins::AudioMuseAI::API::list_servers(
					sub {
						my $d = shift;
						my @s = (ref($d) eq 'HASH' && ref($d->{servers}) eq 'ARRAY')
							? grep { ref($_) eq 'HASH' } @{ $d->{servers} } : ();
						my ($hit) = grep {
							lc($_->{name} // '') eq lc($name) || ($_->{server_id} // '') eq $name
						} @s;
						return $set->('ok') if $hit;
						$set->(sprintf("fail: AudioMuse has no music server named '%s' (configured: %s)",
							$name, join(', ', map { $_->{name} // $_->{server_id} // '?' } @s) || 'none'));
					},
					sub { $set->('fail: could not list AudioMuse music servers: ' . (shift // 'unknown')) },
				);
			},
			sub {
				my $err = shift // 'unknown';
				$prefs->set('last_test_result', "fail: $err")
					if ($prefs->get('last_test_result') // '') eq 'in_progress';
			},
		);
	} elsif ($is_post) {
		# Plain Save — the previous test result no longer reflects the
		# current URL/token, so clear it to avoid showing stale state.
		$prefs->set('last_test_result', '');
	}

	$params->{'test_result'} = $prefs->get('last_test_result') // '';

	# Surfaced at the bottom of the page so users can verify which build
	# is actually loaded without bouncing to the extension manager.
	$params->{'plugin_version'} = Plugins::AudioMuseAI::Plugin::VERSION();

	return $class->SUPER::handler($client, $params);
}

1;
