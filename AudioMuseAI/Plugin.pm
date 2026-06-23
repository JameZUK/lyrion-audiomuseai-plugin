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
	VERSION             => '0.3.1',
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
	# Page size for paginated artist browse — kept small so simpler
	# controllers (e.g. Squeezer on Android) don't choke on long
	# responses. Server-side pagination handles deeper navigation.
	BROWSE_PAGE_SIZE    => 50,
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
		url                  => 'http://localhost:8000',
		token                => '',
		default_count        => 25,
		dstm_enabled         => 0,
		# Auto-name strategy for 'Save current queue as playlist'.
		# One of: timestamp | first_track | artist_mix | mood_tagged | prompt.
		save_playlist_format => 'timestamp',
		# Auto-save the result of an Instant Playlist (text prompt) as
		# a Lyrion playlist named after the prompt.
		auto_save_instant    => 0,
		# Auto-save the result of a Mood preset as a Lyrion playlist
		# named after the mood label.
		auto_save_mood       => 0,
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
	# These are pure menu builders (list items only). They were marked
	# needsClient=1 originally for menu_instant which uses per-player
	# recent-prompts. But the parent menu items pass player=>0, and
	# strict controllers (Squeezer) honour that — the dispatcher then
	# rejects with bad-params and the menu auto-dismisses. Set
	# needsClient=0 and have the builders degrade gracefully when no
	# client is in scope.
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_instant'],
		[0, 1, 1, \&_menuInstant]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_similar_song'],
		[0, 1, 1, \&_menuSimilarSong]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_similar_artist'],
		[0, 1, 1, \&_menuSimilarArtist]);
	# Filter the Lyrion artist list by a substring; used by the text-input
	# entries in similar_song / similar_artist for actual autocomplete.
	Slim::Control::Request::addDispatch(['audiomuseai', 'filter_artists'],
		[1, 1, 1, \&_filterArtists]);
	# Tap-only paginated artist browse (no text input required —
	# necessary for controllers like Squeezer that don't render the
	# Jive 'input' field at all).
	Slim::Control::Request::addDispatch(['audiomuseai', 'browse_artists'],
		[1, 1, 1, \&_browseArtists]);

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
	# Lyrics-based discovery: free-text query embedded server-side and
	# matched against the lyrics voyager index. Same UX as Instant.
	Slim::Control::Request::addDispatch(['audiomuseai', 'lyrics_search'],
		[1, 1, 1, \&_lyricsSearch]);

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
	# Library-coverage snapshot — drives the new 'Library' rows on the
	# settings status panel.
	Slim::Control::Request::addDispatch(['audiomuseai', 'library_summary'],
		[0, 1, 1, \&_librarySummary]);
	# Cancel the currently running AudioMuse task. Looks up the active
	# task ID via active_tasks then POSTs /api/cancel/<id>.
	Slim::Control::Request::addDispatch(['audiomuseai', 'cancel_active'],
		[0, 1, 1, \&_cancelActive]);
	# Popular CLAP search prompts (community-aggregated). Submenu of
	# tappable preset queries — pure discovery / inspiration.
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_top_queries'],
		[0, 1, 1, \&_menuTopQueries]);
	# LLM-driven playlist via /chat/api/chatPlaylist — uses whatever
	# AI_MODEL_PROVIDER (and corresponding model / key) the user has
	# configured on their AudioMuse server. The plugin is provider-
	# agnostic; it just submits userInput and renders the response.
	Slim::Control::Request::addDispatch(['audiomuseai', 'chat_playlist'],
		[1, 1, 1, \&_chatPlaylist]);

	# Top-level menu under My Music. The 'icon' field is honoured by
	# Material, default web UI, iPeng, and Squeezer (where it shows
	# next to the menu entry under My Music).
	my @items = ({
		text    => string('PLUGIN_AUDIOMUSEAI'),
		id      => 'pluginAudioMuseAI',
		weight  => 80,
		node    => 'myMusic',
		icon    => 'plugins/AudioMuseAI/html/images/icon.png',
		actions => {
			go => {
				cmd    => ['audiomuseai', 'menu'],
				player => 0,
			},
		},
		window  => { menustyle => 'text' },
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
					player => 0,
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
					player => 0,
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
					player => 0,
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
			# Pre-warm the CLAP text-search model so the first Instant
			# Playlist / Mood / Top Queries tap doesn't pay the model
			# load cost (typically several seconds). Fire-and-forget;
			# 503 if CLAP is disabled is fine — we just log debug.
			Plugins::AudioMuseAI::API::clap_warmup(
				sub { $log->debug('CLAP warmup OK'); },
				sub { $log->debug('CLAP warmup skipped: ' . (shift // '?')); },
			);
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
	# Only prime the cache when it's empty — peek already returned
	# fresh data otherwise (5s TTL). Avoids a redundant HTTP round-trip
	# on every menu open.
	unless ($cached) {
		Plugins::AudioMuseAI::API::active_tasks(sub {}, sub {});
	}

	# --- Tier 1: one-tap actions, most common ---
	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_SIMILAR_NOW',
		['audiomuseai', 'similar_now'], 1);
	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_FINGERPRINT',
		['audiomuseai', 'sonic_fp'], 1);
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_MOOD',
		['audiomuseai', 'menu_mood']);
	# Community-popular CLAP search prompts — sits right after Mood
	# because it's the same kind of "tap a phrase, get a playlist" UX.
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_TOP_QUERIES',
		['audiomuseai', 'menu_top_queries']);

	# --- Tier 2: tap-driven browse / drill-down ---
	# Direct dispatch to browse_artists — see comment in v0.2.16 about
	# why we don't wrap in a single-item submenu (Squeezer auto-dismiss).
	push @menu, _navItem('PLUGIN_AUDIOMUSEAI_MENU_SIMILAR_ARTIST',
		['audiomuseai', 'browse_artists'],
		{ target => 'similar_artist', start => 0 });
	push @menu, _navItem('PLUGIN_AUDIOMUSEAI_MENU_SIMILAR_SONG',
		['audiomuseai', 'browse_artists'],
		{ target => 'similar_song_search', start => 0 });

	# --- Tier 3: sessions / advanced ---
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_DYNAMIC',
		['audiomuseai', 'menu_dynamic']);
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_ALCHEMY',
		['audiomuseai', 'menu_alchemy']);

	# --- Tier 4: tools (tap-only) ---
	# Save current queue: auto-named with timestamp, no text input
	# required. Squeezer-friendly. Users can rename via Lyrion's standard
	# playlist UI later if desired.
	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_SAVE_PLAYLIST',
		['audiomuseai', 'save_playlist'], 1);

	# --- Tier 5: text-input required (web UI / Material only) ---
	# Squeezer skips items with `input` blocks cleanly — they just don't
	# render. Suffix in the label warns users that typing is required.
	push @menu, _textInputItem('PLUGIN_AUDIOMUSEAI_MENU_INSTANT',
		'PLUGIN_AUDIOMUSEAI_PROMPT_INSTANT',
		['audiomuseai', 'instant'], 'prompt');
	# LLM-driven version of the same idea — different backend (server-
	# configured AI provider) but same UX (type a prompt, get a queue).
	push @menu, _textInputItem('PLUGIN_AUDIOMUSEAI_MENU_CHAT',
		'PLUGIN_AUDIOMUSEAI_PROMPT_CHAT',
		['audiomuseai', 'chat_playlist'], 'prompt');
	# Lyrics-text search — matches the user's phrase against the
	# AudioMuse lyrics voyager index (e5-base-v2 embeddings). Distinct
	# from CLAP (which matches audio embeddings) and chat (LLM→SQL).
	push @menu, _textInputItem('PLUGIN_AUDIOMUSEAI_MENU_LYRICS',
		'PLUGIN_AUDIOMUSEAI_PROMPT_LYRICS',
		['audiomuseai', 'lyrics_search'], 'prompt');
	# findpath_search returns a track-pick menu (not a notification),
	# so it should NOT have nextWindow:refresh — that would close the
	# pushed picker.
	push @menu, _textInputItem('PLUGIN_AUDIOMUSEAI_MENU_FINDPATH',
		'PLUGIN_AUDIOMUSEAI_FINDPATH_PROMPT',
		['audiomuseai', 'findpath_search'], 'artist',
		{ push => 1 });

	# --- Tier 6: status / link-out ---
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_STATUS',
		['audiomuseai', 'menu_status']);

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
		my $label = string($key);
		push @menu, {
			text    => $label,
			actions => {
				go => {
					cmd    => ['audiomuseai', 'mood'],
					player => 0,
					# mood_label is a human-friendly tag passed alongside
					# the CLAP prompt; used for save_playlist_format=
					# mood_tagged and for auto-save naming.
					params => { prompt => $prompt, mood_label => $label },
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
			['audiomuseai', 'findpath_search'], 'artist',
			{ push => 1 }),
	]);
}

