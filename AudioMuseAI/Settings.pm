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

sub handler {
	my ($class, $client, $params) = @_;

	if ($params->{'test_connection'}) {
		# Synchronous-ish: API calls are async, but the settings page
		# template re-renders on the next request. Kick off a probe
		# and stash the result in a transient pref the template reads.
		Plugins::AudioMuseAI::API::ping(
			sub {
				$prefs->set('last_test_result', 'ok');
			},
			sub {
				my $err = shift || 'unknown';
				$prefs->set('last_test_result', "fail: $err");
			},
		);
		# Set a "in-progress" marker so the template shows something
		# until the next render.
		$prefs->set('last_test_result', 'in_progress');
	}

	$params->{'test_result'} = $prefs->get('last_test_result') || '';

	return $class->SUPER::handler($client, $params);
}

1;
