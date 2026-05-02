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

use constant {
	VERSION             => '0.2.5',
	HEALTHCHECK_DELAY   => 5,
	# Cap search-result menus to keep the UI navigable on hardware
	# controllers; AudioMuse can return hundreds of tracks for prolific
	# artists.
	MAX_PICK_RESULTS    => 50,
	# Default count clamped to this range to avoid tiny / huge requests.
	COUNT_MIN           => 5,
	COUNT_MAX           => 100,
	FINDPATH_MAX_STEPS  => 12,
};

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.audiomuseai',
	'defaultLevel' => 'INFO',
	'description'  => 'PLUGIN_AUDIOMUSEAI',
});

my $prefs = preferences('plugin.audiomuseai');

# Tracks we registered timers for, so shutdownPlugin can clean up.
my @_timers;

sub initPlugin {
	my $class = shift;

	$prefs->init({
		url           => 'http://localhost:8000',
		token         => '',
		default_count => 25,
		dstm_enabled  => 0,
	});

	# One-time: normalize any pre-existing values that may have come in
	# with whitespace or missing scheme.
	if (my $u = $prefs->get('url'))   { $prefs->set('url',   _normalizeUrl($u)); }
	if (my $t = $prefs->get('token')) { $prefs->set('token', _trim($t));        }

	if (main::WEBUI) {
		require Plugins::AudioMuseAI::Settings;
		Plugins::AudioMuseAI::Settings->new;
	}

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

	# Settings-page AJAX support: report the latest connection-test result
	# as a JSON-RPC query so the page can poll without reloading.
	Slim::Control::Request::addDispatch(['audiomuseai', 'test_result'],
		[0, 1, 1, \&_testResult]);

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

	Slim::Control::Request::subscribe(\&_onNewSong,
		[['playlist'], ['newsong']]);

	$class->SUPER::initPlugin(@_);
	$log->info('AudioMuse-AI plugin v' . VERSION . ' initialised');

	# Startup health check (deferred so SimpleAsyncHTTP is fully up).
	my $when = time() + HEALTHCHECK_DELAY;
	Slim::Utils::Timers::setTimer(undef, $when, \&_healthCheck);
	push @_timers, [undef, $when, \&_healthCheck];
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&_onNewSong);
	for my $t (@_timers) {
		Slim::Utils::Timers::killSpecific(@$t);
	}
	@_timers = ();
}