sub _menuDynamic {
	my $request = shift;
	my $client  = $request->client;
	my $active  = $client ? ($prefs->client($client)->get('dstm_active') // '') : '';

	# Prefix the currently-active mode with a tick so the user can see
	# what's running and find 'Stop auto-extend' easily. Per-player.
	my $tick = '✓ ';
	my $sim_label = string('PLUGIN_AUDIOMUSEAI_DYNAMIC_SIMILAR');
	my $fp_label  = string('PLUGIN_AUDIOMUSEAI_DYNAMIC_FINGERPRINT');
	$sim_label = $tick . $sim_label if $active eq 'similar';
	$fp_label  = $tick . $fp_label  if $active eq 'fingerprint';

	_emit($request, [
		{
			text    => $sim_label,
			actions => { go => { cmd => ['audiomuseai', 'dyn_similar'], player => 0 } },
			nextWindow => 'refresh',
		},
		{
			text    => $fp_label,
			actions => { go => { cmd => ['audiomuseai', 'dyn_fingerprint'], player => 0 } },
			nextWindow => 'refresh',
		},
		_actionItem('PLUGIN_AUDIOMUSEAI_DYNAMIC_STOP',
			['audiomuseai', 'dyn_stop']),
	]);
}

sub _menuSimilarSong {
	my $request = shift;
	$log->info('menu_similar_song reached -> delegating to browse_artists '
		. '(target=similar_song_search)');
	# Defensive: Squeezer caches My Music menu structure aggressively.
	# Even after we collapsed the top-menu items in v0.2.16 to dispatch
	# straight to browse_artists, cached clients still call the old
	# wrapper. So make the wrapper do the same thing as the new
	# direct dispatch — single source of truth, works for cached and
	# fresh clients alike.
	$request->addParam('target', 'similar_song_search');
	$request->addParam('start',  '0');
	return _browseArtists($request);
}

sub _menuSimilarArtist {
	my $request = shift;
	$log->info('menu_similar_artist reached -> delegating to browse_artists '
		. '(target=similar_artist)');
	$request->addParam('target', 'similar_artist');
	$request->addParam('start',  '0');
	return _browseArtists($request);
}

# Paginated artist browse. Re-enters itself with start += BROWSE_PAGE_SIZE
# via a 'More...' item at the bottom. We also set count/offset so
# controllers that honour Jive's native pagination (Material, default web
# UI) page server-side as the user scrolls. Squeezer ignores those but
# the static 'More...' item works.
sub _browseArtists {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $start   = int($request->getParam('start') // 0);
	$start = 0 if $start < 0;
	my $target  = $request->getParam('target') || 'similar_artist';
	$log->info("browse_artists reached: target=$target start=$start "
		. 'client=' . $client->id);
	$target = 'similar_artist'
		unless grep { $_ eq $target } qw(similar_artist similar_song_search);

	my $page = BROWSE_PAGE_SIZE;
	my @items;
	my $total = 0;

	# Non-actionable header item — only on the first page — explains the
	# drill-down flow to users who tap 'Similar to song' / 'Similar to
	# artist' expecting an immediate result list. Items without an
	# 'actions' block render as a non-tappable label (or grayed-out
	# disabled item, depending on controller).
	if ($start == 0) {
		my $hint_key = $target eq 'similar_song_search'
			? 'PLUGIN_AUDIOMUSEAI_HINT_PICK_FOR_SONG'
			: 'PLUGIN_AUDIOMUSEAI_HINT_PICK_FOR_ARTIST';
		push @items, { text => string($hint_key) };
	}

	eval {
		my $req = Slim::Control::Request::executeRequest(undef,
			['artists', "$start", "$page"]);
		return unless $req;
		$total = $req->getResult('count') // 0;
		my $loop = $req->getResult('artists_loop') || [];
		for my $a (@$loop) {
			my $name = $a->{artist} // $a->{name};
			next unless defined $name && length $name;
			push @items, _libraryArtistItem($name,
				['audiomuseai', $target]);
		}
	};
	$log->warn("browse_artists failed at start=$start: $@") if $@;

	# 'More...' tail item if there are further pages. Static so it
	# works even in controllers that don't honour server-side
	# pagination metadata.
	if ($total > $start + scalar(@items)) {
		my $next = $start + scalar(@items);
		push @items, {
			text    => string('PLUGIN_AUDIOMUSEAI_MORE'),
			actions => {
				go => {
					cmd    => ['audiomuseai', 'browse_artists'],
					player => 0,
					params => { target => $target, start => $next },
				},
			},
		};
	}

	if (!@items) {
		push @items, { text => string('PLUGIN_AUDIOMUSEAI_NO_RESULTS') };
	}

	_emit($request, \@items, 'PLUGIN_AUDIOMUSEAI_PICK_BROWSE_LIBRARY');
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
	# No nextWindow: dispatch returns a NEW menu (similar_* picker).
	push @items, {
		text    => sprintf(string('PLUGIN_AUDIOMUSEAI_USE_AS_TYPED'), $query),
		actions => {
			go => {
				cmd    => ['audiomuseai', $target],
				player => 0,
				params => { artist => "$query" },
			},
		},
	};

	for my $name (@$matches) {
		next if lc($name) eq lc($query);  # already at the top
		push @items, _libraryArtistItem($name,
			['audiomuseai', $target]);
	}

	_emit($request, \@items);
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
	# NOTE: no `nextWindow => 'refresh'` here. Tapping an artist
	# dispatches to similar_artist or similar_song_search, which return
	# ANOTHER menu (a picker). Squeezer pushes the picker as a new
	# activity, but if the originating item also has `refresh` the
	# parent activity refreshes — which closes the just-pushed picker.
	# Result: flash and revert. Default (no nextWindow) lets the new
	# menu push and stay.
	return {
		text    => _safeText($artistName),
		actions => {
			go => {
				cmd    => $cmd,
				player => 0,
				params => { artist => "$artistName" },
			},
		},
	};
}

sub _menuInstant {
	my $request = shift;
	my $client  = $request->client;
	$log->info('menu_instant reached (client='
		. ($client ? $client->id : 'none') . ')');

	# Diagnostic: drop the 'New prompt...' text input item. If Squeezer
	# now renders this submenu the issue was the input item; if it still
	# flashes we're after something else.
	my @menu;

	if ($client) {
		my $recents = $prefs->client($client)->get('recent_prompts');
		$recents = [] unless ref($recents) eq 'ARRAY';
		for my $p (@$recents) {
			next unless defined $p && length $p;
			# _safeText: prompts are user-typed and can contain entities
			# / tags that would render literally in HTML-rendering skins.
			push @menu, {
				text    => _safeText($p),
				actions => {
					go => {
						cmd    => ['audiomuseai', 'instant'],
						player => 0,
						params => { prompt => $p },
					},
				},
				nextWindow => 'refresh',
			};
		}
	}
	# Always have at least one item so the menu has content; helps
	# distinguish "menu rendered but empty" from "menu auto-dismissed".
	push @menu, { text => string('PLUGIN_AUDIOMUSEAI_INSTANT_HINT') }
		unless @menu;

	_emit($request, \@menu, 'PLUGIN_AUDIOMUSEAI_MENU_INSTANT');
}

sub _menuStatus {
	my $request = shift;
	# status_active / status_last push a multi-line status sub-window
	# — they're navigation, not actions returning notifications, so use
	# _navItem (no nextWindow:refresh).
	# run_analysis / run_clustering / cancel_active trigger a server-side
	# action and return a notification — _actionItem (refresh).
	_emit($request, [
		_navItem('PLUGIN_AUDIOMUSEAI_STATUS_ACTIVE',
			['audiomuseai', 'status_active']),
		_navItem('PLUGIN_AUDIOMUSEAI_STATUS_LAST',
			['audiomuseai', 'status_last']),
		_actionItem('PLUGIN_AUDIOMUSEAI_STATUS_RUN_ANALYSIS',
			['audiomuseai', 'run_analysis']),
		_actionItem('PLUGIN_AUDIOMUSEAI_STATUS_RUN_CLUSTERING',
			['audiomuseai', 'run_clustering']),
		_actionItem('PLUGIN_AUDIOMUSEAI_STATUS_CANCEL_ACTIVE',
			['audiomuseai', 'cancel_active']),
	]);
}

sub _menuTopQueries {
	my $request = shift;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::clap_top_queries(
		sub {
			my $data = shift;
			my $queries = (ref($data) eq 'HASH' ? $data->{queries} : undef) || [];
			$queries = [] unless ref($queries) eq 'ARRAY';
			my @items;
			for my $q (@$queries) {
				next unless defined $q && length $q;
				# Each query item dispatches to mood (which is the same
				# as instant — both wrap clap_search) so the auto-save
				# pref applies.
				my $label = _safeText($q);
				push @items, {
					text    => $label,
					actions => {
						go => {
							cmd    => ['audiomuseai', 'mood'],
							player => 0,
							params => { prompt => $q, mood_label => $label },
						},
					},
					nextWindow => 'refresh',
				};
			}
			unless (@items) {
				push @items, { text => string('PLUGIN_AUDIOMUSEAI_NO_RESULTS') };
			}
			_emit($request, \@items);
		},
		sub { _notifyError($request, shift) },
	);
}

sub _cancelActive {
	my $request = shift;
	$log->info('cancel_active: looking up running task');
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::active_tasks(
		sub {
			my $data = shift;
			my $tid  = (ref($data) eq 'HASH') ? $data->{task_id} : undef;
			my $st   = (ref($data) eq 'HASH') ? ($data->{status} // '') : '';
			unless ($tid && $st =~ /^(PROGRESS|STARTED|PENDING)$/i) {
				return _notify($request, string('PLUGIN_AUDIOMUSEAI_CANCEL_NONE'));
			}
			$log->info("cancel_active: cancelling task $tid (status=$st)");
			Plugins::AudioMuseAI::API::cancel_task(
				$tid,
				sub { _notify($request,
					sprintf(string('PLUGIN_AUDIOMUSEAI_CANCEL_OK'), $tid)); },
				sub { _notifyError($request, shift); },
			);
		},
		sub { _notifyError($request, shift) },
	);
}

# Read-only library coverage for the settings panel. Cached server-side
# (30s) to avoid pestering the API on every JS poll.
sub _librarySummary {
	my $request = shift;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::dashboard_summary(
		sub {
			my $data = shift;
			my $c    = (ref($data) eq 'HASH' ? $data->{content} : undef) || {};
			$c = {} unless ref($c) eq 'HASH';

			$request->addResult('reachable',        1);
			$request->addResult('distinct_albums',  $c->{distinct_albums}  // '');
			$request->addResult('distinct_artists', $c->{distinct_artists} // '');
			$request->addResult('clap_indexed',     $c->{clap_indexed}     // '');
			$request->addResult('gmm_indexed',      $c->{gmm_indexed}      // '');
			# Top three moods by score (a flat 'mood1=score1; mood2=score2'
			# string the JS can split — keeps the response shape simple).
			my $mc = $c->{moods_coverage};
			if (ref($mc) eq 'ARRAY') {
				my @top = sort { ($b->{score} // 0) <=> ($a->{score} // 0) } @$mc;
				my @three = map {
					sprintf('%s=%d', $_->{label} // '?', int($_->{score} // 0))
				} @top[0 .. ($#top > 2 ? 2 : $#top)];
				$request->addResult('top_moods', join(';', @three));
			} else {
				$request->addResult('top_moods', '');
			}
			$request->setStatusDone;
		},
		sub {
			my $err = shift // 'unknown';
			$request->addResult('reachable', 0);
			$request->addResult('error',     $err);
			$request->setStatusDone;
		},
	);
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
				# Score field renamed `distance` → `divergence` upstream
				# (artist_similarity blueprint). Keep the old name as
				# fallback for any older AudioMuse server.
				my $score = $a->{divergence} // $a->{distance};
				my $sub = '';
				if (defined $score) {
					$sub = sprintf(' (sim %.2f)', $score);
				}
				push @items, {
					text    => $name . $sub,
					actions => {
						go => {
							cmd    => ['audiomuseai', 'similar_artist_with_artist'],
							player => 0,
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
	# Remember the prompt for save_playlist_format=prompt and for the
	# auto-save naming below.
	$prefs->client($client)->set('last_instant_prompt', $prompt);
	$log->info("instant playlist: " . _logSafe($prompt));
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::clap_search(
		$prompt, _count($client),
		sub {
			_queueResults($request, $client, shift, 1);
			_maybeAutoSave($client, 'instant', $prompt) if $prefs->get('auto_save_instant');
		},
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

# LLM-driven playlist via /chat/api/chatPlaylist. Same UX as
# _instantPlaylist (prompt -> queue) but the backend translates the
# prompt into SQL via the configured AI provider rather than running
# CLAP audio similarity.
sub _chatPlaylist {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $prompt  = _trim($request->getParam('prompt') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $prompt;

	_recordRecentPrompt($client, $prompt);
	$prefs->client($client)->set('last_instant_prompt', $prompt);
	$log->info('chat playlist: ' . _logSafe($prompt));
	$request->setStatusProcessing;

	Plugins::AudioMuseAI::API::chat_playlist(
		$prompt,
		sub {
			my $data = shift;
			my $resp = (ref($data) eq 'HASH') ? $data->{response} : undef;
			unless (ref($resp) eq 'HASH') {
				return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
			}

			my $tracks = $resp->{query_results};
			my $msg    = $resp->{message} // '';
			my $prov   = $resp->{ai_provider_used} // '';

			# 'NONE' provider -> server refused. Surface the message
			# verbatim so the user knows what to fix.
			if ($prov eq 'NONE' || $prov eq '') {
				return _notify($request, length $msg
					? "AudioMuse-AI: $msg"
					: string('PLUGIN_AUDIOMUSEAI_CHAT_NO_PROVIDER'));
			}
			unless (ref($tracks) eq 'ARRAY' && @$tracks) {
				return _notify($request, length $msg
					? "AudioMuse-AI ($prov): $msg"
					: string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
			}

			# Queue the AI's tracks. _queueResults handles its own
			# notification ("Queued N tracks…").
			_queueResults($request, $client, $tracks, 1);
			# Auto-save uses the same toggle as Instant Playlist —
			# both are user-typed prompt → queue.
			_maybeAutoSave($client, 'instant', $prompt)
				if $prefs->get('auto_save_instant');
		},
		sub { _notifyError($request, shift) },
	);
}

sub _lyricsSearch {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $prompt  = _trim($request->getParam('prompt') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $prompt;
	# Server enforces a 3-char minimum and rejects shorter queries with
	# 400. Reject early so users see the real reason rather than a generic
	# error.
	if (length $prompt < 3) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_LYRICS_TOO_SHORT'));
	}
	_recordRecentPrompt($client, $prompt);
	$prefs->client($client)->set('last_instant_prompt', $prompt);
	$log->info('lyrics search: ' . _logSafe($prompt));
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::lyrics_search(
		$prompt, _count($client),
		sub {
			_queueResults($request, $client, shift, 1);
			# Auto-save reuses the Instant Playlist toggle — both are
			# user-typed prompt → queue and the user's intent is
			# the same.
			_maybeAutoSave($client, 'instant', $prompt) if $prefs->get('auto_save_instant');
		},
		sub {
			# The lyrics endpoint returns HTTP 404 with {"error":"No
			# lyrics found."} when nothing matches. _notifyError would
			# read that as "track not indexed" — wrong context for a
			# free-text lyric search. Surface a query-specific message
			# instead, fall back to the generic error path otherwise.
			my $err = shift // '';
			if ($err =~ /no lyrics found/i) {
				return _notify($request,
					string('PLUGIN_AUDIOMUSEAI_LYRICS_NO_MATCH'));
			}
			_notifyError($request, $err);
		},
	);
}

sub _moodPlaylist {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $prompt  = _trim($request->getParam('prompt') // '');
	# Optional human-friendly label passed by the menu (e.g. 'Calm /
	# Ambient'). Falls back to the prompt for direct CLI invocations.
	my $label   = _trim($request->getParam('mood_label') // '') || $prompt;
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $prompt;

	# Record the most recent mood label so save_playlist_format=mood_tagged
	# can use it.
	$prefs->client($client)->set('last_mood_label', $label);

	$log->info("mood playlist: " . _logSafe($prompt) . " (label=" . _logSafe($label) . ")");
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::clap_search(
		$prompt, _count($client),
		sub {
			_queueResults($request, $client, shift, 1);
			_maybeAutoSave($client, 'mood', $label) if $prefs->get('auto_save_mood');
		},
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
	_ensureDstmEnabled();
	$prefs->client($client)->set('dstm_active', 'similar');
	$log->info("DSTM mode 'similar' active for " . $client->id);
	_similarNow($request);
}

sub _dynamicFingerprint {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	_ensureDstmEnabled();
	$prefs->client($client)->set('dstm_active', 'fingerprint');
	$log->info("DSTM mode 'fingerprint' active for " . $client->id);
	_sonicFingerprint($request);
}

# Selecting a dynamic mode from the player menu is an explicit opt-in to
# auto-extend. The per-song hook (_onNewSong) gates on the GLOBAL
# dstm_enabled pref, so if that's still off the chosen mode would queue
# once and then silently never extend. Flip the gate on the first time a
# user starts a mode; the Settings checkbox still lets them disable the
# whole feature, and _dynamicStop clears the per-player mode regardless.
sub _ensureDstmEnabled {
	return if $prefs->get('dstm_enabled');
	$prefs->set('dstm_enabled', 1);
	$log->info('DSTM auto-extend globally enabled (was off) by menu selection');
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

	# Name precedence:
	#   1. user-typed `name` param (web UI / Material — they can override
	#      the auto-name by typing in the field)
	#   2. configured save_playlist_format applied to current state
	#   3. timestamp fallback
	my $name = _trim($request->getParam('name') // '');
	$name = _generateAutoName($client) unless length $name;
	$name = _sanitisePlaylistName($name);

	my $count = Slim::Player::Playlist::count($client);
	if (!$count) {
		return _notify($request,
			string('PLUGIN_AUDIOMUSEAI_PLAYLIST_EMPTY'));
	}

	$log->info("saving Lyrion queue ($count tracks) as playlist '" . _logSafe($name) . "' on " . $client->id);
	Slim::Control::Request::executeRequest(
		$client,
		['playlist', 'save', $name]
	);
	_notify($request, sprintf('%s (%d tracks): %s',
		string('PLUGIN_AUDIOMUSEAI_PLAYLIST_SAVED'), $count, $name));
}

# --- Auto-name + auto-save helpers ------------------------------------------

sub _sanitisePlaylistName {
	my $n = shift // '';
	$n =~ s/[\x00-\x1f\x7f]//g;     # control chars
	$n =~ s{[/\\]}{-}g;              # path separators
	$n =~ s/\s+/ /g;                  # collapse whitespace
	$n = _trim($n);
	$n = substr($n, 0, 80) if length($n) > 80;
	$n = 'AudioMuse playlist' unless length $n;
	return $n;
}

sub _timestamp {
	my @t = localtime();
	return sprintf('%04d-%02d-%02d %02d:%02d',
		$t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1]);
}

sub _generateAutoName {
	my ($client, $extra) = @_;
	my $fmt = $prefs->get('save_playlist_format') || 'timestamp';

	# Per-client extras (last mood label, last instant prompt) drive the
	# tagged formats. $extra (when called from auto-save) overrides them.
	$extra //= {};
	my $mood   = $extra->{mood}
		// $prefs->client($client)->get('last_mood_label');
	my $prompt = $extra->{prompt}
		// $prefs->client($client)->get('last_instant_prompt');

	if ($fmt eq 'first_track') {
		my $song = Slim::Player::Playlist::song($client, 0);
		if ($song) {
			my $title  = $song->title // '';
			my $artist = $song->artistName // '';
			return $title || 'AudioMuse: ' . _timestamp() unless length $artist;
			return sprintf('AudioMuse: %s - %s', $title, $artist);
		}
	}
	elsif ($fmt eq 'artist_mix') {
		my %seen; my @top;
		my $count = Slim::Player::Playlist::count($client);
		for (my $i = 0; $i < $count && @top < 3; $i++) {
			my $s = Slim::Player::Playlist::song($client, $i) or next;
			my $a = $s->artistName // '' or next;
			next if $seen{$a}++;
			push @top, $a;
		}
		if (@top) {
			return sprintf('AudioMuse: %s (%dt)', join(', ', @top), $count);
		}
	}
	elsif ($fmt eq 'mood_tagged' && $mood) {
		return sprintf('AudioMuse: %s - %s', $mood, _timestamp());
	}
	elsif ($fmt eq 'prompt' && $prompt) {
		return sprintf('AudioMuse: %s', $prompt);
	}

	# Fallback for any unrecognised format and for the explicit
	# 'timestamp' choice.
	return 'AudioMuse ' . _timestamp();
}

# Save the player's current queue without going through the user-facing
# notification. Used by auto-save after Instant Playlist / Mood actions.
sub _maybeAutoSave {
	my ($client, $kind, $label) = @_;
	return unless $client;
	my $count = Slim::Player::Playlist::count($client);
	return unless $count;

	# Compose a name biased toward the current action's context.
	my $extra = $kind eq 'mood'    ? { mood   => $label }
	          : $kind eq 'instant' ? { prompt => $label }
	          : {};
	# For auto-save, prefer a context-aware name even when the global
	# format pref is 'timestamp' — the user already gave us a label.
	my $name;
	if ($kind eq 'mood') {
		$name = sprintf('AudioMuse: %s - %s', $label, _timestamp());
	} elsif ($kind eq 'instant') {
		$name = sprintf('AudioMuse: %s', $label);
	} else {
		$name = _generateAutoName($client, $extra);
	}
	$name = _sanitisePlaylistName($name);

	$log->info("auto-saving $kind queue ($count tracks) as '" . _logSafe($name) . "' on " . $client->id);
	Slim::Control::Request::executeRequest(
		$client,
		['playlist', 'save', $name]
	);
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

# Make a string safe for log lines — strips ASCII control chars
# (newlines, CR, tab, etc.) so user-supplied prompts can't inject false
# log entries.
sub _logSafe {
	my $s = shift // '';
	$s =~ s/[\x00-\x1f\x7f]/?/g;
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

# --- Item builder helpers ---
# Three flavours of item, distinguished by what the dispatched action
# returns:
#
#   _actionItem  : action returns a NOTIFICATION (queues tracks etc).
#                  Includes `nextWindow: refresh` so the parent menu
#                  refreshes after the toast.
#
#   _navItem     : action returns a NEW MENU to push (a picker, sub
#                  list). Has NO `nextWindow` — Squeezer would close
#                  the just-pushed menu if `refresh` were set.
#
#   _submenuItem : same as _navItem but for items that explicitly open
#                  a known submenu builder (menu_mood etc). Kept
#                  separate for readability.
#
#   _textInputItem : prompts for text. Whether `nextWindow:refresh` is
#                    appropriate depends on the dispatched command —
#                    callers pass a flag.
#
# Player flag is always 0. The actual player ID is sent automatically
# as the first JSON-RPC argument; the menu item's `player` field, if
# set to a non-zero value, is interpreted by Squeezer as a literal
# player ID and breaks navigation. (See v0.2.18 commit notes.)

sub _actionItem {
	my ($strKey, $cmd, undef) = @_;  # 3rd arg kept for back-compat, unused
	return {
		text    => string($strKey),
		actions => {
			go => {
				cmd    => $cmd,
				player => 0,
			},
		},
		nextWindow => 'refresh',
	};
}

sub _navItem {
	my ($strKey, $cmd, $params) = @_;
	my $go = { cmd => $cmd, player => 0 };
	$go->{params} = $params if $params && %$params;
	return {
		text    => string($strKey),
		actions => { go => $go },
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
	my ($titleKey, $promptKey, $cmd, $paramName, $opts) = @_;
	# $opts->{push} = 1  -> action returns a new menu (no nextWindow)
	#                       Default is action returns a notification.
	$opts ||= {};
	my $item = {
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
				player => 0,
				params => { $paramName => '__TAGGEDINPUT__' },
			},
		},
	};
	$item->{nextWindow} = 'refresh' unless $opts->{push};
	return $item;
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
					player => 0,
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
	my ($request, $menu, $titleKey) = @_;
	$menu ||= [];
	# Always set 'window' metadata so strict controllers (Squeezer on
	# Android, etc.) treat the response as a sub-window push instead of
	# a fire-and-forget action that auto-dismisses. The field name is
	# `menustyle` (lowercase, no T), per the SlimBrowse protocol —
	# `titleStyle` is non-standard and Squeezer ignores it, causing the
	# auto-dismiss. Standard values are 'text' (plain list) and 'album'
	# (with artwork). Established plugins like Dynamic Playlists 4
	# follow this exact convention.
	$request->addResult('window', {
		text      => $titleKey ? string($titleKey) : string('PLUGIN_AUDIOMUSEAI'),
		menustyle => 'text',
	});
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
	} elsif ($err =~ /\b404\b|not found/i) {
		# AudioMuse returns 404 for similar_tracks etc. when the track
		# isn't in its index. Most common cause: the track / album
		# hasn't been analyzed yet (large libraries take days).
		_notify($request, string('PLUGIN_AUDIOMUSEAI_TRACK_NOT_INDEXED'));
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

# Unwrap a track list from any of the response shapes AudioMuse uses:
#   - bare array (similar_tracks, similar_artists, search_tracks,
#     sonic_fingerprint)
#   - { results: [...], ... }   (clap_search, lyrics_search, alchemy)
#   - { path: [...], total_distance } (find_path)
#   - { query_results: [...] } as a courtesy for any future caller that
#     forwards the chat-playlist response straight through.
# Returns an ARRAYREF (possibly empty) so callers can iterate without
# checking ref() each time.
sub _extractTracks {
	my $data = shift;
	return $data    if ref($data) eq 'ARRAY';
	return []       unless ref($data) eq 'HASH';
	for my $k (qw(results path query_results)) {
		return $data->{$k} if ref($data->{$k}) eq 'ARRAY';
	}
	return [];
}

sub _queueResults {
	my ($request, $client, $data, $loadFresh) = @_;
	my $tracks = _extractTracks($data);
	unless (ref($tracks) eq 'ARRAY' && @$tracks) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
	}
	# Filter: defined, non-empty, and only digits (Lyrion track IDs are
	# always integers; anything else would crash playlistcontrol).
	my @ids = grep { defined && /\A\d+\z/ }
		map { $_->{item_id} // $_->{id} } @$tracks;
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
		my $tracks = _extractTracks(shift);
		return unless ref($tracks) eq 'ARRAY' && @$tracks;
		my @ids = grep { defined && /\A\d+\z/ }
			map { $_->{item_id} // $_->{id} } @$tracks;
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
