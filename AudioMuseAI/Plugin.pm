package Plugins::AudioMuseAI::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);

use Slim::Control::Request;
use Slim::Control::Jive;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::AudioMuseAI::API;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.audiomuseai',
	'defaultLevel' => 'INFO',
	'description'  => 'PLUGIN_AUDIOMUSEAI',
});

my $prefs = preferences('plugin.audiomuseai');

# Cache for the most-recently-played track per client, used by the
# DSTM-style auto-extend hook.
my %lastTrackId;

sub initPlugin {
	my $class = shift;

	$prefs->init({
		url           => 'http://localhost:8000',
		token         => '',
		default_count => 25,
		dstm_enabled  => 0,
	});

	if (main::WEBUI) {
		require Plugins::AudioMuseAI::Settings;
		Plugins::AudioMuseAI::Settings->new;
	}

	# CLI dispatch table — every menu action lands here. The 'menu' arg
	# tells SqueezeCenter to format the response as a Jive menu.
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu'],
		[0, 1, 1, \&_topMenu]);

	Slim::Control::Request::addDispatch(['audiomuseai', 'similar_now'],
		[1, 1, 1, \&_similarNow]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'sonic_fp'],
		[1, 1, 1, \&_sonicFingerprint]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'instant'],
		[1, 1, 1, \&_instantPlaylist]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'similar_artist'],
		[1, 1, 1, \&_similarArtist]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'similar_track', '_trackid'],
		[1, 1, 1, \&_similarTrack]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'dynamic_similar'],
		[1, 1, 1, \&_dynamicSimilar]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'dynamic_fp'],
		[1, 1, 1, \&_dynamicFingerprint]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'open_map'],
		[0, 1, 1, \&_openMap]);

	# Top-level menu under My Music.
	my @items = ({
		text    => string('PLUGIN_AUDIOMUSEAI'),
		id      => 'pluginAudioMuseAI',
		weight  => 80,
		node    => 'myMusic',
		actions => {
			go => {
				cmd    => ['audiomuseai', 'menu'],
				player => 0,
			},
		},
		window  => { titleStyle => 'mymusic' },
	});
	Slim::Control::Jive::registerPluginMenu(\@items, 'myMusic');

	# Listen for player events so we can track recent plays for DSTM.
	Slim::Control::Request::subscribe(\&_onNewSong,
		[['playlist'], ['newsong']]);

	$class->SUPER::initPlugin(@_);
	$log->info("AudioMuse-AI plugin v0.1.0 initialised");
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&_onNewSong);
}

# ---------------------------------------------------------------------------
# Menu dispatch handlers — each pushes a Jive menu onto the request
# ---------------------------------------------------------------------------

sub _topMenu {
	my $request = shift;

	my $count = $prefs->get('default_count') || 25;
	my @menu;

	push @menu, _menuItem(string('PLUGIN_AUDIOMUSEAI_MENU_SIMILAR_NOW'),
		['audiomuseai', 'similar_now'], 1);

	push @menu, _menuItem(string('PLUGIN_AUDIOMUSEAI_MENU_FINGERPRINT'),
		['audiomuseai', 'sonic_fp'], 1);

	push @menu, _textInputItem(string('PLUGIN_AUDIOMUSEAI_MENU_INSTANT'),
		string('PLUGIN_AUDIOMUSEAI_PROMPT_INSTANT'),
		['audiomuseai', 'instant'], 'prompt');

	push @menu, _textInputItem(string('PLUGIN_AUDIOMUSEAI_MENU_SIMILAR_ARTIST'),
		'Artist name',
		['audiomuseai', 'similar_artist'], 'artist');

	# Dynamic Playlists submenu
	push @menu, {
		text    => string('PLUGIN_AUDIOMUSEAI_MENU_DYNAMIC'),
		actions => {
			go => {
				cmd    => ['audiomuseai', 'menu_dynamic'],
				player => 0,
			},
		},
	};

	push @menu, _menuItem(string('PLUGIN_AUDIOMUSEAI_MENU_OPEN_MAP'),
		['audiomuseai', 'open_map'], 0);

	$request->addResult('count', scalar @menu);
	$request->addResult('offset', 0);
	$request->addResult('item_loop', \@menu);
	$request->setStatusDone;
}