sub _healthCheck {
	Plugins::AudioMuseAI::API::ping(
		sub {
			$log->info('AudioMuse-AI reachable: ' . ($prefs->get('url') || 'unset'));
		},
		sub {
			my $err = shift // 'unknown';
			$log->warn('AudioMuse-AI not reachable at '
				. ($prefs->get('url') || 'unset') . ": $err");
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
	_emit($request, [
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
	]);
}

sub _menuFindPath {
	my $request = shift;
	_emit($request, [
		_textInputItem('PLUGIN_AUDIOMUSEAI_FINDPATH_FROM_NOW',
			'PLUGIN_AUDIOMUSEAI_FINDPATH_PROMPT',
			['audiomuseai', 'findpath_search'], 'artist'),
	]);
}

sub _menuDynamic {
	my $request = shift;
	_emit($request, [
		_actionItem('PLUGIN_AUDIOMUSEAI_DYNAMIC_SIMILAR',
			['audiomuseai', 'dyn_similar'], 1),
		_actionItem('PLUGIN_AUDIOMUSEAI_DYNAMIC_FINGERPRINT',
			['audiomuseai', 'dyn_fingerprint'], 1),
		_actionItem('PLUGIN_AUDIOMUSEAI_DYNAMIC_STOP',
			['audiomuseai', 'dyn_stop'], 1),
	]);
}

sub _menuStatus {
	my $request = shift;
	_emit($request, [
		_actionItem('PLUGIN_AUDIOMUSEAI_STATUS_ACTIVE',
			['audiomuseai', 'status_active'], 0),
		_actionItem('PLUGIN_AUDIOMUSEAI_STATUS_LAST',
			['audiomuseai', 'status_last'], 0),
		_actionItem('PLUGIN_AUDIOMUSEAI_STATUS_RUN_ANALYSIS',
			['audiomuseai', 'run_analysis'], 0),
		_actionItem('PLUGIN_AUDIOMUSEAI_STATUS_RUN_CLUSTERING',
			['audiomuseai', 'run_clustering'], 0),
	]);
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
	$log->info('similar_now: track=' . $song->id . ' client=' . $client->id);
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::similar_tracks(
		$song->id, _count(),
		sub { _queueResults($request, $client, shift, 0) },
		sub { _notifyError($request, shift) },
	);
}

sub _similarSongSearch {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $artist  = _trim($request->getParam('artist') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $artist;

	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::search_tracks(
		$artist,
		sub {
			my $tracks = shift;
			unless (ref($tracks) eq 'ARRAY' && @$tracks) {
				return _notify($request,
					string('PLUGIN_AUDIOMUSEAI_NO_TRACKS_FOR_ARTIST'));
			}
			_emit($request, _tracksAsPickMenu($tracks, ['audiomuseai', 'similar_track'], 'track_id'));
		},
		sub { _notifyError($request, shift) },
	);
}

sub _similarTrack {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $tid     = $request->getParam('track_id');
	return $request->setStatusBadParams unless defined $tid && length $tid;
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
	my $artist  = _trim($request->getParam('artist') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $artist;

	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::similar_artists(
		$artist, 5,
		sub {
			my $data = shift;
			my @arts = ref($data) eq 'ARRAY' ? @$data : ();
			unless (@arts) {
				return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
			}
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
	my $prompt  = _trim($request->getParam('prompt') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $prompt;
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
	my $prompt  = _trim($request->getParam('prompt') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $prompt;
	$log->info("mood playlist: $prompt");
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::clap_search(
		$prompt, _count(),
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
}

# ----- Alchemy --------------------------------------------------------------

sub _alchemyAddNow { _alchemyAddTo($_[0], 'add'); }
sub _alchemySubNow { _alchemyAddTo($_[0], 'sub'); }

sub _alchemyAddTo {
	my ($request, $bucket) = @_;
	my $client = $request->client or return $request->setStatusBadParams;
	my $song   = Slim::Player::Playlist::song($client);
	unless ($song && $song->id) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NOTHING_PLAYING'));
	}
	my $tid = "" . $song->id;

	my $key  = "alchemy_$bucket";
	my $list = _alchemyList($client, $key);
	push @$list, $tid unless grep { $_ eq $tid } @$list;
	$prefs->client($client)->set($key, $list);
	_notify($request, sprintf('ADDED to %s: %s — %s (%d in list)',
		uc($bucket),
		$song->title      // '?',
		$song->artistName // '?',
		scalar @$list));
}

sub _alchemyShow {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $a = _alchemyList($client, 'alchemy_add');
	my $s = _alchemyList($client, 'alchemy_sub');
	if (!@$a && !@$s) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_ALCHEMY_EMPTY'));
	}
	# Cap displayed IDs in the summary line — long lists get truncated
	# with a "+N more" tail rather than rendering hundreds of IDs.
	_notifyLines($request, [
		_alchemyLine('ADD',      $a),
		_alchemyLine('SUBTRACT', $s),
	]);
}

sub _alchemyReset {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	$prefs->client($client)->set('alchemy_add', []);
	$prefs->client($client)->set('alchemy_sub', []);
	_notify($request, string('PLUGIN_AUDIOMUSEAI_ALCHEMY_CLEARED'));
}

sub _alchemyGenerate {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $a = _alchemyList($client, 'alchemy_add');
	my $s = _alchemyList($client, 'alchemy_sub');
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

sub _alchemyList {
	my ($client, $key) = @_;
	my $list = $prefs->client($client)->get($key);
	$list = [] unless ref($list) eq 'ARRAY';
	return $list;
}

sub _alchemyLine {
	my ($label, $list) = @_;
	my $count = scalar @$list;
	return sprintf('%s (%d): —', $label, $count) unless $count;
	my $shown = $count > 8 ? 8 : $count;
	my $body  = join(',', @$list[0 .. $shown - 1]);
	$body .= " (+@{[ $count - $shown ]} more)" if $count > $shown;
	return sprintf('%s (%d): %s', $label, $count, $body);
}

# ----- Find Path ------------------------------------------------------------

sub _findPathSearch {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $song    = Slim::Player::Playlist::song($client);
	unless ($song && $song->id) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_FINDPATH_NO_START'));
	}
	my $artist = _trim($request->getParam('artist') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $artist;

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
			_emit($request, _tracksAsPickMenu(
				$tracks,
				['audiomuseai', 'findpath_to'],
				'end_id',
				{ start_id => "$start_id" },
			));
		},
		sub { _notifyError($request, shift) },
	);
}

sub _findPathExecute {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $start   = $request->getParam('start_id');
	my $end     = $request->getParam('end_id');
	unless (defined $start && length $start && defined $end && length $end) {
		return $request->setStatusBadParams;
	}
	$log->info("findpath: $start -> $end");
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::find_path(
		$start, $end, FINDPATH_MAX_STEPS,
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
	$log->info('DSTM mode cleared for ' . $client->id);
	_notify($request, string('PLUGIN_AUDIOMUSEAI_DSTM_STOPPED'));
}

# ----- Server status / admin ------------------------------------------------

sub _statusActive {
	my $request = shift;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::active_tasks(
		sub { _statusFormat($request, shift, 'ACTIVE') },
		sub { _notifyError($request, shift) },
	);
}

sub _statusLast {
	my $request = shift;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::last_task(
		sub { _statusFormat($request, shift, 'LAST') },
		sub { _notifyError($request, shift) },
	);
}

sub _statusFormat {
	my ($request, $data, $label) = @_;
	$label ||= 'TASK';

	unless (ref($data) eq 'HASH' && %$data) {
		return _notifyLines($request, ["[$label] (no task)"]);
	}

	my $details = $data->{details} || {};
	$details = {} unless ref($details) eq 'HASH';

	my @lines = ("[$label]");
	push @lines, $details->{status_message} if $details->{status_message};

	my @hdr;
	push @hdr, "status: $data->{status}"  if defined $data->{status};
	push @hdr, "type: $data->{task_type}" if defined $data->{task_type};
	push @lines, join(' · ', @hdr) if @hdr;

	push @lines, "progress: $data->{progress}%"             if defined $data->{progress};
	push @lines, 'running: ' . _fmtDuration($data->{running_time_seconds})
		if defined $data->{running_time_seconds};
	push @lines, "task_id: $data->{task_id}"                if defined $data->{task_id};

	for my $k (qw(albums_skipped albums_to_process)) {
		push @lines, "$k: $details->{$k}"
			if defined $details->{$k} && !ref($details->{$k});
	}
	if (ref($details->{log}) eq 'ARRAY' && @{$details->{log}}) {
		push @lines, 'last log: ' . $details->{log}[-1];
	}
	push @lines, $details->{log_storage_info} if $details->{log_storage_info};

	_notifyLines($request, \@lines);
}

sub _runAnalysis {
	my $request = shift;
	$log->info('triggering /api/analysis/start');
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::start_analysis(
		sub { _notify($request, string('PLUGIN_AUDIOMUSEAI_STATUS_TRIGGERED')); },
		sub { _notifyError($request, shift); },
	);
}

sub _runClustering {
	my $request = shift;
	$log->info('triggering /api/clustering/start');
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::start_clustering(
		sub { _notify($request, string('PLUGIN_AUDIOMUSEAI_STATUS_TRIGGERED')); },
		sub { _notifyError($request, shift); },
	);
}

sub _openMap {
	my $request = shift;
	my $url = ($prefs->get('url') || '') . '/';
	_notifyLines($request, [
		string('PLUGIN_AUDIOMUSEAI_MENU_OPEN_MAP') . ':',
		$url,
	]);
}

sub _testResult {
	my $request = shift;
	my $val = $prefs->get('last_test_result') // '';
	$request->addResult('value', $val);
	$request->setStatusDone;
}

# ===========================================================================
# Helpers
# ===========================================================================

sub _trim {
	my $s = shift;
	return '' unless defined $s;
	$s =~ s/\A\s+//;
	$s =~ s/\s+\z//;
	return $s;
}

# Validate / normalize the URL pref. Strips trailing slashes, adds http://
# when no scheme is present, rejects nothing (we'd rather hit the API and
# surface its error than silently refuse to call).
sub _normalizeUrl {
	my $u = _trim(shift // '');
	return $u unless length $u;
	$u = "http://$u" unless $u =~ m{^https?://}i;
	$u =~ s{/+$}{};
	return $u;
}

sub _count {
	my $n = $prefs->get('default_count') // 25;
	$n = COUNT_MIN if $n < COUNT_MIN;
	$n = COUNT_MAX if $n > COUNT_MAX;
	return $n;
}

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

# Build a Jive menu of tappable tracks from an AudioMuse search-result list.
# Each item dispatches to $cmd with the track's id put into $idParamName.
# Optional $extraParams are merged into every item (e.g. start_id for findpath).
sub _tracksAsPickMenu {
	my ($tracks, $cmd, $idParamName, $extraParams) = @_;
	$extraParams ||= {};
	my @items;
	my $cap = MAX_PICK_RESULTS;
	for my $t (@$tracks) {
		last if @items >= $cap;
		my $tid = $t->{item_id} // $t->{id};
		next unless defined $tid && length $tid;
		my $title  = _trim($t->{title}  // '');
		my $author = _trim($t->{author} // $t->{album_artist} // '');
		my $label  = $title || '?';
		$label .= ' — ' . $author if length $author;
		push @items, {
			text    => $label,
			actions => {
				go => {
					cmd    => $cmd,
					player => 1,
					params => { %$extraParams, $idParamName => "$tid" },
				},
			},
			nextWindow => 'refresh',
		};
	}
	if (@$tracks > $cap) {
		push @items, {
			text => sprintf('… (%d more not shown)', @$tracks - $cap),
		};
	}
	return \@items;
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
	_emit($request, [{ text => $msg // '' }]);
}

sub _notifyLines {
	my ($request, $lines) = @_;
	$lines ||= [];
	$lines = ['No status returned.'] unless @$lines;
	_emit($request, [ map { { text => "$_" } } @$lines ]);
}

sub _notifyError {
	my ($request, $err) = @_;
	$err //= 'Unknown error';
	if ($err =~ /\b409\b/ || $err =~ /conflict/i) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_BUSY'));
	} elsif ($err =~ /\b503\b/ || $err =~ /unavailable/i) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_UNAVAILABLE'));
	} elsif ($err =~ /\b401\b|\b403\b/ || $err =~ /unauthor/i || $err =~ /forbidden/i) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_AUTH_FAIL'));
	} elsif ($err =~ /timeout/i) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_TIMEOUT'));
	} elsif ($err =~ /\b(?:5\d\d)\b/) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_SERVER_ERROR') . " ($err)");
	} else {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_GENERIC_ERROR') . " $err");
	}
}

sub _fmtDuration {
	my $sec = int(shift // 0);
	$sec = 0 if $sec < 0;
	my $h = int($sec / 3600);
	my $m = int(($sec % 3600) / 60);
	my $s = $sec % 60;
	return sprintf('%dh %02dm %02ds', $h, $m, $s) if $h;
	return sprintf('%dm %02ds', $m, $s)           if $m;
	return sprintf('%ds', $s);
}

sub _queueResults {
	my ($request, $client, $data, $loadFresh) = @_;
	unless (ref($data) eq 'ARRAY' && @$data) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
	}
	# Filter: defined, non-empty, and only digits (Lyrion track IDs are
	# always integers; anything else would crash playlistcontrol).
	my @ids = grep { defined && /\A\d+\z/ }
		map { $_->{item_id} // $_->{id} } @$data;
	unless (@ids) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
	}
	my $cmd = $loadFresh ? 'load' : 'add';
	$log->info(sprintf('queueing %d tracks (%s) on %s',
		scalar @ids, $cmd, $client->id));
	Slim::Control::Request::executeRequest(
		$client,
		['playlistcontrol', "cmd:$cmd", 'track_id:' . join(',', @ids)]
	);
	_notify($request, string('PLUGIN_AUDIOMUSEAI_QUEUED'));
}

# Subscriber: track newly playing songs and auto-extend if a DSTM mode is active.
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

	my $cb_ok = sub {
		my $data = shift;
		return unless ref($data) eq 'ARRAY' && @$data;
		my @ids = grep { defined && /\A\d+\z/ }
			map { $_->{item_id} // $_->{id} } @$data;
		return unless @ids;
		Slim::Control::Request::executeRequest(
			$client,
			['playlistcontrol', 'cmd:add', 'track_id:' . join(',', @ids)]
		);
	};
	my $cb_err = sub { $log->warn('DSTM extend failed: ' . (shift // 'unknown')) };

	if ($mode eq 'similar') {
		Plugins::AudioMuseAI::API::similar_tracks(
			$song->id, 10, $cb_ok, $cb_err);
	} elsif ($mode eq 'fingerprint') {
		Plugins::AudioMuseAI::API::sonic_fingerprint(10, $cb_ok, $cb_err);
	}
	# Note: alchemy mode is intentionally not auto-extended — alchemy's
	# meaning is "blend these tracks", not "stream of similar to the
	# current track", so re-extending it on every new-song event
	# wouldn't carry the user's intent forward.
}

1;
