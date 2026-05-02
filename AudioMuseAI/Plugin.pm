package Plugins::AudioMuseAI::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);

use Slim::Control::Request;
use Slim::Control::Jive;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Timers;

use Plugins::AudioMuseAI::API;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.audiomuseai',
	'defaultLevel' => 'INFO',
	'description'  => 'PLUGIN_AUDIOMUSEAI',
});

my $prefs = preferences('plugin.audiomuseai');

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

	# CLI dispatch table — every menu action lands here. The middle field
	# in the dispatch tuple ([needsClient, needsArrayResp, isQuery, sub])
	# matters: 1 means a player is required for that command.

	# Menu builders ----------------------------------------------------------
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu'],
		[0, 1, 1, \&_topMenu]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_mood'],
		[0, 1, 1, \&_menuMood]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_alchemy'],
		[0, 1, 1, \&_menuAlchemy]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_findpath'],
		[0, 1, 1, \&_menuFindPath]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_dynamic'],
		[0, 1, 1, \&_menuDynamic]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_status'],
		[0, 1, 1, \&_menuStatus]);

	# Direct actions ---------------------------------------------------------
	Slim::Control::Request::addDispatch(['audiomuseai', 'similar_now'],
		[1, 1, 1, \&_similarNow]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'similar_song_search'],
		[1, 1, 1, \&_similarSongSearch]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'similar_track'],
		[1, 1, 1, \&_similarTrack]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'similar_artist'],
		[1, 1, 1, \&_similarArtist]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'sonic_fp'],
		[1, 1, 1, \&_sonicFingerprint]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'instant'],
		[1, 1, 1, \&_instantPlaylist]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'mood'],
		[1, 1, 1, \&_moodPlaylist]);

	# Alchemy ----------------------------------------------------------------
	Slim::Control::Request::addDispatch(['audiomuseai', 'alchemy_add_now'],
		[1, 1, 1, \&_alchemyAddNow]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'alchemy_sub_now'],
		[1, 1, 1, \&_alchemySubNow]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'alchemy_show'],
		[1, 1, 1, \&_alchemyShow]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'alchemy_reset'],
		[1, 1, 1, \&_alchemyReset]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'alchemy_generate'],
		[1, 1, 1, \&_alchemyGenerate]);

	# Find path --------------------------------------------------------------
	Slim::Control::Request::addDispatch(['audiomuseai', 'findpath_search'],
		[1, 1, 1, \&_findPathSearch]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'findpath_to'],
		[1, 1, 1, \&_findPathExecute]);

	# Dynamic playlists ------------------------------------------------------
	Slim::Control::Request::addDispatch(['audiomuseai', 'dyn_similar'],
		[1, 1, 1, \&_dynamicSimilar]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'dyn_fingerprint'],
		[1, 1, 1, \&_dynamicFingerprint]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'dyn_stop'],
		[1, 1, 1, \&_dynamicStop]);

	# Server status / admin --------------------------------------------------
	Slim::Control::Request::addDispatch(['audiomuseai', 'status_active'],
		[0, 1, 1, \&_statusActive]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'status_last'],
		[0, 1, 1, \&_statusLast]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'run_analysis'],
		[0, 1, 1, \&_runAnalysis]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'run_clustering'],
		[0, 1, 1, \&_runClustering]);
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

	# Listen for new-song events so DSTM-style hooks know what to extend from.
	Slim::Control::Request::subscribe(\&_onNewSong,
		[['playlist'], ['newsong']]);

	$class->SUPER::initPlugin(@_);
	$log->info("AudioMuse-AI plugin v0.2.0 initialised");

	# Startup health check (deferred a few seconds so SimpleAsyncHTTP is up).
	Slim::Utils::Timers::setTimer(undef, time() + 5, \&_healthCheck);
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&_onNewSong);
}

