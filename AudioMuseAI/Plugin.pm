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

# For looking up Lyrion track titles/artists in the alchemy display.
use Slim::Schema;
# Info-menu providers — these add an 'AudioMuse: similar...' option to
# Lyrion's standard artist/track/album browse, so users get all of
# Lyrion's native filter / letter-jump / pagination for free instead of
# a custom (and limited) picker inside the plugin menu.
use Slim::Menu::ArtistInfo;
use Slim::Menu::TrackInfo;
use Slim::Menu::AlbumInfo;

use constant {
	VERSION             => '0.2.10',
	HEALTHCHECK_DELAY   => 5,
	# Cap search-result menus to keep the UI navigable on hardware
	# controllers; AudioMuse can return hundreds of tracks for prolific
	# artists.
	MAX_PICK_RESULTS    => 50,
	# Default count clamped to this range to avoid tiny / huge requests.
	COUNT_MIN           => 5,
	COUNT_MAX           => 100,
	FINDPATH_MAX_STEPS  => 12,
	# Per-player ring buffer for recent CLAP/instant prompts.
	RECENT_PROMPTS_MAX  => 5,
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
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_instant'],
		[1, 1, 1, \&_menuInstant]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_similar_song'],
		[1, 1, 1, \&_menuSimilarSong]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_similar_artist'],
		[1, 1, 1, \&_menuSimilarArtist]);
	# Filter the Lyrion artist list by a substring; used by the text-input
	# entries in similar_song / similar_artist for actual autocomplete.
	Slim::Control::Request::addDispatch(['audiomuseai', 'filter_artists'],
		[1, 1, 1, \&_filterArtists]);

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

	# Save current queue
	Slim::Control::Request::addDispatch(['audiomuseai', 'save_playlist'],
		[1, 1, 1, \&_savePlaylist]);

	# 'AudioMuse: alchemy from this album' — invoked from the album-info
	# context menu in Lyrion's standard browse.
	Slim::Control::Request::addDispatch(['audiomuseai', 'alchemy_album'],
		[1, 1, 1, \&_alchemyAlbum]);

	# Instant playlist with recent prompts
	Slim::Control::Request::addDispatch(['audiomuseai', 'similar_artist_with_artist'],
		[1, 1, 1, \&_similarArtistWithArtist]);

	# Settings-page AJAX support: report the latest connection-test result
	# as a JSON-RPC query so the page can poll without reloading.
	Slim::Control::Request::addDispatch(['audiomuseai', 'test_result'],
		[0, 1, 1, \&_testResult]);

	# Live server-status snapshot for the settings page (structured fields,
	# not a Jive menu — different from menu_status / status_active).
	Slim::Control::Request::addDispatch(['audiomuseai', 'server_status'],
		[0, 1, 1, \&_serverStatus]);

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

	# Hook into Lyrion's standard browse so users can pick artists/tracks
	# via the native UI (with all its filter / letter-jump goodness).
	Slim::Menu::ArtistInfo->registerInfoProvider(
		audiomuseaiSimilarArtist => (
			after => 'top',
			func  => \&_artistInfoSimilar,
		),
	);
	Slim::Menu::TrackInfo->registerInfoProvider(
		audiomuseaiSimilarTrack => (
			after => 'top',
			func  => \&_trackInfoSimilar,
		),
	);
	Slim::Menu::AlbumInfo->registerInfoProvider(
		audiomuseaiAlbumAlchemy => (
			after => 'top',
			func  => \&_albumInfoAlchemy,
		),
	);

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

# ---------------------------------------------------------------------------
# Info-menu providers — surfaced from Lyrion's standard artist / track /
# album browse. Each returns a redirect-style menu item that, when tapped,
# fires our own dispatcher with the relevant context (artist name / track
# id) already filled in. No typing or picker required because the user
# was already on the right item in Lyrion's native UI.
# ---------------------------------------------------------------------------

