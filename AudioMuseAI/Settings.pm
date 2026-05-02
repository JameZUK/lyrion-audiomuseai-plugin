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
	return ($prefs, qw(url token default_count dstm_enabled));
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
	# SUPER reads $params->{pref_url} etc and writes them via the prefs
	# system, so by mutating $params we steer what gets stored.
	if (defined $params->{pref_url}) {
		$params->{pref_url} = _normalizeUrl($params->{pref_url});
	}
	if (defined $params->{pref_token}) {
		my $t = _trim($params->{pref_token});
		# Reject CR/LF — would smuggle headers into the Authorization line.
		$t = '' if $t =~ /[\r\n]/;
		$params->{pref_token} = $t;
	}
	if (defined $params->{pref_default_count}) {
		my $n = $params->{pref_default_count} || 25;
		$n = 5   if $n < 5;
		$n = 100 if $n > 100;
		$params->{pref_default_count} = int($n);
	}

	if ($params->{'test_connection'}) {
		# API calls are async; the settings page template re-renders on
		# the next request. Kick off a probe and stash the result in a
		# transient pref the template reads.
		Plugins::AudioMuseAI::API::ping(
			sub { $prefs->set('last_test_result', 'ok'); },
			sub {
				my $err = shift // 'unknown';
				$prefs->set('last_test_result', "fail: $err");
			},
		);
		$prefs->set('last_test_result', 'in_progress');
	}

	$params->{'test_result'} = $prefs->get('last_test_result') || '';

	return $class->SUPER::handler($client, $params);
}

1;