# Build a tappable menu item that fires a CLI command.
sub _menuItem {
	my ($text, $cmd, $needsPlayer) = @_;
	return {
		text    => $text,
		actions => {
			go => {
				cmd    => $cmd,
				player => $needsPlayer ? 1 : 0,
			},
		},
		nextWindow => 'refresh',
	};
}

# Build a menu item that prompts for text and then fires a CLI command
# with the entered text passed as a tagged param ($paramName:<text>).
sub _textInputItem {
	my ($text, $prompt, $cmd, $paramName) = @_;
	return {
		text  => $text,
		input => {
			len  => 1,
			help => { text => $prompt },
			softbutton1 => 'Insert',
			softbutton2 => 'Delete',
		},
		actions => {
			go => {
				cmd    => $cmd,
				player => 1,
				params => { $paramName => '__TAGGEDINPUT__' },
			},
		},
		nextWindow => 'refresh',
	};
}

# ---------------------------------------------------------------------------
# Action handlers — each calls AudioMuse async, then either queues tracks
# or pushes a notification menu.
# ---------------------------------------------------------------------------

sub _similarNow {
	my $request = shift;
	my $client  = $request->client or do {
		$request->setStatusBadParams;
		return;
	};

	my $song = Slim::Player::Playlist::song($client);
	unless ($song && $song->id) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_NOTHING_PLAYING'));
		return;
	}
	my $tid = $song->id;
	$log->info("similar_now: track=$tid client=" . $client->id);

	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::similar_tracks(
		$tid,
		$prefs->get('default_count') || 25,
		sub { _queueResults($request, $client, shift, 0) },
		sub { _notifyError($request, shift) },
	);
}