sub _artistInfoSimilar {
	my ($client, $url, $artist) = @_;
	return unless $artist;
	my $name = ref($artist) ? $artist->name : "$artist";
	return unless defined $name && length $name;
	return {
		type => 'redirect',
		name => string('PLUGIN_AUDIOMUSEAI_INFO_SIMILAR_ARTIST'),
		jive => {
			actions => {
				go => {
					cmd    => ['audiomuseai', 'similar_artist'],
					player => 1,
					params => { artist => "$name" },
				},
			},
		},
	};
}

sub _trackInfoSimilar {
	my ($client, $url, $track) = @_;
	return unless $track;
	my $tid = ref($track) ? $track->id : "$track";
	return unless defined $tid && length $tid;
	return {
		type => 'redirect',
		name => string('PLUGIN_AUDIOMUSEAI_INFO_SIMILAR_TRACK'),
		jive => {
			actions => {
				go => {
					cmd    => ['audiomuseai', 'similar_track'],
					player => 1,
					params => { track_id => "$tid" },
				},
			},
		},
	};
}

sub _albumInfoAlchemy {
	my ($client, $url, $album) = @_;
	return unless $album;
	my $aid = ref($album) ? $album->id : "$album";
	return unless defined $aid && length $aid;
	# We don't have a direct AudioMuse "similar to album" endpoint, but
	# we can approximate by adding all of the album's tracks to the
	# alchemy ADD list and triggering a generate. That gives a sonic
	# blend that "smells like" the album.
	return {
		type => 'redirect',
		name => string('PLUGIN_AUDIOMUSEAI_INFO_ALCHEMY_FROM_ALBUM'),
		jive => {
			actions => {
				go => {
					cmd    => ['audiomuseai', 'alchemy_album'],
					player => 1,
					params => { album_id => "$aid" },
				},
			},
		},
	};
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

	# Status hint at the top of the submenu — uses the cached
	# active_tasks state if available so menu rendering doesn't wait
	# on the network. Fires off a background fetch to refresh the
	# cache for the next invocation.
	my $cached = Plugins::AudioMuseAI::API::peek_active_tasks();
	if (my $hdr = _statusHeaderItem($cached)) {
		push @menu, $hdr;
	}
	# Prime the cache (fire-and-forget; ignore the result).
	Plugins::AudioMuseAI::API::active_tasks(sub {}, sub {});

	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_SIMILAR_NOW',
		['audiomuseai', 'similar_now'], 1);

	# Both Similar-to-song and Similar-to-artist now open submenus that
	# combine a 'Type custom...' text input with a pickable list of
	# artists from the user's Lyrion library, so they don't have to
	# type if their target is already in the library.
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_SIMILAR_SONG',
		['audiomuseai', 'menu_similar_song']);

	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_SIMILAR_ARTIST',
		['audiomuseai', 'menu_similar_artist']);

	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_FINGERPRINT',
		['audiomuseai', 'sonic_fp'], 1);

	# Instant Playlist is now a submenu so we can offer recent prompts
	# (per player) alongside a fresh-prompt text input.
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_INSTANT',
		['audiomuseai', 'menu_instant']);

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

	# Save current Lyrion queue under a user-supplied name. Doesn't go
	# through AudioMuse — it just calls Lyrion's playlist save command.
	push @menu, _textInputItem('PLUGIN_AUDIOMUSEAI_MENU_SAVE_PLAYLIST',
		'PLUGIN_AUDIOMUSEAI_PROMPT_PLAYLIST_NAME',
		['audiomuseai', 'save_playlist'], 'name');

	# Open Music Map: weblink-bearing item with action.go fallback.
	my $url = ($prefs->get('url') || '') . '/';
	push @menu, {
		text    => string('PLUGIN_AUDIOMUSEAI_MENU_OPEN_MAP'),
		weblink => $url,
		actions => {
			go => {
				cmd    => ['audiomuseai', 'open_map'],
				player => 0,
			},
		},
	};

	_emit($request, \@menu);
}