sub _healthCheck {
	Plugins::AudioMuseAI::API::ping(
		sub { $log->info("AudioMuse-AI reachable: " . ($prefs->get('url') || 'unset')); },
		sub {
			my $err = shift;
			$log->warn("AudioMuse-AI not reachable at " . ($prefs->get('url') || 'unset') . ": $err");
		},
	);
}

# ===========================================================================
# Menu builders
# ===========================================================================

sub _topMenu {
	my $request = shift;
	my @menu;

	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_SIMILAR_NOW',
		['audiomuseai', 'similar_now'], 1);

	push @menu, _textInputItem('PLUGIN_AUDIOMUSEAI_MENU_SIMILAR_SONG',
		'PLUGIN_AUDIOMUSEAI_PROMPT_SONG_ARTIST',
		['audiomuseai', 'similar_song_search'], 'artist');

	push @menu, _textInputItem('PLUGIN_AUDIOMUSEAI_MENU_SIMILAR_ARTIST',
		'PLUGIN_AUDIOMUSEAI_PROMPT_ARTIST',
		['audiomuseai', 'similar_artist'], 'artist');

	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_FINGERPRINT',
		['audiomuseai', 'sonic_fp'], 1);

	push @menu, _textInputItem('PLUGIN_AUDIOMUSEAI_MENU_INSTANT',
		'PLUGIN_AUDIOMUSEAI_PROMPT_INSTANT',
		['audiomuseai', 'instant'], 'prompt');

	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_MOOD',
		['audiomuseai', 'menu_mood']);
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_ALCHEMY',
		['audiomuseai', 'menu_alchemy']);
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_FINDPATH',
		['audiomuseai', 'menu_findpath']);
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_DYNAMIC',
		['audiomuseai', 'menu_dynamic']);
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_STATUS',
		['audiomuseai', 'menu_status']);
	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_OPEN_MAP',
		['audiomuseai', 'open_map'], 0);

	_emit($request, \@menu);
}

sub _menuMood {
	my $request = shift;

	my @presets = (
		['PLUGIN_AUDIOMUSEAI_MOOD_ENERGETIC',  'energetic, upbeat, high tempo, driving'],
		['PLUGIN_AUDIOMUSEAI_MOOD_CALM',       'calm, ambient, peaceful, relaxing'],
		['PLUGIN_AUDIOMUSEAI_MOOD_SAD',        'sad, melancholy, slow, sorrowful'],
		['PLUGIN_AUDIOMUSEAI_MOOD_HAPPY',      'happy, upbeat, joyful, bright'],
		['PLUGIN_AUDIOMUSEAI_MOOD_AGGRESSIVE', 'aggressive, hard, intense, heavy'],
		['PLUGIN_AUDIOMUSEAI_MOOD_ACOUSTIC',   'acoustic, mellow, unplugged, intimate'],
		['PLUGIN_AUDIOMUSEAI_MOOD_PARTY',      'party, danceable, club, upbeat'],
	);

	my @menu;
	for my $p (@presets) {
		my ($key, $prompt) = @$p;
		push @menu, {
			text    => string($key),
			actions => {
				go => {
					cmd    => ['audiomuseai', 'mood'],
					player => 1,
					params => { prompt => $prompt },
				},
			},
			nextWindow => 'refresh',
		};
	}
	push @menu, _textInputItem('PLUGIN_AUDIOMUSEAI_MOOD_CUSTOM',
		'PLUGIN_AUDIOMUSEAI_PROMPT_INSTANT',
		['audiomuseai', 'instant'], 'prompt');

	_emit($request, \@menu);
}

