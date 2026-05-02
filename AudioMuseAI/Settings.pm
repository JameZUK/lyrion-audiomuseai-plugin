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
	if (defined $params->{pref_url}) {
		$params->{pref_url} = _normalizeUrl($params->{pref_url});
	}
	if (defined $params->{pref_token}) {
		my $t = _trim($params->{pref_token});
		$t = '' if $t =~ /[\r\n]/;        # reject header-smuggling input
		$params->{pref_token} = $t;
	}
	if (defined $params->{pref_default_count}) {
		my $n = $params->{pref_default_count} || 25;
		$n = 5   if $n < 5;
		$n = 100 if $n > 100;
		$params->{pref_default_count} = int($n);
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
				$prefs->set('last_test_result', 'ok')
					if ($prefs->get('last_test_result') // '') eq 'in_progress';
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

	return $class->SUPER::handler($client, $params);
}

1;