# Build the status header item from cached active_tasks data. Returns
# undef when there's nothing useful to show (no cache hit, idle server,
# unauthenticated). Returns a non-tappable text item otherwise.
sub _statusHeaderItem {
	my $data = shift;
	return undef unless ref($data) eq 'HASH' && %$data;
	my $details = $data->{details};
	$details = {} unless ref($details) eq 'HASH';

	my $state = $data->{status} // '';
	# Only show the header when something interesting is happening.
	return undef unless $state =~ /^(PROGRESS|STARTED|PENDING)$/i;

	my $type     = $data->{task_type}             // 'task';
	my $progress = $data->{progress};
	my $bits = "* $type";
	$bits .= " - $progress%" if defined $progress && $progress ne '';
	if (defined $data->{running_time_seconds} && $data->{running_time_seconds}) {
		$bits .= ' (' . _fmtDuration($data->{running_time_seconds}) . ')';
	}
	return { text => $bits };
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

sub _menuSimilarSong {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	# A single text-input that filters the Lyrion library against the
	# typed substring and presents matching artists as a pick list. The
	# `target` param tells _filterArtists which downstream dispatcher
	# to wire each match item to.
	_emit($request, [
		_artistFilterInput('similar_song_search'),
	]);
}

sub _menuSimilarArtist {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	_emit($request, [
		_artistFilterInput('similar_artist'),
	]);
}

# Filter the Lyrion artist list by a typed substring and present matches.
# The chosen artist (or the typed text as-is) is then dispatched to
# `audiomuseai <target>` with `artist:<name>`.
sub _filterArtists {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $query   = _trim($request->getParam('query') // '');
	my $target  = $request->getParam('target') || 'similar_artist';
	# Sanitise target: only allow our own dispatchers.
	$target = 'similar_artist'
		unless grep { $_ eq $target } qw(similar_artist similar_song_search);
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT'))
		unless length $query;

	my $matches = _libraryArtists(MAX_PICK_RESULTS, $query);
	my @items;

	# Always offer "use as typed" first — the user might be searching
	# for an artist that isn't (yet) in the local Lyrion library but
	# exists in AudioMuse. Also covers the no-matches case.
	push @items, {
		text    => sprintf(string('PLUGIN_AUDIOMUSEAI_USE_AS_TYPED'), $query),
		actions => {
			go => {
				cmd    => ['audiomuseai', $target],
				player => 1,
				params => { artist => "$query" },
			},
		},
		nextWindow => 'refresh',
	};

	for my $name (@$matches) {
		next if lc($name) eq lc($query);  # already at the top
		push @items, _libraryArtistItem($name,
			['audiomuseai', $target]);
	}

	_emit($request, \@items);
}

sub _artistFilterInput {
	my $target = shift;
	return {
		text  => string('PLUGIN_AUDIOMUSEAI_PICK_TYPE_ARTIST'),
		input => {
			len  => 1,
			help => { text => string('PLUGIN_AUDIOMUSEAI_PROMPT_ARTIST') },
			softbutton1 => 'Insert',
			softbutton2 => 'Delete',
		},
		actions => {
			go => {
				cmd    => ['audiomuseai', 'filter_artists'],
				player => 1,
				params => {
					query  => '__TAGGEDINPUT__',
					target => $target,
				},
			},
		},
		nextWindow => 'refresh',
	};
}

# Returns up to $limit artist names from Lyrion's library matching
# $search (substring). When $search is empty/undef returns the first
# $limit alphabetically. Uses Lyrion's built-in 'artists' CLI which is
# in-process, indexed, and supports a `search:` filter natively.
sub _libraryArtists {
	my ($limit, $search) = @_;
	$limit //= MAX_PICK_RESULTS;
	my @cmd = ('artists', '0', "$limit");
	push @cmd, "search:$search"
		if defined $search && length $search;

	my @out;
	eval {
		my $req = Slim::Control::Request::executeRequest(undef, \@cmd);
		return unless $req;
		my $loop = $req->getResult('artists_loop') || [];
		for my $a (@$loop) {
			my $name = $a->{artist} // $a->{name};
			next unless defined $name && length $name;
			push @out, $name;
		}
	};
	$log->warn("library artist lookup failed: $@") if $@;
	return \@out;
}

sub _libraryArtistItem {
	my ($artistName, $cmd) = @_;
	return {
		text    => _safeText($artistName),
		actions => {
			go => {
				cmd    => $cmd,
				player => 1,
				params => { artist => "$artistName" },
			},
		},
		nextWindow => 'refresh',
	};
}

sub _menuInstant {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;

	my @menu;
	push @menu, _textInputItem('PLUGIN_AUDIOMUSEAI_INSTANT_NEW',
		'PLUGIN_AUDIOMUSEAI_PROMPT_INSTANT',
		['audiomuseai', 'instant'], 'prompt');

	my $recents = $prefs->client($client)->get('recent_prompts');
	$recents = [] unless ref($recents) eq 'ARRAY';
	for my $p (@$recents) {
		next unless defined $p && length $p;
		push @menu, {
			text    => $p,
			actions => {
				go => {
					cmd    => ['audiomuseai', 'instant'],
					player => 1,
					params => { prompt => $p },
				},
			},
			nextWindow => 'refresh',
		};
	}
	_emit($request, \@menu);
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
		$song->id, _count($client),
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
		$tid, _count($client),
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
		$artist, 10,
		sub {
			my $data = shift;
			my @arts = ref($data) eq 'ARRAY' ? @$data : ();
			unless (@arts) {
				return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
			}
			# Render a pick list of similar artists. User taps one to
			# queue tracks by that artist (via search_tracks).
			my @items;
			for my $a (@arts) {
				my $name = _safeText($a->{artist} // $a->{name} // '');
				next unless length $name;
				my $sub = '';
				if (defined $a->{distance}) {
					$sub = sprintf(' (sim %.2f)', $a->{distance});
				}
				push @items, {
					text    => $name . $sub,
					actions => {
						go => {
							cmd    => ['audiomuseai', 'similar_artist_with_artist'],
							player => 1,
							params => { artist => "$name" },
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

sub _similarArtistWithArtist {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $artist  = _trim($request->getParam('artist') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $artist;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::search_tracks(
		$artist,
		sub { _queueResults($request, $client, shift, 0) },
		sub { _notifyError($request, shift) },
	);
}

sub _sonicFingerprint {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::sonic_fingerprint(
		_count($client),
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
}

sub _instantPlaylist {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $prompt  = _trim($request->getParam('prompt') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $prompt;
	_recordRecentPrompt($client, $prompt);
	$log->info("instant playlist: $prompt");
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::clap_search(
		$prompt, _count($client),
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
}

sub _recordRecentPrompt {
	my ($client, $prompt) = @_;
	return unless $client && defined $prompt && length $prompt;
	my $list = $prefs->client($client)->get('recent_prompts');
	$list = [] unless ref($list) eq 'ARRAY';
	# Move-to-front: remove existing instance, prepend new one.
	@$list = grep { $_ ne $prompt } @$list;
	unshift @$list, $prompt;
	@$list = @$list[0 .. RECENT_PROMPTS_MAX - 1] if @$list > RECENT_PROMPTS_MAX;
	$prefs->client($client)->set('recent_prompts', $list);
}

sub _moodPlaylist {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $prompt  = _trim($request->getParam('prompt') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $prompt;
	$log->info("mood playlist: $prompt");
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::clap_search(
		$prompt, _count($client),
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

	my @lines;
	if (@$a) {
		push @lines, sprintf('ADD (%d):', scalar @$a);
		push @lines, map { '  + ' . _trackLabel($_) } @$a;
	}
	if (@$s) {
		push @lines, sprintf('SUBTRACT (%d):', scalar @$s);
		push @lines, map { '  - ' . _trackLabel($_) } @$s;
	}
	_notifyLines($request, \@lines);
}

# Resolve a Lyrion track ID to "Title - Artist". Falls back to the
# bare ID if Lyrion can't find the track (e.g. ID stored from an
# older library scan).
sub _trackLabel {
	my $id = shift // return '';
	my $track = eval { Slim::Schema->find('Track', $id) };
	return "id:$id" unless $track;
	my $title  = _safeText($track->title       // '');
	my $artist = _safeText($track->artistName  // '');
	return $title || "id:$id" unless length $artist;
	return ($title || '?') . ' - ' . $artist;
}

sub _alchemyReset {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	$prefs->client($client)->set('alchemy_add', []);
	$prefs->client($client)->set('alchemy_sub', []);
	_notify($request, string('PLUGIN_AUDIOMUSEAI_ALCHEMY_CLEARED'));
}

sub _alchemyAlbum {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $aid     = $request->getParam('album_id');
	return $request->setStatusBadParams unless defined $aid && length $aid;

	my @track_ids;
	eval {
		my $album = Slim::Schema->find('Album', $aid);
		return unless $album;
		my $rs = $album->tracks;
		while (my $t = $rs->next) {
			push @track_ids, "" . $t->id if $t && defined $t->id;
		}
	};
	if ($@) {
		$log->warn("alchemy_album lookup failed for $aid: $@");
	}
	unless (@track_ids) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
	}

	# Fire AudioMuse alchemy with the full album as ADD seeds. Don't
	# clobber the player's existing ADD/SUB state — alchemy_album is a
	# one-shot operation with its own seed set.
	$log->info(sprintf('alchemy_album: %d tracks from album %s', scalar @track_ids, $aid));
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::alchemy(
		\@track_ids, [], _count($client),
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
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
		$a, $s, _count($client),
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

sub _savePlaylist {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $name    = _trim($request->getParam('name') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $name;

	# Reject control / path-injecting characters; Lyrion accepts most
	# strings but it's polite to disallow ones that would be ugly on
	# the file system.
	$name =~ s/[\x00-\x1f\x7f]//g;
	$name =~ s{[/\\]}{-}g;

	my $count = Slim::Player::Playlist::count($client);
	if (!$count) {
		return _notify($request,
			string('PLUGIN_AUDIOMUSEAI_PLAYLIST_EMPTY'));
	}

	$log->info("saving Lyrion queue ($count tracks) as playlist '$name' on " . $client->id);
	Slim::Control::Request::executeRequest(
		$client,
		['playlist', 'save', $name]
	);
	_notify($request, sprintf('%s (%d tracks): %s',
		string('PLUGIN_AUDIOMUSEAI_PLAYLIST_SAVED'), $count, $name));
}

sub _testResult {
	my $request = shift;
	my $val = $prefs->get('last_test_result') // '';
	$request->addResult('value', $val);
	$request->setStatusDone;
}

sub _serverStatus {
	my $request = shift;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::active_tasks(
		sub {
			my $data = shift;
			my $details = (ref($data) eq 'HASH' ? $data->{details} : undef) || {};
			$details = {} unless ref($details) eq 'HASH';

			$request->addResult('reachable',      1);
			$request->addResult('status',         $data->{status}              // '');
			$request->addResult('task_type',      $data->{task_type}           // '');
			$request->addResult('progress',
				defined $data->{progress} ? "$data->{progress}" : '');
			$request->addResult('running_seconds',
				defined $data->{running_time_seconds}
					? int($data->{running_time_seconds}) : 0);
			$request->addResult('task_id',        $data->{task_id}             // '');
			$request->addResult('status_message', $details->{status_message}   // '');
			$request->addResult('albums_skipped',
				defined $details->{albums_skipped} ? "$details->{albums_skipped}" : '');
			$request->addResult('albums_to_process',
				defined $details->{albums_to_process}
					? "$details->{albums_to_process}" : '');
			$request->addResult('last_log',
				(ref($details->{log}) eq 'ARRAY' && @{$details->{log}})
					? $details->{log}[-1] : '');
			$request->addResult('url', $prefs->get('url') // '');
			$request->setStatusDone;
		},
		sub {
			my $err = shift // 'unknown';
			$request->addResult('reachable', 0);
			$request->addResult('error',     $err);
			$request->addResult('url',       $prefs->get('url') // '');
			$request->setStatusDone;
		},
	);
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

# Make a string safe to put into a Jive menu item's `text` field across
# different Lyrion skins. Some renderers treat the text as HTML; some as
# plain text. We:
#   - decode pre-existing HTML entities (in case upstream double-encoded);
#   - strip any HTML tags;
#   - replace stray ampersands with the unicode ampersand variant so we
#     don't leave half-entities that an HTML renderer might mangle;
#   - normalise whitespace.
sub _safeText {
	my $s = shift;
	return '' unless defined $s;
	# Decode common entities.
	$s =~ s/&amp;/&/g;
	$s =~ s/&lt;/</g;
	$s =~ s/&gt;/>/g;
	$s =~ s/&quot;/"/g;
	$s =~ s/&#39;|&apos;/'/g;
	# Numeric entities (decimal and hex).
	$s =~ s/&#(\d+);/chr($1)/ge;
	$s =~ s/&#x([0-9a-fA-F]+);/chr(hex($1))/ge;
	# Strip any HTML tags that snuck through.
	$s =~ s/<[^>]+>//g;
	# Collapse whitespace and trim.
	$s =~ s/\s+/ /g;
	$s = _trim($s);
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
	my $client = shift;
	my $n;
	# Prefer per-player override if explicitly set; else fall back to
	# the global default. Per-player can be set via:
	#   audiomuseai prefclient <playerid> default_count <n>
	# (no UI yet — runs through Lyrion's standard pref CLI command.)
	if ($client) {
		my $v = $prefs->client($client)->get('default_count');
		$n = $v if defined $v && $v ne '';
	}
	$n //= $prefs->get('default_count') // 25;
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
		# Use ASCII separator and decode any HTML entities the upstream
		# API may have applied — some Lyrion skins HTML-render menu text,
		# and an unescaped & or stray entity can show as raw markup.
		my $label  = _safeText($title || '?');
		if (length $author) {
			$label .= ' - ' . _safeText($author);
		}
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

	# For "busy" / "unavailable" errors, fetch live server state so the
	# user sees what AudioMuse is *actually* doing rather than a
	# go-look-at-the-status-page nudge. The response is async-driven via
	# active_tasks and renders alongside the human-readable error.
	if ($err =~ /\b409\b/ || $err =~ /conflict/i) {
		return _notifyErrorWithStatus($request,
			string('PLUGIN_AUDIOMUSEAI_BUSY'));
	}
	if ($err =~ /\b503\b/ || $err =~ /unavailable/i) {
		return _notifyErrorWithStatus($request,
			string('PLUGIN_AUDIOMUSEAI_UNAVAILABLE'));
	}

	if ($err =~ /\b401\b|\b403\b/ || $err =~ /unauthor/i || $err =~ /forbidden/i) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_AUTH_FAIL'));
	} elsif ($err =~ /timeout/i) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_TIMEOUT'));
	} elsif ($err =~ /\b(?:5\d\d)\b/) {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_SERVER_ERROR') . " ($err)");
	} else {
		_notify($request, string('PLUGIN_AUDIOMUSEAI_GENERIC_ERROR') . " $err");
	}
}

sub _notifyErrorWithStatus {
	my ($request, $headline) = @_;
	# active_tasks is cheap (often cached 5s) so this is OK to fire
	# from inside an error path.
	Plugins::AudioMuseAI::API::active_tasks(
		sub {
			my $data    = shift;
			my $details = (ref($data) eq 'HASH' ? $data->{details} : undef) || {};
			my @lines = ($headline);
			if (ref($data) eq 'HASH' && %$data) {
				push @lines, $details->{status_message}
					if $details->{status_message};
				my @hdr;
				push @hdr, "state: $data->{status}"  if defined $data->{status};
				push @hdr, "type: $data->{task_type}" if defined $data->{task_type};
				push @lines, join(' · ', @hdr) if @hdr;
				push @lines, "progress: $data->{progress}%"
					if defined $data->{progress} && $data->{progress} ne '';
				push @lines, 'running: ' . _fmtDuration($data->{running_time_seconds})
					if defined $data->{running_time_seconds}
					&& $data->{running_time_seconds};
			}
			_notifyLines($request, \@lines);
		},
		sub {
			# Status fetch failed too — just show the original headline.
			_notify($request, $headline);
		},
	);
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
	# Compact summary: "Queued 25 tracks (replace queue)" / "...append".
	my $verb = $loadFresh ? 'replaced queue' : 'appended to queue';
	_notify($request, sprintf('%s — %d tracks %s.',
		string('PLUGIN_AUDIOMUSEAI_QUEUED'), scalar @ids, $verb));
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