sub _menuAlchemy {
	my $request = shift;
	my @menu = (
		_actionItem('PLUGIN_AUDIOMUSEAI_ALCHEMY_SHOW',
			['audiomuseai', 'alchemy_show'], 1),
		_actionItem('PLUGIN_AUDIOMUSEAI_ALCHEMY_ADD_NOW',
			['audiomuseai', 'alchemy_add_now'], 1),
		_actionItem('PLUGIN_AUDIOMUSEAI_ALCHEMY_SUB_NOW',
			['audiomuseai', 'alchemy_sub_now'], 1),
		_actionItem('PLUGIN_AUDIOMUSEAI_ALCHEMY_RESET',
			['audiomuseai', 'alchemy_reset'], 1),
		_actionItem('PLUGIN_AUDIOMUSEAI_ALCHEMY_GENERATE',
			['audiomuseai', 'alchemy_generate'], 1),
	);
	_emit($request, \@menu);
}

sub _menuFindPath {
	my $request = shift;
	my @menu = (
		_textInputItem('PLUGIN_AUDIOMUSEAI_FINDPATH_FROM_NOW',
			'PLUGIN_AUDIOMUSEAI_FINDPATH_PROMPT',
			['audiomuseai', 'findpath_search'], 'artist'),
	);
	_emit($request, \@menu);
}

sub _menuDynamic {
	my $request = shift;
	my @menu = (
		_actionItem('PLUGIN_AUDIOMUSEAI_DYNAMIC_SIMILAR',
			['audiomuseai', 'dyn_similar'], 1),
		_actionItem('PLUGIN_AUDIOMUSEAI_DYNAMIC_FINGERPRINT',
			['audiomuseai', 'dyn_fingerprint'], 1),
		_actionItem('PLUGIN_AUDIOMUSEAI_DYNAMIC_STOP',
			['audiomuseai', 'dyn_stop'], 1),
	);
	_emit($request, \@menu);
}

sub _menuStatus {
	my $request = shift;
	my @menu = (
		_actionItem('PLUGIN_AUDIOMUSEAI_STATUS_ACTIVE',
			['audiomuseai', 'status_active'], 0),
		_actionItem('PLUGIN_AUDIOMUSEAI_STATUS_LAST',
			['audiomuseai', 'status_last'], 0),
		# Confirmations: each "trigger" is a sub-menu that asks Yes/No.
		{
			text    => string('PLUGIN_AUDIOMUSEAI_STATUS_RUN_ANALYSIS'),
			actions => {
				go => {
					cmd    => ['audiomuseai', 'run_analysis'],
					player => 0,
				},
			},
		},
		{
			text    => string('PLUGIN_AUDIOMUSEAI_STATUS_RUN_CLUSTERING'),
			actions => {
				go => {
					cmd    => ['audiomuseai', 'run_clustering'],
					player => 0,
				},
			},
		},
	);
	_emit($request, \@menu);
}

# ===========================================================================
# Action handlers
# ===========================================================================

sub _similarNow {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $song    = Slim::Player::Playlist::song($client);
	unless ($song && $song->id) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NOTHING_PLAYING'));
	}
	$log->info("similar_now: track=" . $song->id . " client=" . $client->id);
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::similar_tracks(
		$song->id,
		_count(),
		sub { _queueResults($request, $client, shift, 0) },
		sub { _notifyError($request, shift) },
	);
}