sub _sonicFingerprint {
	my $request = shift;
	my $client  = $request->client or do {
		$request->setStatusBadParams;
		return;
	};
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::sonic_fingerprint(
		$prefs->get('default_count') || 25,
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
}

sub _instantPlaylist {
	my $request = shift;
	my $client  = $request->client or do {
		$request->setStatusBadParams;
		return;
	};
	my $prompt = $request->getParam('prompt');
	unless ($prompt) {
		_notify($request, "Empty prompt");
		return;
	}
	$log->info("instant playlist prompt: $prompt");
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::clap_search(
		$prompt,
		$prefs->get('default_count') || 25,
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
}

sub _similarArtist {
	my $request = shift;
	my $client  = $request->client or do {
		$request->setStatusBadParams;
		return;
	};
	my $artist = $request->getParam('artist');
	unless ($artist) {
		_notify($request, "Empty artist name");
		return;
	}
	$request->setStatusProcessing;
	# similar_artists returns artists; we then need their tracks. Two-step:
	# first artist similarity, then search_tracks for each top artist,
	# concatenate. For v1 we just use the first similar artist's tracks.
	Plugins::AudioMuseAI::API::similar_artists(
		$artist, 5,
		sub {
			my $data = shift;
			my @artists = ref($data) eq 'ARRAY' ? @$data : ();
			unless (@artists) {
				_notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
				return;
			}
			my $first = $artists[0]->{artist} || $artists[0]->{name};
			Plugins::AudioMuseAI::API::search_tracks(
				$first,
				sub { _queueResults($request, $client, shift, 0) },
				sub { _notifyError($request, shift) },
			);
		},
		sub { _notifyError($request, shift) },
	);
}

sub _similarTrack {
	my $request = shift;
	my $client  = $request->client or do {
		$request->setStatusBadParams;
		return;
	};
	my $tid = $request->getParam('_trackid');
	unless ($tid) {
		$request->setStatusBadParams;
		return;
	}
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::similar_tracks(
		$tid,
		$prefs->get('default_count') || 25,
		sub { _queueResults($request, $client, shift, 0) },
		sub { _notifyError($request, shift) },
	);
}

sub _dynamicSimilar {
	my $request = shift;
	# Same as similar_now but enables the auto-extend flag for this client.
	my $client = $request->client or do {
		$request->setStatusBadParams;
		return;
	};
	$prefs->client($client)->set('dstm_active', 'similar');
	_similarNow($request);
}

sub _dynamicFingerprint {
	my $request = shift;
	my $client = $request->client or do {
		$request->setStatusBadParams;
		return;
	};
	$prefs->client($client)->set('dstm_active', 'fingerprint');
	_sonicFingerprint($request);
}

sub _openMap {
	my $request = shift;
	my $url = ($prefs->get('url') || '') . '/';
	$request->addResult('count', 1);
	$request->addResult('offset', 0);
	$request->addResult('item_loop', [{
		text => string('PLUGIN_AUDIOMUSEAI_MENU_OPEN_MAP') . ":\n$url",
	}]);
	$request->setStatusDone;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Take an AudioMuse response (list of {item_id, ...}), turn it into a
# Lyrion `playlistcontrol` add/load command. $loadFresh=1 replaces queue.
sub _queueResults {
	my ($request, $client, $data, $loadFresh) = @_;

	unless (ref($data) eq 'ARRAY' && @$data) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
		return;
	}

	my @ids = grep { defined && length } map {
		my $i = $_->{item_id} // $_->{id};
		# AudioMuse returns string IDs; Lyrion's playlistcontrol accepts them.
		$i;
	} @$data;

	unless (@ids) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
		return;
	}

	my $cmd = $loadFresh ? 'load' : 'add';
	$log->info(sprintf("queueing %d tracks (%s) on %s",
		scalar @ids, $cmd, $client->id));

	Slim::Control::Request::executeRequest(
		$client,
		['playlistcontrol', "cmd:$cmd", 'track_id:' . join(',', @ids)]
	);

	_notify($request, string('PLUGIN_AUDIOMUSEAI_QUEUED'));
}

sub _notify {
	my ($request, $msg) = @_;
	$request->addResult('count', 1);
	$request->addResult('offset', 0);
	$request->addResult('item_loop', [{ text => $msg }]);
	$request->setStatusDone;
}

sub _notifyError {
	my ($request, $err) = @_;
	$err ||= 'Unknown error';
	if ($err =~ /unavailable/i) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_UNAVAILABLE'));
	} else {
		_notify($request, "AudioMuse-AI error: $err");
	}
}

# Track newly playing songs so DSTM-style hooks know what to extend from.
sub _onNewSong {
	my $request = shift;
	my $client  = $request->client or return;
	my $song    = Slim::Player::Playlist::song($client) or return;
	$lastTrackId{$client->id} = $song->id;

	my $mode = $prefs->client($client)->get('dstm_active') or return;
	return unless $prefs->get('dstm_enabled');

	my $remaining = Slim::Player::Playlist::count($client)
		- Slim::Player::Source::streamingSongIndex($client) - 1;
	return if $remaining > 3;

	$log->info("DSTM auto-extend mode=$mode remaining=$remaining");

	my $cb_ok  = sub {
		my $data = shift;
		return unless ref($data) eq 'ARRAY' && @$data;
		my @ids = map { $_->{item_id} // $_->{id} } @$data;
		Slim::Control::Request::executeRequest(
			$client,
			['playlistcontrol', 'cmd:add', 'track_id:' . join(',', @ids)]
		);
	};
	my $cb_err = sub { $log->warn("DSTM extend failed: " . shift) };

	if ($mode eq 'similar') {
		Plugins::AudioMuseAI::API::similar_tracks(
			$song->id, 10, $cb_ok, $cb_err);
	} elsif ($mode eq 'fingerprint') {
		Plugins::AudioMuseAI::API::sonic_fingerprint(10, $cb_ok, $cb_err);
	}
}

1;