sub _similarSongSearch {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $artist  = $request->getParam('artist');
	return _notify($request, "Empty artist") unless $artist;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::search_tracks(
		$artist,
		sub {
			my $tracks = shift;
			unless (ref($tracks) eq 'ARRAY' && @$tracks) {
				return _notify($request,
					string('PLUGIN_AUDIOMUSEAI_NO_TRACKS_FOR_ARTIST'));
			}
			# Render the result list as a Jive menu of tappable tracks.
			my @items;
			for my $t (@$tracks) {
				my $tid = $t->{item_id} // $t->{id} // next;
				my $label = ($t->{title} // '?') . ' — ' . ($t->{author} // $t->{album_artist} // '?');
				push @items, {
					text    => $label,
					actions => {
						go => {
							cmd    => ['audiomuseai', 'similar_track'],
							player => 1,
							params => { track_id => "$tid" },
						},
					},
					nextWindow => 'refresh',
				};
			}
			_emit($request, \@items);
		},
		sub { _notifyError($request, shift) },
	);
}

sub _similarTrack {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $tid     = $request->getParam('track_id');
	return $request->setStatusBadParams unless $tid;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::similar_tracks(
		$tid, _count(),
		sub { _queueResults($request, $client, shift, 0) },
		sub { _notifyError($request, shift) },
	);
}

sub _similarArtist {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $artist  = $request->getParam('artist') or return _notify($request, "Empty artist");
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::similar_artists(
		$artist, 5,
		sub {
			my $data = shift;
			my @arts = ref($data) eq 'ARRAY' ? @$data : ();
			unless (@arts) {
				return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
			}
			# Pull tracks from the top match. Could be expanded to
			# show the artist list and let user pick, but keeping flat
			# for v0.2 since the artist-similarity list is usually short.
			my $first = $arts[0]->{artist} // $arts[0]->{name} // $artist;
			Plugins::AudioMuseAI::API::search_tracks(
				$first,
				sub { _queueResults($request, $client, shift, 0) },
				sub { _notifyError($request, shift) },
			);
		},
		sub { _notifyError($request, shift) },
	);
}

sub _sonicFingerprint {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::sonic_fingerprint(
		_count(),
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
}

sub _instantPlaylist {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $prompt  = $request->getParam('prompt') or return _notify($request, "Empty prompt");
	$log->info("instant playlist: $prompt");
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::clap_search(
		$prompt, _count(),
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
}

sub _moodPlaylist {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $prompt  = $request->getParam('prompt') or return _notify($request, "Empty prompt");
	$log->info("mood playlist: $prompt");
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::clap_search(
		$prompt, _count(),
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
}

# ----- Alchemy --------------------------------------------------------------

sub _alchemyAddNow {
	my $request = shift;
	_alchemyAddTo($request, 'add');
}

sub _alchemySubNow {
	my $request = shift;
	_alchemyAddTo($request, 'sub');
}

sub _alchemyAddTo {
	my ($request, $bucket) = @_;
	my $client = $request->client or return $request->setStatusBadParams;
	my $song   = Slim::Player::Playlist::song($client) or
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NOTHING_PLAYING'));
	my $tid    = $song->id;

	my $key   = "alchemy_$bucket";
	my $list  = $prefs->client($client)->get($key) || [];
	# Ensure ARRAYref (LMS prefs sometimes round-trip as scalars when empty).
	$list = [] unless ref($list) eq 'ARRAY';
	push @$list, "$tid" unless grep { $_ eq "$tid" } @$list;
	$prefs->client($client)->set($key, $list);
	_notify($request, sprintf("ADDED to %s: %s — %s (%d in list)",
		uc($bucket),
		$song->title // '?',
		$song->artistName // '?',
		scalar @$list));
}

sub _alchemyShow {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $a = $prefs->client($client)->get('alchemy_add') || [];
	my $s = $prefs->client($client)->get('alchemy_sub') || [];
	$a = [] unless ref($a) eq 'ARRAY';
	$s = [] unless ref($s) eq 'ARRAY';
	if (!@$a && !@$s) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_ALCHEMY_EMPTY'));
	}
	my $msg = sprintf("ADD (%d): %s\nSUBTRACT (%d): %s",
		scalar @$a, join(',', @$a) || '—',
		scalar @$s, join(',', @$s) || '—');
	_notify($request, $msg);
}

sub _alchemyReset {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	$prefs->client($client)->set('alchemy_add', []);
	$prefs->client($client)->set('alchemy_sub', []);
	_notify($request, "Alchemy selection cleared.");
}

sub _alchemyGenerate {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $a = $prefs->client($client)->get('alchemy_add') || [];
	my $s = $prefs->client($client)->get('alchemy_sub') || [];
	$a = [] unless ref($a) eq 'ARRAY';
	$s = [] unless ref($s) eq 'ARRAY';
	unless (@$a || @$s) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_ALCHEMY_EMPTY'));
	}
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::alchemy(
		$a, $s, _count(),
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
}

# ----- Find Path ------------------------------------------------------------

sub _findPathSearch {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $song    = Slim::Player::Playlist::song($client);
	unless ($song && $song->id) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_FINDPATH_NO_START'));
	}
	my $artist = $request->getParam('artist') or return _notify($request, "Empty artist");
	my $start_id = $song->id;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::search_tracks(
		$artist,
		sub {
			my $tracks = shift;
			unless (ref($tracks) eq 'ARRAY' && @$tracks) {
				return _notify($request,
					string('PLUGIN_AUDIOMUSEAI_NO_TRACKS_FOR_ARTIST'));
			}
			my @items;
			for my $t (@$tracks) {
				my $tid   = $t->{item_id} // $t->{id} // next;
				my $label = ($t->{title} // '?') . ' — ' . ($t->{author} // '?');
				push @items, {
					text    => $label,
					actions => {
						go => {
							cmd    => ['audiomuseai', 'findpath_to'],
							player => 1,
							params => {
								start_id => "$start_id",
								end_id   => "$tid",
							},
						},
					},
					nextWindow => 'refresh',
				};
			}
			_emit($request, \@items);
		},
		sub { _notifyError($request, shift) },
	);
}

sub _findPathExecute {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $start   = $request->getParam('start_id') or return $request->setStatusBadParams;
	my $end     = $request->getParam('end_id')   or return $request->setStatusBadParams;
	$log->info("findpath: $start -> $end");
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::find_path(
		$start, $end, 12,
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
}

# ----- Dynamic playlists ----------------------------------------------------

sub _dynamicSimilar {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	$prefs->client($client)->set('dstm_active', 'similar');
	$log->info("DSTM mode 'similar' active for " . $client->id);
	_similarNow($request);
}

sub _dynamicFingerprint {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	$prefs->client($client)->set('dstm_active', 'fingerprint');
	$log->info("DSTM mode 'fingerprint' active for " . $client->id);
	_sonicFingerprint($request);
}

sub _dynamicStop {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	$prefs->client($client)->set('dstm_active', '');
	$log->info("DSTM mode cleared for " . $client->id);
	_notify($request, string('PLUGIN_AUDIOMUSEAI_DSTM_STOPPED'));
}

# ----- Server status / admin ------------------------------------------------

sub _statusActive {
	my $request = shift;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::active_tasks(
		sub { _statusFormat($request, shift) },
		sub { _notifyError($request, shift) },
	);
}

sub _statusLast {
	my $request = shift;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::last_task(
		sub { _statusFormat($request, shift) },
		sub { _notifyError($request, shift) },
	);
}

sub _statusFormat {
	my ($request, $data) = @_;
	# Render the most useful keys verbatim. Long log arrays get last-line only.
	my $details = ref($data) eq 'HASH' ? ($data->{details} // $data) : $data;
	my @lines;
	if (ref($details) eq 'HASH') {
		for my $k (sort keys %$details) {
			my $v = $details->{$k};
			if (ref($v) eq 'ARRAY') {
				$v = $v->[-1] // '';
				$v = "(...) " . $v if @{$details->{$k}} > 1;
			}
			push @lines, "$k: $v" if defined $v && !ref($v);
		}
	}
	@lines = ('No status returned.') unless @lines;
	_notify($request, join("\n", @lines));
}

sub _runAnalysis {
	my $request = shift;
	$log->info("triggering /api/analysis/start");
	Plugins::AudioMuseAI::API::start_analysis(
		sub { _notify($request, string('PLUGIN_AUDIOMUSEAI_STATUS_TRIGGERED')); },
		sub { _notifyError($request, shift); },
	);
}

sub _runClustering {
	my $request = shift;
	$log->info("triggering /api/clustering/start");
	Plugins::AudioMuseAI::API::start_clustering(
		sub { _notify($request, string('PLUGIN_AUDIOMUSEAI_STATUS_TRIGGERED')); },
		sub { _notifyError($request, shift); },
	);
}

sub _openMap {
	my $request = shift;
	my $url = ($prefs->get('url') || '') . '/';
	_notify($request, string('PLUGIN_AUDIOMUSEAI_MENU_OPEN_MAP') . ":\n$url");
}

# ===========================================================================
# Helpers
# ===========================================================================

sub _count { return $prefs->get('default_count') || 25; }

sub _actionItem {
	my ($strKey, $cmd, $needsPlayer) = @_;
	return {
		text    => string($strKey),
		actions => {
			go => {
				cmd    => $cmd,
				player => $needsPlayer ? 1 : 0,
			},
		},
		nextWindow => 'refresh',
	};
}

sub _submenuItem {
	my ($strKey, $cmd) = @_;
	return {
		text    => string($strKey),
		actions => {
			go => {
				cmd    => $cmd,
				player => 0,
			},
		},
	};
}

sub _textInputItem {
	my ($titleKey, $promptKey, $cmd, $paramName) = @_;
	return {
		text  => string($titleKey),
		input => {
			len  => 1,
			help => { text => string($promptKey) },
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

sub _emit {
	my ($request, $menu) = @_;
	$menu ||= [];
	$request->addResult('count', scalar @$menu);
	$request->addResult('offset', 0);
	$request->addResult('item_loop', $menu);
	$request->setStatusDone;
}

sub _notify {
	my ($request, $msg) = @_;
	_emit($request, [{ text => $msg }]);
}

sub _notifyError {
	my ($request, $err) = @_;
	$err ||= 'Unknown error';
	if ($err =~ /\b409\b/ || $err =~ /conflict/i) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_BUSY'));
	} elsif ($err =~ /unavailable/i || $err =~ /\b503\b/) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_UNAVAILABLE'));
	} elsif ($err =~ /\b401\b|\b403\b/ || $err =~ /unauthor/i || $err =~ /forbidden/i) {
		_notify($request, "AudioMuse-AI auth failed: check API token in plugin settings.");
	} elsif ($err =~ /timeout/i) {
		_notify($request, "AudioMuse-AI timed out. The server may be overloaded.");
	} else {
		_notify($request, "AudioMuse-AI error: $err");
	}
}

sub _queueResults {
	my ($request, $client, $data, $loadFresh) = @_;
	unless (ref($data) eq 'ARRAY' && @$data) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
	}
	my @ids = grep { defined && length } map { $_->{item_id} // $_->{id} } @$data;
	unless (@ids) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
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

# Track newly playing songs and auto-extend if a DSTM mode is active.
sub _onNewSong {
	my $request = shift;
	my $client  = $request->client or return;
	my $song    = Slim::Player::Playlist::song($client) or return;

	my $mode = $prefs->client($client)->get('dstm_active') or return;
	return unless $prefs->get('dstm_enabled');

	my $remaining = Slim::Player::Playlist::count($client)
		- Slim::Player::Source::streamingSongIndex($client) - 1;
	return if $remaining > 3;

	$log->info("DSTM auto-extend mode=$mode remaining=$remaining client=" . $client->id);

	my $cb_ok  = sub {
		my $data = shift;
		return unless ref($data) eq 'ARRAY' && @$data;
		my @ids = grep { defined && length } map { $_->{item_id} // $_->{id} } @$data;
		return unless @ids;
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
	} elsif ($mode eq 'alchemy') {
		my $a = $prefs->client($client)->get('alchemy_add') || [];
		my $s = $prefs->client($client)->get('alchemy_sub') || [];
		Plugins::AudioMuseAI::API::alchemy($a, $s, 10, $cb_ok, $cb_err);
	}
}

1;
