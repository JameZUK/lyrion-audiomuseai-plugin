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
	VERSION             => '0.6.1',
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
	# Anti-repeat: how many recently played / queued tracks per player we
	# remember (in memory) and refuse to queue again on append / extend.
	HISTORY_MAX         => 1000,
	# Tracks added per auto-extend (menu dynamic mode and native DSTM).
	EXTEND_BATCH        => 10,
	# Hard cap on any single AudioMuse request size.
	FETCH_MAX           => 200,
};

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.audiomuseai',
	'defaultLevel' => 'INFO',
	'description'  => 'PLUGIN_AUDIOMUSEAI',
});

my $prefs = preferences('plugin.audiomuseai');

# Tracks we registered timers for, so shutdownPlugin can clean up.
my @_timers;

# Per-player anti-repeat memory: client id => { order => [[id,key],...],
# ids => {id=>n}, keys => {key=>n} }. See _remember / _exclusionSet.
our %_history;   # (package var so tests can reset it)
# Lyrion track id -> AudioMuse's id for the same song, for tracks AudioMuse
# knows under a stale (pre-rescan) Lyrion id. Lets a renumbered track still
# seed AudioMuse queries. See _localizeRows / _withAmSeed.
my %_amIdFor;
# Per-player tracks WE just added: client id => { id => [epoch, key] }.
# LMS applies `playlistcontrol add` asynchronously, so for a moment a fresh
# batch isn't in the queue yet; a second extend in that window (fast
# skipping) would otherwise re-add the same tracks.
our %_recentAdds;
use constant RECENT_ADD_TTL => 600;
# Per-player in-flight auto-extend (epoch), so back-to-back newsong events
# can't fire two overlapping extends that both add the same tracks.
my %_extending;

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
		# Auto-save an Album Creation result under its suggested name.
		auto_save_album      => 0,
		# AudioMuse multi-server (v3.0+): the AudioMuse name of this Lyrion
		# server. Blank = AudioMuse's default server.
		server_name          => '',
	});

	# One-time: normalize any pre-existing values that may have come in
	# with whitespace or missing scheme.
	if (my $u = $prefs->get('url'))   { $prefs->set('url',   _normalizeUrl($u)); }
	if (my $t = $prefs->get('token')) { $prefs->set('token', _trim($t));        }

	if (main::WEBUI) {
		require Plugins::AudioMuseAI::Settings;
		Plugins::AudioMuseAI::Settings->new;
		# Default / Classic web skins: AudioMuse-AI under My Music (#6).
		require Plugins::AudioMuseAI::Web;
		Plugins::AudioMuseAI::Web::init();
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
	# Tap-only paginated artist browse — a no-typing alternative to the
	# filter_artists search box, for stepping through the whole library
	# alphabetically.
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
	# SemGrove similarity (merged lyrics+audio index) — current track or a
	# given track id. Distinct from similar_now/_track (audio only).
	Slim::Control::Request::addDispatch(['audiomuseai', 'semgrove_now'],
		[1, 1, 1, \&_semGroveNow]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'semgrove_track'],
		[1, 1, 1, \&_semGroveTrack]);
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

	# Alchemy "radios" — user-defined saved stations (anchor + temperature
	# + n). menu_radios lists them; radios_run asks AudioMuse to (re)build
	# one Lyrion playlist per enabled radio.
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_radios'],
		[0, 1, 1, \&_menuRadios]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'radios_run'],
		[0, 1, 1, \&_radiosRun]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'anchor_play'],
		[1, 1, 1, \&_anchorPlay]);

	# --- AudioMuse v3.x features ---
	# Album Creation (v3.6.2): from the current track, a picked track, or
	# a typed description.
	Slim::Control::Request::addDispatch(['audiomuseai', 'album_now'],
		[1, 1, 1, \&_albumNow]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'album_track'],
		[1, 1, 1, \&_albumTrack]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'album_text'],
		[1, 1, 1, \&_albumText]);
	# Hyperbolic Explorer (v3.3): similar / roots / niche.
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_explore'],
		[0, 1, 1, \&_menuExplore]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'explore_now'],
		[1, 1, 1, \&_exploreNow]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'explore_track'],
		[1, 1, 1, \&_exploreTrack]);
	# Sonic mood clusters (mood centroids).
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_sonic_moods'],
		[0, 1, 1, \&_menuSonicMoods]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_sonic_mood'],
		[0, 1, 1, \&_menuSonicMood]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'sonic_mood'],
		[1, 1, 1, \&_sonicMood]);
	# Lyric themes (lyrics axes).
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_lyric_themes'],
		[0, 1, 1, \&_menuLyricThemes]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'lyric_theme'],
		[1, 1, 1, \&_lyricTheme]);
	# DCLAP steering vocabulary (reference list for Instant Playlist).
	Slim::Control::Request::addDispatch(['audiomuseai', 'menu_concepts'],
		[0, 1, 1, \&_menuConcepts]);
	# Alchemy with artists / playlists / anchors.
	Slim::Control::Request::addDispatch(['audiomuseai', 'alchemy_add_artist'],
		[1, 1, 1, \&_alchemyAddArtist]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'alchemy_sub_artist'],
		[1, 1, 1, \&_alchemySubArtist]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'alchemy_pick'],
		[0, 1, 1, \&_alchemyPick]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'alchemy_add_ref'],
		[1, 1, 1, \&_alchemyAddRef]);
	# Extra dynamic (auto-extend) modes.
	Slim::Control::Request::addDispatch(['audiomuseai', 'dyn_semgrove'],
		[1, 1, 1, \&_dynamicSemGrove]);
	Slim::Control::Request::addDispatch(['audiomuseai', 'dyn_album'],
		[1, 1, 1, \&_dynamicAlbum]);

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
	Slim::Menu::TrackInfo->registerInfoProvider(
		audiomuseaiSemGroveTrack => (
			after => 'audiomuseaiSimilarTrack',
			func  => \&_trackInfoSemGrove,
		),
	);
	Slim::Menu::TrackInfo->registerInfoProvider(
		audiomuseaiAlbumFromTrack => (
			after => 'audiomuseaiSemGroveTrack',
			func  => sub { _trackInfoItem(@_[0 .. 2], 'PLUGIN_AUDIOMUSEAI_INFO_ALBUM_TRACK',
				['audiomuseai', 'album_track']) },
		),
	);
	Slim::Menu::TrackInfo->registerInfoProvider(
		audiomuseaiExploreTrack => (
			after => 'audiomuseaiAlbumFromTrack',
			func  => sub { _trackInfoItem(@_[0 .. 2], 'PLUGIN_AUDIOMUSEAI_INFO_EXPLORE_TRACK',
				['audiomuseai', 'explore_track'], { mode => 'niche' }) },
		),
	);
	Slim::Menu::AlbumInfo->registerInfoProvider(
		audiomuseaiAlbumAlchemy => (
			after => 'top',
			func  => \&_albumInfoAlchemy,
		),
	);

	# --- Native "Don't Stop The Music" providers (issue #2) ----------------
	# Surface AudioMuse-AI in LMS's per-player "Don't Stop The Music"
	# dropdown (Player Settings -> Audio), alongside MusicIP / SugarCube.
	# Registered at runtime and guarded so the plugin still loads on LMS
	# builds without DSTM. Coexists with the menu-based dynamic modes:
	# _onNewSong stands down when one of our providers is a player's active
	# DSTM handler, so the queue isn't topped up twice.
	if ( eval { require Slim::Plugin::DontStopTheMusic::Plugin; 1 } ) {
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
			'PLUGIN_AUDIOMUSEAI_DSTM_SIMILAR',     \&_dstmMixSimilar);
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
			'PLUGIN_AUDIOMUSEAI_DSTM_ALBUM',       \&_dstmMixAlbum);
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
			'PLUGIN_AUDIOMUSEAI_DSTM_FINGERPRINT', \&_dstmMixFingerprint);
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
			'PLUGIN_AUDIOMUSEAI_DSTM_SEMGROVE',    \&_dstmMixSemGrove);
		$log->info("registered Don't Stop The Music providers");
	}
	else {
		$log->info('DontStopTheMusic not available; native providers skipped');
	}

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
	# Pass the contributor id so similar_artist resolves the tracks from the
	# local library (handles composite/credit artist names).
	my %params = ( artist => "$name" );
	my $aid = ref($artist) ? eval { $artist->id } : undef;
	$params{artist_id} = "$aid" if defined $aid && length "$aid";
	return _infoItem('PLUGIN_AUDIOMUSEAI_INFO_SIMILAR_ARTIST',
		['audiomuseai', 'similar_artist'], \%params);
}

sub _trackInfoSimilar {
	my ($client, $url, $track) = @_;
	return _trackInfoItem($client, $url, $track,
		'PLUGIN_AUDIOMUSEAI_INFO_SIMILAR_TRACK', ['audiomuseai', 'similar_track']);
}

sub _trackInfoSemGrove {
	my ($client, $url, $track) = @_;
	return _trackInfoItem($client, $url, $track,
		'PLUGIN_AUDIOMUSEAI_INFO_SEMGROVE_TRACK', ['audiomuseai', 'semgrove_track']);
}

# Generic "AudioMuse: ... from this track" info-menu entry.
sub _trackInfoItem {
	my ($client, $url, $track, $strKey, $cmd, $extra) = @_;
	return unless $track;
	my $tid = ref($track) ? eval { $track->id } : "$track";
	return unless defined $tid && $tid =~ /\A\d+\z/;
	return _infoItem($strKey, $cmd, { %{ $extra || {} }, track_id => "$tid" });
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
	return _infoItem('PLUGIN_AUDIOMUSEAI_INFO_ALCHEMY_FROM_ALBUM',
		['audiomuseai', 'alchemy_album'], { album_id => "$aid" });
}

# An info-menu (context menu) item. Controllers use the `jive` go action,
# exactly as before (type stays 'redirect' — that's what they receive).
# The Default web skin ignores `jive` and only shows a 'redirect' item that
# has a `web.url`: that points at the web adapter's run page, which runs the
# same command for the selected player and shows the result (#6).
sub _infoItem {
	my ($strKey, $cmd, $params) = @_;
	my $item = {
		type => 'redirect',
		name => string($strKey),
		jive => {
			actions => {
				go => {
					cmd    => $cmd,
					player => 0,
					params => $params,
				},
			},
		},
	};
	if (main::WEBUI) {
		$item->{web} = { url => Plugins::AudioMuseAI::Web::runUrl($cmd->[1], $params) };
	}
	return $item;
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
	# SemGrove: "similar" using the merged lyrics+audio index — sits next to
	# Similar to current track as the lyrics-aware alternative.
	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_SEMGROVE_NOW',
		['audiomuseai', 'semgrove_now'], 1);
	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_FINGERPRINT',
		['audiomuseai', 'sonic_fp'], 1);
	# Album Creation (v3.6.2): a sequenced album around the current track.
	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_ALBUM_NOW',
		['audiomuseai', 'album_now']);
	# Hyperbolic Explorer (v3.3): similar / roots / niche around it.
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_EXPLORE',
		['audiomuseai', 'menu_explore']);
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_MOOD',
		['audiomuseai', 'menu_mood']);
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_LYRIC_THEMES',
		['audiomuseai', 'menu_lyric_themes']);
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
	# Saved alchemy "radios" — list + (re)build their Lyrion playlists.
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_RADIOS',
		['audiomuseai', 'menu_radios']);

	# --- Tier 4: tools (tap-only) ---
	# Save current queue: auto-named with timestamp, no text input
	# required. Squeezer-friendly. Users can rename via Lyrion's standard
	# playlist UI later if desired.
	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_MENU_SAVE_PLAYLIST',
		['audiomuseai', 'save_playlist'], 1);

	# --- Tier 5: text-input items (the user types a prompt) ---
	# These carry a Jive `input` block, which every controller renders.
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
	push @menu, _textInputItem('PLUGIN_AUDIOMUSEAI_MENU_ALBUM_TEXT',
		'PLUGIN_AUDIOMUSEAI_PROMPT_ALBUM',
		['audiomuseai', 'album_text'], 'prompt');
	# findpath_search returns a track-pick menu (not a notification),
	# so it should NOT have nextWindow:refresh — that would close the
	# pushed picker.
	# Find path: sonic / lyrics / hyperbolic journey, each a text box.
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_FINDPATH',
		['audiomuseai', 'menu_findpath']);

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
	return undef unless $state =~ /^(?:RUNNING|NEW|PROGRESS|STARTED|PENDING|QUEUED)$/i;

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
	# AudioMuse's own mood clusters (analysed, not text-prompted).
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_SONIC_MOODS',
		['audiomuseai', 'menu_sonic_moods']);
	push @menu, _submenuItem('PLUGIN_AUDIOMUSEAI_MENU_CONCEPTS',
		['audiomuseai', 'menu_concepts']);

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
		# v2.3+/v3.x alchemy also blends whole artists, saved anchors and
		# playlists, not just songs.
		_actionItem('PLUGIN_AUDIOMUSEAI_ALCHEMY_ADD_ARTIST',
			['audiomuseai', 'alchemy_add_artist']),
		_actionItem('PLUGIN_AUDIOMUSEAI_ALCHEMY_SUB_ARTIST',
			['audiomuseai', 'alchemy_sub_artist']),
		_navItem('PLUGIN_AUDIOMUSEAI_ALCHEMY_ADD_PLAYLIST',
			['audiomuseai', 'alchemy_pick'], { kind => 'playlist' }),
		_navItem('PLUGIN_AUDIOMUSEAI_ALCHEMY_ADD_ANCHOR',
			['audiomuseai', 'alchemy_pick'], { kind => 'anchor' }),
		_actionItem('PLUGIN_AUDIOMUSEAI_ALCHEMY_RESET',
			['audiomuseai', 'alchemy_reset'], 1),
		_actionItem('PLUGIN_AUDIOMUSEAI_ALCHEMY_GENERATE',
			['audiomuseai', 'alchemy_generate'], 1),
	]);
}

sub _menuFindPath {
	my $request = shift;
	# One text box per path method; each returns a destination pick-list.
	_emit($request, [ map {
		my ($key, $method) = @$_;
		_textInputItem($key,
			'PLUGIN_AUDIOMUSEAI_FINDPATH_PROMPT',
			['audiomuseai', 'findpath_search'], 'artist',
			{ push => 1, params => { method => $method } });
	} (
		['PLUGIN_AUDIOMUSEAI_FINDPATH_SONIC',      'sonic'],
		['PLUGIN_AUDIOMUSEAI_FINDPATH_LYRICS',     'lyrics'],
		['PLUGIN_AUDIOMUSEAI_FINDPATH_HYPERBOLIC', 'hyperbolic'],
	) ], 'PLUGIN_AUDIOMUSEAI_MENU_FINDPATH');
}

sub _menuDynamic {
	my $request = shift;
	my $client  = $request->client;
	my $active  = $client ? ($prefs->client($client)->get('dstm_active') // '') : '';

	# Prefix the currently-active mode with a marker so the user can see
	# what's running and find 'Stop auto-extend' easily. Per-player.
	# ASCII marker — non-ASCII glyphs reach some controllers as Latin-1
	# mojibake over JSON-RPC (this file has no `use utf8`); keep emitted
	# strings 7-bit. See issue #1 (the em-dash showed up as 'a').
	my @modes = (
		['similar',     'PLUGIN_AUDIOMUSEAI_DYNAMIC_SIMILAR',     'dyn_similar'],
		['semgrove',    'PLUGIN_AUDIOMUSEAI_DYNAMIC_SEMGROVE',    'dyn_semgrove'],
		['album',       'PLUGIN_AUDIOMUSEAI_DYNAMIC_ALBUM',       'dyn_album'],
		['fingerprint', 'PLUGIN_AUDIOMUSEAI_DYNAMIC_FINGERPRINT', 'dyn_fingerprint'],
	);
	_emit($request, [
		(map {
			my ($mode, $key, $cmd) = @$_;
			{
				text    => ($active eq $mode ? '* ' : '') . string($key),
				actions => { go => { cmd => ['audiomuseai', $cmd], player => 0 } },
				nextWindow => 'refresh',
			};
		} @modes),
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
	my $total   = 0;
	my $fetched = 0;   # artists actually added this page (drives pagination)

	# First page only: a search box + the explanatory header.
	if ($start == 0) {
		# Search box (discussion #686 — wirrunna). The Jive 'input' block
		# renders as a search field, which beats paging the whole library
		# alphabetically; the paged list below is still there for browsing
		# without typing.
		push @items, _textInputItem(
			$target eq 'similar_song_search'
				? 'PLUGIN_AUDIOMUSEAI_SEARCH_ARTIST_FOR_SONG'
				: 'PLUGIN_AUDIOMUSEAI_SEARCH_ARTIST',
			'PLUGIN_AUDIOMUSEAI_SEARCH_ARTIST_PROMPT',
			['audiomuseai', 'filter_artists'], 'query',
			{ push => 1, params => { target => $target } });

		# Non-actionable header — explains the drill-down flow to users who
		# tap 'Similar to song' / 'Similar to artist' expecting an immediate
		# result list. Items without an 'actions' block render as a
		# non-tappable label (or grayed-out item, depending on controller).
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
				['audiomuseai', $target], $a->{id});
			$fetched++;
		}
	};
	$log->warn("browse_artists failed at start=$start: $@") if $@;

	# 'More...' tail item if there are further pages. Advance by the number
	# of ARTISTS shown ($start + $fetched), NOT scalar(@items) — the search
	# box and header would otherwise skew the offset and skip artists.
	# Static so it works even on controllers that ignore server-side
	# pagination metadata.
	my $shown = $start + $fetched;
	if ($total > $shown) {
		push @items, {
			text    => string('PLUGIN_AUDIOMUSEAI_MORE'),
			actions => {
				go => {
					cmd    => ['audiomuseai', 'browse_artists'],
					player => 0,
					params => { target => $target, start => $shown },
				},
			},
		};
	}

	if (!$fetched) {
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

	for my $m (@$matches) {
		next if lc($m->{name}) eq lc($query);  # already at the top
		push @items, _libraryArtistItem($m->{name},
			['audiomuseai', $target], $m->{id});
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
			push @out, { id => $a->{id}, name => $name };
		}
	};
	$log->warn("library artist lookup failed: $@") if $@;
	return \@out;
}

sub _libraryArtistItem {
	my ($artistName, $cmd, $artist_id) = @_;
	# Carry the Lyrion contributor id when we have it, so the dispatched
	# action resolves the artist's tracks from the local library rather than
	# AudioMuse's name search (which can't match composite/credit contributor
	# names like "Dave Grohl, Foo Fighters, ...").
	my %params = ( artist => "$artistName" );
	$params{artist_id} = "$artist_id"
		if defined $artist_id && length "$artist_id";
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
				params => \%params,
			},
		},
	};
}

# A library contributor's tracks, straight from Lyrion (by artist_id), shaped
# like AudioMuse search_tracks results ({ item_id, title, author }) so they
# drop into _tracksAsPickMenu / _queueResults. This sidesteps AudioMuse's
# artist-name matching, which can't resolve composite/credit contributor
# names. AudioMuse indexes by the same Lyrion track IDs, so the ids are valid
# seeds.
sub _libraryArtistTracks {
	my ($artist_id, $limit) = @_;
	return [] unless defined $artist_id && $artist_id =~ /\A\d+\z/;
	$limit ||= MAX_PICK_RESULTS;
	my @out;
	eval {
		my $req = Slim::Control::Request::executeRequest(undef,
			['titles', 0, $limit, "artist_id:$artist_id", 'tags:a']);
		return unless $req;
		my $loop = $req->getResult('titles_loop') || [];
		for my $t (@$loop) {
			next unless defined $t->{id};
			push @out, {
				item_id => '' . $t->{id},
				title   => $t->{title},
				author  => $t->{artist},
			};
		}
	};
	$log->warn("library artist tracks lookup failed for $artist_id: $@") if $@;
	return \@out;
}

# Just the track IDs for a contributor (a fuller list than the pick menu —
# used as alchemy seeds / the exclude set for "music like this artist").
sub _libraryArtistTrackIds {
	my $artist_id = shift;
	return [ map { $_->{item_id} } @{ _libraryArtistTracks($artist_id, 500) } ];
}

sub _menuInstant {
	my $request = shift;
	my $client  = $request->client;
	$log->info('menu_instant reached (client='
		. ($client ? $client->id : 'none') . ')');

	# This submenu lists the player's recent prompts only (no inline
	# 'New prompt...' input item) — typing a fresh prompt is done from the
	# top-level Instant Playlist item instead.
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
			unless ($tid && $st =~ /^(?:RUNNING|NEW|PROGRESS|STARTED|PENDING|QUEUED)$/i) {
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

# ----- Alchemy radios -------------------------------------------------------

# Saved radios and anchors. Tapping a radio or anchor plays it now (songs
# nearest the anchor, via similar_tracks?anchor_id=); "Rebuild" asks
# AudioMuse to (re)write one Lyrion playlist per enabled radio.
sub _menuRadios {
	my $request = shift;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::list_radios(
		sub {
			my $data   = shift;
			my $radios = (ref($data) eq 'HASH' ? $data->{radios} : undef) || [];
			$radios = [] unless ref($radios) eq 'ARRAY';
			Plugins::AudioMuseAI::API::list_anchors(
				sub { _emitRadios($request, $radios, shift) },
				sub { _emitRadios($request, $radios, {}) },
			);
		},
		sub { _notifyError($request, shift) },
	);
}

sub _emitRadios {
	my ($request, $radios, $adata) = @_;
	my $anchors = (ref($adata) eq 'HASH' ? $adata->{anchors} : undef) || [];
	$anchors = [] unless ref($anchors) eq 'ARRAY';

	my @menu;
	my %radioAnchor;
	for my $r (@$radios) {
		next unless ref($r) eq 'HASH' && defined $r->{anchor_id};
		$radioAnchor{ $r->{anchor_id} } = 1;
		my $name  = _safeText($r->{name} // '?');
		my $label = ($r->{enabled} ? '' : '(off) ') . $name;
		$label .= sprintf(' (%d tracks)', $r->{n_results})
			if defined $r->{n_results} && $r->{n_results} =~ /\A\d+\z/;
		my %params = (anchor_id => "$r->{anchor_id}", name => $name);
		$params{n} = "$r->{n_results}" if defined $r->{n_results} && $r->{n_results} =~ /\A\d+\z/;
		push @menu, {
			text    => string('PLUGIN_AUDIOMUSEAI_RADIO_PLAY') . ' ' . $label,
			actions => { go => { cmd => ['audiomuseai', 'anchor_play'], player => 0,
				params => \%params } },
			nextWindow => 'refresh',
		};
	}
	for my $an (@$anchors) {
		next unless ref($an) eq 'HASH' && defined $an->{id};
		next if $radioAnchor{ $an->{id} };   # already listed as a radio
		my $name = _safeText($an->{name} // '?');
		push @menu, {
			text    => string('PLUGIN_AUDIOMUSEAI_ANCHOR_PLAY') . ' ' . $name,
			actions => { go => { cmd => ['audiomuseai', 'anchor_play'], player => 0,
				params => { anchor_id => "$an->{id}", name => $name } } },
			nextWindow => 'refresh',
		};
	}
	push @menu, { text => string('PLUGIN_AUDIOMUSEAI_RADIOS_NONE') } unless @menu;
	push @menu, _actionItem('PLUGIN_AUDIOMUSEAI_RADIOS_RUN', ['audiomuseai', 'radios_run'])
		if @$radios;
	_emit($request, \@menu, 'PLUGIN_AUDIOMUSEAI_MENU_RADIOS');
}

sub _radiosRun {
	my $request = shift;
	$log->info('radios_run: POST /api/radios/run');
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::run_radios(
		sub {
			my $data    = shift;
			my $created = (ref($data) eq 'HASH') ? $data->{playlists_created} : undef;
			my $enabled = (ref($data) eq 'HASH') ? $data->{radios_enabled}    : undef;
			my $msg     = (ref($data) eq 'HASH') ? $data->{message}           : undef;
			if (defined $created || defined $enabled) {
				_notify($request, sprintf(string('PLUGIN_AUDIOMUSEAI_RADIOS_RUN_OK'),
					int($created // 0), int($enabled // 0)));
			}
			else {
				_notify($request, $msg
					|| string('PLUGIN_AUDIOMUSEAI_STATUS_TRIGGERED'));
			}
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
				# v3.x reports `count` (songs per mood); older builds `score`.
				my $v = sub { $_[0]{count} // $_[0]{score} // 0 };
				my @top = sort { $v->($b) <=> $v->($a) }
					grep { ref($_) eq 'HASH' } @$mc;
				my @three = map {
					sprintf('%s=%d', $_->{label} // '?', int($v->($_)))
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
	_appendSimilar($request, $client, '' . $song->id);
}

sub _similarSongSearch {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $artist  = _trim($request->getParam('artist') // '');
	my $aid     = _trim($request->getParam('artist_id') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT'))
		unless length $artist || length $aid;

	# Picked library artist: list its tracks straight from Lyrion (handles
	# composite contributor names AudioMuse's search can't match). A
	# free-typed name falls through to AudioMuse's fuzzy search_tracks.
	if (length $aid && $aid =~ /\A\d+\z/) {
		my $tracks = _libraryArtistTracks($aid);
		unless (@$tracks) {
			return _notify($request,
				string('PLUGIN_AUDIOMUSEAI_NO_TRACKS_FOR_ARTIST'));
		}
		return _emit($request,
			_tracksAsPickMenu($tracks, ['audiomuseai', 'similar_track'], 'track_id'));
	}

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
	return $request->setStatusBadParams unless defined $tid && $tid =~ /\A\d+\z/;
	_appendSimilar($request, $client, $tid);
}

# "Music like this artist" from a single selection (discussion #686 —
# mamema). Picking an artist used to show a second pick-list of ~10 similar
# artists; now it goes straight to a playlist. We seed AudioMuse's alchemy
# (centroid) with the artist's own analyzed tracks and filter them back out,
# so you get a varied blend in that artist's vein — not the artist's own
# catalogue, and without the extra tap.
sub _similarArtist {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $artist  = _trim($request->getParam('artist') // '');
	my $aid     = _trim($request->getParam('artist_id') // '');
	unless (length $artist || length $aid) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT'));
	}

	$log->info('similar_artist (blend): ' . _logSafe($artist)
		. (length $aid ? " [id $aid]" : ''));
	$request->setStatusProcessing;

	# A picked library artist carries its Lyrion contributor id — use the
	# local library's exact track list (AudioMuse's name search misses
	# composite/credit names like "Dave Grohl, Foo Fighters, ..."). A
	# free-typed name (no id) goes through AudioMuse's fuzzy search_tracks.
	if (length $aid && $aid =~ /\A\d+\z/) {
		my $ids = _libraryArtistTrackIds($aid);
		unless (@$ids) {
			return _notify($request,
				string('PLUGIN_AUDIOMUSEAI_NO_TRACKS_FOR_ARTIST'));
		}
		_similarArtistBlend($request, $client, $artist, $ids);
	}
	else {
		Plugins::AudioMuseAI::API::search_tracks(
			$artist,
			sub {
				my $tracks = shift;
				my @ids = grep { defined && /\A\d+\z/ }
					map { $_->{item_id} // $_->{id} }
					(ref($tracks) eq 'ARRAY' ? @$tracks : ());
				unless (@ids) {
					return _notify($request,
						string('PLUGIN_AUDIOMUSEAI_NO_TRACKS_FOR_ARTIST'));
				}
				_similarArtistBlend($request, $client, $artist, \@ids);
			},
			sub { _notifyError($request, shift) },
		);
	}
}

# Seed AudioMuse's alchemy (centroid) with the artist's tracks ($ids) and
# queue the blend, dropping the artist's own tracks (by id, and by name in
# _queueBlend) so the queue moves outward.
sub _similarArtistBlend {
	my ($request, $client, $artist, $ids) = @_;
	my %exclude = map { $_ => 1 } @$ids;     # full known track set for the artist
	my @seeds   = @$ids;
	# Cap the seed set — a prolific artist can have hundreds of tracks and the
	# centroid only needs a representative sample.
	@seeds = @seeds[0 .. (MAX_PICK_RESULTS - 1)] if @seeds > MAX_PICK_RESULTS;
	Plugins::AudioMuseAI::API::alchemy(
		\@seeds, [], _oversample(_count($client)),
		sub { _queueBlend($request, $client, shift, \%exclude, 0, $artist) },
		sub { _notifyError($request, shift) },
	);
}

# Queue an alchemy/blend result, dropping any seed tracks (the $exclude set)
# so the queue moves outward instead of replaying the seeds. $loadFresh as
# per _queueResults (0 = append, 1 = replace). $excludeArtist (optional)
# additionally drops every track by that artist name — search_tracks only
# returns a capped sample of an artist's IDs, so for "music like this artist"
# an ID-only exclude misses the rest; matching on the author name catches
# them all.
sub _queueBlend {
	my ($request, $client, $data, $exclude, $loadFresh, $excludeArtist) = @_;
	$exclude ||= {};
	my $artist_lc = defined $excludeArtist ? lc(_trim($excludeArtist)) : '';
	my $tracks = _extractTracks($data);
	my @keep = grep {
		ref($_) eq 'HASH' && do {
			my $id = $_->{item_id} // $_->{id};
			my $ok = defined $id && !$exclude->{$id};
			if ($ok && length $artist_lc) {
				my $a = lc(_trim($_->{author} // $_->{album_artist} // ''));
				$ok = ($a ne $artist_lc);
			}
			$ok;
		};
	} @$tracks;
	_queueResults($request, $client, \@keep, $loadFresh);
}

sub _sonicFingerprint {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::sonic_fingerprint(
		_loadN($client),
		sub { _queueResults($request, $client, shift, 1) },
		sub { _notifyError($request, shift) },
	);
}

# ----- SemGrove (merged lyrics + audio similarity) --------------------------

sub _semGroveNow {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $song    = Slim::Player::Playlist::song($client);
	unless ($song && $song->id) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NOTHING_PLAYING'));
	}
	$log->info('semgrove_now: track=' . $song->id . ' client=' . $client->id);
	$request->setStatusProcessing;
	my $n = _loadN($client);
	_withAmSeed('' . $song->id,
		sub { Plugins::AudioMuseAI::API::sem_grove($_[0], $n, $_[1], $_[2]) },
		sub { _semGroveQueue($request, $client, shift) },
		sub { _notifyError($request, shift) },
	);
}

sub _semGroveTrack {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $tid     = $request->getParam('track_id');
	return $request->setStatusBadParams unless defined $tid && length $tid;
	$request->setStatusProcessing;
	my $n = _loadN($client);
	_withAmSeed($tid,
		sub { Plugins::AudioMuseAI::API::sem_grove($_[0], $n, $_[1], $_[2]) },
		sub { _semGroveQueue($request, $client, shift) },
		sub { _notifyError($request, shift) },
	);
}

# SemGrove always returns the seed song first (is_seed=true); drop it so we
# don't re-queue the track the user seeded from, then hand off to the normal
# queue path.
sub _semGroveQueue {
	my ($request, $client, $data) = @_;
	my $tracks = _extractTracks($data);
	my @keep = grep { ref($_) eq 'HASH' && !$_->{is_seed} } @$tracks;
	_queueResults($request, $client, \@keep, 1);
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

	my ($query, $steer) = _parseSteering($prompt);
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $query;
	my $run = sub {
		my $steering = shift;
		Plugins::AudioMuseAI::API::clap_search(
			$query, _loadN($client),
			sub {
				_queueResults($request, $client, shift, 1);
				_maybeAutoSave($client, 'instant', $prompt) if $prefs->get('auto_save_instant');
			},
			sub { _notifyError($request, shift) },
			$steering,
		);
	};
	return $run->([]) unless @$steer;

	# Concept steering: terms must come from the server's validated
	# vocabulary — check first so a typo gets a clear message, not a 400.
	Plugins::AudioMuseAI::API::clap_concepts(
		sub {
			my %known = map { lc($_) => 1 } _conceptTerms(shift);
			my @bad = grep { !$known{ $_->{term} } } @$steer;
			if (@bad) {
				return _notify($request, sprintf(string('PLUGIN_AUDIOMUSEAI_STEER_UNKNOWN'),
					join(', ', map { $_->{term} } @bad)));
			}
			$run->($steer);
		},
		sub { _notifyError($request, shift) },
	);
}

# Instant Playlist concept steering (AudioMuse v3.5.1 "Concept Weight").
# Syntax: everything after a '|' is a comma-separated list of concepts:
#   "jazz with viola | +viola x3, -drums, piano"
# '+' (default) = more, '-' = less, "xN" / "*N" = weight (server snaps it to
# 1/2/3/5/10). Returns ($query, [ { term, direction, weight? }, ... ]).
sub _parseSteering {
	my $prompt = shift // '';
	my ($q, $rest) = split /\s*\|\s*/, $prompt, 2;
	$q = _trim($q // '');
	return ($q, []) unless defined $rest && length _trim($rest);
	my @steer;
	for my $tok (split /\s*,\s*/, $rest) {
		$tok = _trim($tok);
		next unless length $tok;
		my $dir = 'more';
		$dir = 'less' if $tok =~ s/\A-\s*//;
		$tok =~ s/\A\+\s*//;
		my $w;
		$w = $1 if $tok =~ s/\s*[x*]\s*(\d+(?:\.\d+)?)\s*\z//i;
		$tok = lc _trim($tok);
		next unless length $tok;
		push @steer, { term => $tok, direction => $dir,
			(defined $w ? (weight => $w + 0) : ()) };
	}
	@steer = @steer[0 .. 9] if @steer > 10;   # server max_terms
	return ($q, \@steer);
}

sub _conceptTerms {
	my $data = shift;
	return () unless ref($data) eq 'HASH' && ref($data->{categories}) eq 'ARRAY';
	return map { $_->{term} }
		grep { ref($_) eq 'HASH' && defined $_->{term} }
		map { ref($_->{terms}) eq 'ARRAY' ? @{ $_->{terms} } : () }
		grep { ref($_) eq 'HASH' } @{ $data->{categories} };
}

# Browse the steering vocabulary (read-only reference for the syntax above).
sub _menuConcepts {
	my $request = shift;
	my $cat = $request->getParam('category') // '';
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::clap_concepts(
		sub {
			my $data = shift;
			my @items;
			my $cats = ref($data) eq 'HASH' && ref($data->{categories}) eq 'ARRAY' ? $data->{categories} : [];
			if (length $cat) {
				my ($c) = grep { ref($_) eq 'HASH' && ($_->{category} // '') eq $cat } @$cats;
				push @items, map { { text => _safeText($_->{term}) } }
					grep { ref($_) eq 'HASH' && defined $_->{term} }
					@{ ($c && ref($c->{terms}) eq 'ARRAY') ? $c->{terms} : [] };
			}
			else {
				push @items, { text => string('PLUGIN_AUDIOMUSEAI_STEER_HELP') };
				for my $c (@$cats) {
					next unless ref($c) eq 'HASH' && defined $c->{category};
					push @items, {
						text    => _safeText($c->{label} // $c->{category}),
						actions => { go => { cmd => ['audiomuseai', 'menu_concepts'], player => 0,
							params => { category => $c->{category} } } },
					};
				}
			}
			push @items, { text => string('PLUGIN_AUDIOMUSEAI_NO_RESULTS') } unless @items;
			_emit($request, \@items, 'PLUGIN_AUDIOMUSEAI_MENU_CONCEPTS');
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
		$prompt, _count($client),
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
		$prompt, _loadN($client),
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
		$prompt, _loadN($client),
		sub {
			_queueResults($request, $client, shift, 1);
			_maybeAutoSave($client, 'mood', $label) if $prefs->get('auto_save_mood');
		},
		sub { _notifyError($request, shift) },
	);
}

# ----- Album Creation (AudioMuse v3.6.2) ------------------------------------
# A sequenced, CD-like album (opener -> closer) built from one seed song or a
# few words, using the MusiCNN + DCLAP + lyrics indexes together. Needs all
# three analyses on the server; it answers 400 otherwise.

sub _albumNow {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $song    = Slim::Player::Playlist::song($client);
	unless ($song && $song->id) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NOTHING_PLAYING'));
	}
	_albumCreate($request, $client, 'song', '' . $song->id);
}

sub _albumTrack {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $tid     = $request->getParam('track_id');
	return $request->setStatusBadParams unless defined $tid && $tid =~ /\A\d+\z/;
	_albumCreate($request, $client, 'song', $tid);
}

sub _albumText {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $prompt  = _trim($request->getParam('prompt') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $prompt;
	_recordRecentPrompt($client, $prompt);
	_albumCreate($request, $client, 'text', $prompt);
}

sub _albumCreate {
	my ($request, $client, $type, $seed) = @_;
	$log->info("album creation ($type): " . _logSafe($seed));
	$request->setStatusProcessing;
	my $call = $type eq 'song'
		? sub { my ($ok, $err) = @_; _withAmSeed($seed,
			sub { Plugins::AudioMuseAI::API::album_creation('song', @_) }, $ok, $err) }
		: sub { Plugins::AudioMuseAI::API::album_creation('text', $seed, @_) };
	$call->(
		sub {
			my $data   = shift;
			my $tracks = ref($data) eq 'HASH' ? $data->{tracks} : undef;
			unless (ref($tracks) eq 'ARRAY' && @$tracks) {
				return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
			}
			my $name = _safeText($data->{suggested_name} // $data->{name} // '');
			# An album keeps its running order and its own length.
			_queueResults($request, $client, $tracks, 1,
				{ want => scalar @$tracks });
			if (length $name) {
				$prefs->client($client)->set('last_instant_prompt', $name);
				_maybeAutoSave($client, 'album', $name) if $prefs->get('auto_save_album');
			}
		},
		sub {
			my $err = shift // '';
			# 400 = feature disabled (needs lyrics + DCLAP) or bad seed;
			# 404 = seed not analysed / too few neighbours.
			return _notify($request, string('PLUGIN_AUDIOMUSEAI_ALBUM_UNAVAILABLE'))
				if $err =~ /\b400\b/;
			return _notify($request, string('PLUGIN_AUDIOMUSEAI_ALBUM_NO_SEED'))
				if $err =~ /\b404\b/;
			_notifyError($request, $err);
		},
	);
}

# ----- Hyperbolic Explorer (AudioMuse v3.3+) ----------------------------------
# Around a seed song: similar (nearest in the hyperbolic map), roots (more
# general / foundational neighbourhood) or niche (more specific, deeper
# cuts). Needs the hyperbolic index (built by an analysis run on v3.3+).

sub _exploreMode {
	my $m = shift // 'similar';
	return grep({ $_ eq $m } qw(similar roots niche)) ? $m : 'similar';
}

sub _exploreNow {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $song    = Slim::Player::Playlist::song($client);
	unless ($song && $song->id) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NOTHING_PLAYING'));
	}
	_exploreRun($request, $client, '' . $song->id, _exploreMode($request->getParam('mode')));
}

sub _exploreTrack {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $tid     = $request->getParam('track_id');
	return $request->setStatusBadParams unless defined $tid && $tid =~ /\A\d+\z/;
	_exploreRun($request, $client, $tid, _exploreMode($request->getParam('mode')));
}

sub _exploreRun {
	my ($request, $client, $seed, $mode) = @_;
	$log->info("hyperbolic explore ($mode) from $seed on " . $client->id);
	$request->setStatusProcessing;
	my $n = _loadN($client);
	_withAmSeed($seed,
		sub { Plugins::AudioMuseAI::API::hyperbolic_similar($_[0], $mode, $n, $_[1], $_[2]) },
		sub { _queueResults($request, $client, shift, 1, { exclude => { $seed => 1 } }) },
		sub {
			my $err = shift // '';
			return _notify($request, string('PLUGIN_AUDIOMUSEAI_EXPLORE_UNAVAILABLE'))
				if $err =~ /\b400\b/;
			_notifyError($request, $err);
		},
	);
}

sub _menuExplore {
	my $request = shift;
	_emit($request, [ map {
		my ($key, $mode) = @$_;
		{
			text    => string($key),
			actions => { go => { cmd => ['audiomuseai', 'explore_now'], player => 0,
				params => { mode => $mode } } },
			nextWindow => 'refresh',
		};
	} (
		['PLUGIN_AUDIOMUSEAI_EXPLORE_SIMILAR', 'similar'],
		['PLUGIN_AUDIOMUSEAI_EXPLORE_ROOTS',   'roots'],
		['PLUGIN_AUDIOMUSEAI_EXPLORE_NICHE',   'niche'],
	) ], 'PLUGIN_AUDIOMUSEAI_MENU_EXPLORE');
}

# ----- Sonic moods (AudioMuse mood centroids) ---------------------------------
# AudioMuse clusters each mood (happy, sad, relaxed, ...) into several sonic
# "flavours", each described by its top tags. Tap-only: mood -> flavour.

sub _menuSonicMoods {
	my $request = shift;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::mood_centroids(
		sub {
			my $data = shift;
			my @items;
			if (ref($data) eq 'HASH') {
				for my $mood (sort keys %$data) {
					next unless ref($data->{$mood}) eq 'ARRAY' && @{ $data->{$mood} };
					push @items, {
						text    => sprintf('%s (%d)', ucfirst($mood), scalar @{ $data->{$mood} }),
						actions => { go => { cmd => ['audiomuseai', 'menu_sonic_mood'],
							player => 0, params => { mood => $mood } } },
					};
				}
			}
			push @items, { text => string('PLUGIN_AUDIOMUSEAI_NO_RESULTS') } unless @items;
			_emit($request, \@items, 'PLUGIN_AUDIOMUSEAI_MENU_SONIC_MOODS');
		},
		sub { _notifyError($request, shift) },
	);
}

sub _menuSonicMood {
	my $request = shift;
	my $mood = _trim($request->getParam('mood') // '');
	return $request->setStatusBadParams unless $mood =~ /\A[\w-]+\z/;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::mood_centroids(
		sub {
			my $data = shift;
			my $list = ref($data) eq 'HASH' ? $data->{$mood} : undef;
			my @items;
			for my $c (ref($list) eq 'ARRAY' ? @$list : ()) {
				next unless ref($c) eq 'HASH' && defined $c->{index};
				my @tags = ref($c->{top_tags}) eq 'ARRAY' ? @{ $c->{top_tags} } : ();
				@tags = @tags[0 .. 2] if @tags > 3;
				my $label = ucfirst($mood) . ': ' . (@tags ? join(', ', @tags) : '#' . ($c->{index} + 1));
				push @items, {
					text    => _safeText($label),
					actions => { go => { cmd => ['audiomuseai', 'sonic_mood'], player => 0,
						params => { mood => $mood, index => $c->{index}, mood_label => _safeText($label) } } },
					nextWindow => 'refresh',
				};
			}
			push @items, { text => string('PLUGIN_AUDIOMUSEAI_NO_RESULTS') } unless @items;
			_emit($request, \@items, 'PLUGIN_AUDIOMUSEAI_MENU_SONIC_MOODS');
		},
		sub { _notifyError($request, shift) },
	);
}

sub _sonicMood {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $mood    = _trim($request->getParam('mood') // '');
	my $index   = $request->getParam('index');
	return $request->setStatusBadParams
		unless $mood =~ /\A[\w-]+\z/ && defined $index && $index =~ /\A\d+\z/;
	my $label = _trim($request->getParam('mood_label') // '') || ucfirst($mood);
	$prefs->client($client)->set('last_mood_label', $label);
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::similar_by_mood($mood, $index, _loadN($client),
		sub {
			_queueResults($request, $client, shift, 1);
			_maybeAutoSave($client, 'mood', $label) if $prefs->get('auto_save_mood');
		},
		sub { _notifyError($request, shift) },
	);
}

# ----- Lyric themes (lyrics axes) ----------------------------------------------
# Tap-only lyrics search: pick an axis (setting, social dynamic, emotional
# valence, ...) then one of its labels (URBAN, MELANCHOLIC, ...).

sub _axisLabel {
	my $k = shift // '';
	$k =~ s/\AAXIS_\d+_//;
	$k =~ s/_/ /g;
	return ucfirst(lc $k);
}

sub _menuLyricThemes {
	my $request = shift;
	my $axis = _trim($request->getParam('axis') // '');
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::lyrics_axes(
		sub {
			my $data = shift;
			my $axes = ref($data) eq 'HASH' && ref($data->{axes}) eq 'HASH' ? $data->{axes} : {};
			my @items;
			if (length $axis) {
				my $labels = ref($axes->{$axis}) eq 'HASH' ? $axes->{$axis}{labels} : undef;
				# Older servers return a plain list of labels per axis.
				my @keys = ref($labels) eq 'HASH' ? sort keys %$labels
				         : ref($axes->{$axis}) eq 'ARRAY' ? @{ $axes->{$axis} } : ();
				for my $l (@keys) {
					my $text = _axisLabel($l);
					push @items, {
						text    => _safeText($text),
						actions => { go => { cmd => ['audiomuseai', 'lyric_theme'], player => 0,
							params => { axis => $axis, label => $l,
								mood_label => _safeText(_axisLabel($axis) . ': ' . $text) } } },
						nextWindow => 'refresh',
					};
				}
			}
			else {
				for my $a (sort keys %$axes) {
					push @items, {
						text    => _safeText(_axisLabel($a)),
						actions => { go => { cmd => ['audiomuseai', 'menu_lyric_themes'],
							player => 0, params => { axis => $a } } },
					};
				}
			}
			push @items, { text => string('PLUGIN_AUDIOMUSEAI_LYRICS_THEMES_NONE') } unless @items;
			_emit($request, \@items, 'PLUGIN_AUDIOMUSEAI_MENU_LYRIC_THEMES');
		},
		sub { _notifyError($request, shift) },
	);
}

sub _lyricTheme {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $axis    = _trim($request->getParam('axis')  // '');
	my $label   = _trim($request->getParam('label') // '');
	return $request->setStatusBadParams
		unless $axis =~ /\A\w+\z/ && $label =~ /\A[\w-]+\z/;
	my $name = _trim($request->getParam('mood_label') // '') || _axisLabel($label);
	$prefs->client($client)->set('last_mood_label', $name);
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::lyrics_search_axes({ $axis => $label }, _loadN($client),
		sub {
			_queueResults($request, $client, shift, 1);
			_maybeAutoSave($client, 'mood', $name) if $prefs->get('auto_save_mood');
		},
		sub {
			my $err = shift // '';
			return _notify($request, string('PLUGIN_AUDIOMUSEAI_LYRICS_NO_MATCH'))
				if $err =~ /\b404\b|no lyrics/i;
			_notifyError($request, $err);
		},
	);
}

# ----- Saved anchors -------------------------------------------------------------

sub _anchorPlay {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $aid     = $request->getParam('anchor_id');
	return $request->setStatusBadParams unless defined $aid && $aid =~ /\A\d+\z/;
	my $n = $request->getParam('n');
	$n = _count($client) unless defined $n && $n =~ /\A\d+\z/ && $n > 0;
	$n = FETCH_MAX if $n > FETCH_MAX;
	my $name = _trim($request->getParam('name') // '');
	$prefs->client($client)->set('last_mood_label', $name) if length $name;
	$request->setStatusProcessing;
	Plugins::AudioMuseAI::API::similar_by_anchor($aid, $n + 10,
		sub { _queueResults($request, $client, shift, 1, { want => $n }) },
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
	_notify($request, sprintf('ADDED to %s: %s - %s (%d in list)',
		uc($bucket),
		$song->title      // '?',
		$song->artistName // '?',
		scalar @$list));
}

sub _alchemyAddArtist { _alchemyArtistTo($_[0], 'add'); }
sub _alchemySubArtist { _alchemyArtistTo($_[0], 'sub'); }

# Put the current track's artist (Lyrion contributor id — AudioMuse maps it
# to its artist index) into the ADD / SUBTRACT list as "artist:<id>".
sub _alchemyArtistTo {
	my ($request, $bucket) = @_;
	my $client = $request->client or return $request->setStatusBadParams;
	my $song   = Slim::Player::Playlist::song($client);
	my $artist = $song ? eval { $song->artist } : undef;
	my $aid    = $artist ? eval { $artist->id } : undef;
	unless (defined $aid) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NOTHING_PLAYING'));
	}
	_alchemyStoreRef($request, $client, $bucket, "artist:$aid",
		_safeText(eval { $artist->name } // '?'));
}

# Pick a Lyrion playlist or a saved anchor to ADD.
sub _alchemyPick {
	my $request = shift;
	my $kind = $request->getParam('kind') // '';
	my $item = sub {
		my ($ref, $label) = @_;
		return {
			text    => _safeText($label),
			actions => { go => { cmd => ['audiomuseai', 'alchemy_add_ref'], player => 0,
				params => { ref => $ref, label => _safeText($label) } } },
			nextWindow => 'refresh',
		};
	};
	if ($kind eq 'anchor') {
		$request->setStatusProcessing;
		return Plugins::AudioMuseAI::API::list_anchors(
			sub {
				my $d = shift;
				my $list = ref($d) eq 'HASH' && ref($d->{anchors}) eq 'ARRAY' ? $d->{anchors} : [];
				my @items = map { $item->("anchor:$_->{id}", $_->{name} // "#$_->{id}") }
					grep { ref($_) eq 'HASH' && defined $_->{id} } @$list;
				push @items, { text => string('PLUGIN_AUDIOMUSEAI_RADIOS_NONE') } unless @items;
				_emit($request, \@items, 'PLUGIN_AUDIOMUSEAI_ALCHEMY_ADD_ANCHOR');
			},
			sub { _notifyError($request, shift) },
		);
	}
	my @items;
	eval {
		my $req = Slim::Control::Request::executeRequest(undef, ['playlists', 0, 200]);
		for my $p (@{ ($req && $req->getResult('playlists_loop')) || [] }) {
			next unless defined $p->{id};
			push @items, $item->("playlist:$p->{id}", $p->{playlist} // "#$p->{id}");
		}
	};
	$log->warn("alchemy playlist list failed: $@") if $@;
	push @items, { text => string('PLUGIN_AUDIOMUSEAI_NO_RESULTS') } unless @items;
	_emit($request, \@items, 'PLUGIN_AUDIOMUSEAI_ALCHEMY_ADD_PLAYLIST');
}

sub _alchemyAddRef {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $ref     = $request->getParam('ref') // '';
	return $request->setStatusBadParams unless $ref =~ /\A(?:playlist|anchor|artist):\d+\z/;
	_alchemyStoreRef($request, $client, 'add', $ref,
		_trim($request->getParam('label') // '') || $ref);
}

# Labels for non-song alchemy entries, so "Show" can describe them.
sub _alchemyStoreRef {
	my ($request, $client, $bucket, $ref, $label) = @_;
	my $key  = "alchemy_$bucket";
	my $list = _alchemyList($client, $key);
	push @$list, $ref unless grep { $_ eq $ref } @$list;
	$prefs->client($client)->set($key, $list);
	my $labels = $prefs->client($client)->get('alchemy_labels');
	$labels = {} unless ref($labels) eq 'HASH';
	$labels->{$ref} = $label;
	$prefs->client($client)->set('alchemy_labels', $labels);
	_notify($request, sprintf('ADDED to %s: %s (%d in list)',
		uc($bucket), _alchemyRefLabel($client, $ref), scalar @$list));
}

sub _alchemyRefLabel {
	my ($client, $ref) = @_;
	return _trackLabel($ref) unless $ref =~ /\A(artist|playlist|anchor):/;
	my $type = ucfirst $1;
	my $labels = $client ? $prefs->client($client)->get('alchemy_labels') : undef;
	my $name = ref($labels) eq 'HASH' ? $labels->{$ref} : undef;
	return "$type: " . ($name // $ref);
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
		push @lines, map { '  + ' . _alchemyRefLabel($client, $_) } @$a;
	}
	if (@$s) {
		push @lines, sprintf('SUBTRACT (%d):', scalar @$s);
		push @lines, map { '  - ' . _alchemyRefLabel($client, $_) } @$s;
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
	$prefs->client($client)->set('alchemy_labels', {});
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
		[ map { _amId($_) } @track_ids ], [], _loadN($client),
		sub { _queueResults($request, $client, shift, 1,
			{ exclude => { map { $_ => 1 } @track_ids } }) },
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
	my $am = sub { [ map { /\A\d+\z/ ? _amId($_) : $_ } @{ $_[0] } ] };
	Plugins::AudioMuseAI::API::alchemy(
		$am->($a), $am->($s), _loadN($client),
		sub { _queueResults($request, $client, shift, 1,
			{ exclude => { map { $_ => 1 } grep { /\A\d+\z/ } @$a, @$s } }) },
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

# Path methods: sonic (MusiCNN audio index), lyrics (merged lyrics+audio
# SemGrove index — path_space=lyrics), hyperbolic (v3.5 geodesic journey
# through the two songs' shared musical "ancestor").
sub _findPathMethod {
	my $m = shift // 'sonic';
	return grep({ $_ eq $m } qw(sonic lyrics hyperbolic)) ? $m : 'sonic';
}

sub _findPathSearch {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	my $song    = Slim::Player::Playlist::song($client);
	unless ($song && $song->id) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_FINDPATH_NO_START'));
	}
	my $artist = _trim($request->getParam('artist') // '');
	return _notify($request, string('PLUGIN_AUDIOMUSEAI_EMPTY_INPUT')) unless length $artist;
	my $method = _findPathMethod($request->getParam('method'));

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
				{ start_id => "$start_id", method => $method },
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
	my $method = _findPathMethod($request->getParam('method'));
	$log->info("findpath ($method): $start -> $end");
	$request->setStatusProcessing;
	my $ok  = sub { _queueResults($request, $client, shift, 1, { path => 1 }) };
	my $err = sub { _notifyError($request, shift) };
	if ($method eq 'hyperbolic') {
		# length counts both endpoints.
		Plugins::AudioMuseAI::API::hyperbolic_journey(
			_amId($start), _amId($end), FINDPATH_MAX_STEPS + 2, $ok, $err);
	}
	else {
		Plugins::AudioMuseAI::API::find_path(
			_amId($start), _amId($end), FINDPATH_MAX_STEPS, $ok, $err,
			$method eq 'lyrics' ? 'lyrics' : 'audio');
	}
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

sub _dynamicSemGrove {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	_ensureDstmEnabled();
	$prefs->client($client)->set('dstm_active', 'semgrove');
	$log->info("DSTM mode 'semgrove' active for " . $client->id);
	_semGroveNow($request);
}

# Album mode: start by appending a blend of the current album, then keep
# extending album-by-album from whatever is last in the queue.
sub _dynamicAlbum {
	my $request = shift;
	my $client  = $request->client or return $request->setStatusBadParams;
	_ensureDstmEnabled();
	$prefs->client($client)->set('dstm_active', 'album');
	$log->info("DSTM mode 'album' active for " . $client->id);
	$request->setStatusProcessing;
	_extendFetch($client, 'album', _count($client), sub {
		_queueResults($request, $client, shift, 0);
	});
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

# ----- Native Don't Stop The Music providers --------------------------------
# LMS calls these when a player whose "Don't Stop The Music" handler is set
# to one of ours runs low on queued tracks. Each handler must call
# $cb->($client, \@trackUrls). We reuse the same AudioMuse endpoints as the
# menu-based modes and map the returned IDs to local LMS track URLs (DSTM
# consumes URLs, not IDs).

sub _dstmMixSimilar     { _dstmMix('similar',     @_) }
sub _dstmMixAlbum       { _dstmMix('album',       @_) }
sub _dstmMixFingerprint { _dstmMix('fingerprint', @_) }
sub _dstmMixSemGrove    { _dstmMix('semgrove',    @_) }

# "Mix by album" (discussion #686 — wirrunna) seeds alchemy with every track
# of the last queued track's album and keeps the album's own tracks out, so
# the queue continues outward rather than replaying the album. All modes go
# through _extendFetch, i.e. the anti-repeat engine (queue + history +
# same-song filtering, with fallback seeds when one runs dry).
sub _dstmMix {
	my ($mode, $client, $cb) = @_;
	return $cb->($client, []) unless $client && $cb;
	$log->info("DSTM $mode mix on " . $client->id);
	_extendFetch($client, $mode, _dstmBatch($client), sub {
		my $rows = shift;
		_noteAdded($client, $rows);
		$cb->($client, _dstmTrackUrls($rows));
	});
}

sub _dstmBatch {
	my $client = shift;
	my $n = _count($client);
	return $n > 25 ? 25 : $n;
}

# Seed from the last track in the player's queue — the trailing context
# DSTM is trying to continue from. Returns a track ID or undef.
sub _dstmSeedTrackId {
	my $client = shift or return undef;
	my $count = Slim::Player::Playlist::count($client) or return undef;
	my $track = Slim::Player::Playlist::track($client, $count - 1);
	return undef unless $track && eval { $track->id };
	return $track->id;
}

# All track IDs of the album the player's last queued track belongs to —
# the seed set for the "mix by album" DSTM provider.
sub _dstmSeedAlbumTrackIds {
	my $client = shift or return undef;
	my $count = Slim::Player::Playlist::count($client) or return undef;
	my $track = Slim::Player::Playlist::track($client, $count - 1) or return undef;
	my @ids;
	eval {
		my $album = $track->album or return;
		my $rs = $album->tracks;
		while (my $t = $rs->next) {
			push @ids, '' . $t->id if $t && defined $t->id;
		}
	};
	$log->warn("DSTM album seed lookup failed: $@") if $@;
	return \@ids;
}

# Map (already filtered) AudioMuse rows to local LMS track URLs — DSTM
# consumes URLs, not ids. Skips anything not resolvable in the library.
sub _dstmTrackUrls {
	my $rows = shift;
	my @urls;
	for my $t (@{ _extractTracks($rows) }) {
		my $id = $t->{item_id} // $t->{id};
		next unless defined $id && $id =~ /\A\d+\z/;
		my $obj = eval { Slim::Schema->find('Track', $id) } or next;
		my $url = eval { $obj->url };
		push @urls, $url if defined $url && length $url;
	}
	$log->info('DSTM mix returning ' . scalar(@urls) . ' track URL(s)');
	return \@urls;
}

# True when the player's native "Don't Stop The Music" handler is one of
# ours — meaning native DSTM will do the extending and the menu-based
# _onNewSong path should stand down to avoid double-filling the queue.
sub _nativeDstmIsOurs {
	my $client = shift or return 0;
	my $prov = eval {
		preferences('plugin.dontstopthemusic')->client($client)->get('provider');
	};
	return 0 unless defined $prov && length $prov;
	return $prov eq 'PLUGIN_AUDIOMUSEAI_DSTM_SIMILAR'
		|| $prov eq 'PLUGIN_AUDIOMUSEAI_DSTM_ALBUM'
		|| $prov eq 'PLUGIN_AUDIOMUSEAI_DSTM_FINGERPRINT'
		|| $prov eq 'PLUGIN_AUDIOMUSEAI_DSTM_SEMGROVE';
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
	push @lines, join(' / ', @hdr) if @hdr;

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
	} elsif ($kind eq 'album') {
		$name = sprintf('AudioMuse album: %s', $label);
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
	# $opts->{push}   = 1  -> action returns a new menu (no nextWindow)
	#                         Default is action returns a notification.
	# $opts->{params}      -> extra static params merged into the action
	#                         alongside the typed value (e.g. a `target`).
	$opts ||= {};
	my %params = ($paramName => '__TAGGEDINPUT__');
	if (ref $opts->{params} eq 'HASH') {
		%params = (%{ $opts->{params} }, %params);
	}
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
				params => \%params,
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
			text => sprintf('... (%d more not shown)', @$tracks - $cap),
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
	# nextWindow makes Material's canClickItem() return true for this lone
	# item, which stops Material wrapping a single text item's title in a
	# <div style="margin-top:16px;...">…</div> that its text-input result
	# view then renders literally (issue #1 — only the text-entry features
	# hit it). Harmless on every controller: a notification is rarely
	# tapped and 'refresh' is a no-op in that context.
	_emit($request, [{ text => $msg // '', nextWindow => 'refresh' }]);
}

sub _notifyLines {
	my ($request, $lines) = @_;
	$lines ||= [];
	$lines = ['No status returned.'] unless @$lines;
	my @items = map { { text => "$_" } } @$lines;
	# A single-line status hits the same Material single-text-item <div>
	# wrap as _notify; give it a nextWindow so canClickItem() is true.
	$items[0]{nextWindow} = 'refresh' if @items == 1;
	_emit($request, \@items);
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

	# A wrong "AudioMuse music server name" makes AudioMuse answer 400
	# ("Invalid server selection") to everything — point at the setting.
	if ($err =~ /\b400\b/ && length(_trim($prefs->get('server_name') // ''))) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_SERVER_NAME_REJECTED'));
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
				push @lines, join(' / ', @hdr) if @hdr;
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

# Queue an AudioMuse result. $loadFresh: 1 = replace the queue, 0 = append.
# $opts (optional):
#   want    => max tracks to queue (default: the player's count setting)
#   exclude => { id => 1 } extra ids to keep out (seeds)
#   path    => 1 for ordered paths (keeps the destination; see _dedupePath)
# Appends are filtered against the queue + player history (no repeats);
# fresh loads are de-duplicated within themselves (same song, other copy).
sub _queueResults {
	my ($request, $client, $data, $loadFresh, $opts) = @_;
	$opts ||= {};
	my $tracks = _localizeRows(_extractTracks($data));
	unless (@$tracks) {
		return _notify($request, string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
	}
	my $want = $opts->{want} || _count($client);
	my $excl = $loadFresh ? { ids => {}, keys => {} } : _exclusionSet($client, 1);
	$excl->{ids}{$_} = 1 for keys %{ $opts->{exclude} || {} };

	my $rows;
	if ($opts->{path}) {
		$rows = $loadFresh ? _dedupePath($tracks) : _freshRows($tracks, $excl);
	}
	else {
		$rows = _freshRows($tracks, $excl, $want);
	}
	# Only Lyrion-numeric ids (anything else would crash playlistcontrol).
	my @ids = grep { defined && /\A\d+\z/ }
		map { $_->{item_id} // $_->{id} } @$rows;
	unless (@ids) {
		return _notify($request, string($loadFresh
			? 'PLUGIN_AUDIOMUSEAI_NO_RESULTS'
			: 'PLUGIN_AUDIOMUSEAI_NO_NEW_TRACKS'));
	}
	my $cmd = $loadFresh ? 'load' : 'add';
	# A fresh load replaces the queue, so earlier adds no longer matter.
	if ($loadFresh) { delete $_recentAdds{ $client->id } } else { _noteAdded($client, $rows) }
	$log->info(sprintf('queueing %d tracks (%s) on %s (%d offered)',
		scalar @ids, $cmd, $client->id, scalar @$tracks));
	Slim::Control::Request::executeRequest(
		$client,
		['playlistcontrol', "cmd:$cmd", 'track_id:' . join(',', @ids)]
	);
	# Compact summary: "Queued 25 tracks (replace queue)" / "...append".
	my $verb = $loadFresh ? 'replaced queue' : 'appended to queue';
	_notify($request, sprintf('%s - %d tracks %s.',
		string('PLUGIN_AUDIOMUSEAI_QUEUED'), scalar @ids, $verb));
}

# Subscriber: remember every song that starts playing (anti-repeat history)
# and auto-extend the queue if a menu-started dynamic mode is active.
sub _onNewSong {
	my $request = shift;
	my $client  = $request->client or return;
	my $song    = Slim::Player::Playlist::song($client) or return;

	_rememberTrackObj($client, $song);

	my $mode = $prefs->client($client)->get('dstm_active') or return;
	return unless $prefs->get('dstm_enabled');
	# If native DSTM is set to one of our providers for this player, let it
	# do the extending — don't also fire the menu-based mode (issue #2).
	return if _nativeDstmIsOurs($client);

	my $remaining = Slim::Player::Playlist::count($client)
		- Slim::Player::Source::streamingSongIndex($client) - 1;
	return if $remaining > 3;

	my $cid = $client->id;
	return if $_extending{$cid} && time() - $_extending{$cid} < 120;
	$_extending{$cid} = time();

	$log->info("DSTM auto-extend mode=$mode remaining=$remaining client=$cid");

	_extendFetch($client, $mode, EXTEND_BATCH, sub {
		my $rows = shift;
		delete $_extending{$cid};
		my @ids = map { $_->{item_id} // $_->{id} } @$rows;
		unless (@ids) {
			$log->info("DSTM auto-extend found no new tracks on $cid");
			return;
		}
		_noteAdded($client, $rows);
		$log->info('DSTM auto-extend adding ' . scalar(@ids) . " new track(s) on $cid");
		Slim::Control::Request::executeRequest(
			$client,
			['playlistcontrol', 'cmd:add', 'track_id:' . join(',', @ids)]
		);
	});
	# Note: the alchemy *builder* (add/sub lists) is intentionally not a
	# dynamic mode — its meaning is "blend these tracks", not "keep going".
}

# ===========================================================================
# Anti-repeat engine
# ===========================================================================
# AudioMuse answers each request statelessly, so chaining "similar to the
# current track" quickly loops: A's neighbours include B, B's include A, and
# a cluster of ~60 songs gets replayed over and over (measured: 64 unique in
# a 205-track auto-extended queue, one song 17 times). Sonic Fingerprint is
# deterministic and returned the identical list on every call. So every
# append / extend path filters candidates against:
#   - every track already in the player's queue,
#   - the player's recent play history (HISTORY_MAX deep — songs that
#     actually started playing, so a replaced-unheard queue doesn't count), and
#   - a normalised "artist|title" key, so another copy of the same song
#     (album vs single vs compilation vs "(Live)" / "(Remastered)") with a
#     different track id doesn't slip through either.
# Results are over-fetched so there's still a full batch after filtering,
# and extends fall back to other seeds when one is exhausted.

# Normalised identity of a song for duplicate detection.
sub _trackKey {
	my ($title, $artist) = @_;
	$title  = lc(_trim($title  // ''));
	$artist = lc(_trim($artist // ''));
	# Drop bracketed qualifiers: (Live), [Remastered 2011], (feat. X)...
	$title =~ s/\s*[\(\[][^\)\]]*[\)\]]//g;
	# ...and dash-suffixed ones: "Song - 2011 Remaster", "Song - Live at X".
	$title =~ s/\s+-\s+.*\b(?:remaster\w*|live|version|edit|mix|mono|stereo|demo|acoustic)\b.*\z//;
	# Primary artist only: AudioMuse may credit "OneRepublic, Becky G" where
	# Lyrion says "OneRepublic"; featured / secondary artists don't make it
	# a different song.
	$artist =~ s/\s*(?:[,;\/&+]|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b|\bx\b|\band\b).*\z//;
	$title  =~ s/[^\p{L}\p{N}]+//g;
	$artist =~ s/[^\p{L}\p{N}]+//g;
	return undef unless length $title;
	return "$artist|$title";
}

sub _rowKey {
	my $t = shift;
	return _trackKey($t->{title}, $t->{author} // $t->{artist} // $t->{album_artist});
}

sub _hist {
	my $client = shift;
	return $_history{ $client->id } ||= { order => [], ids => {}, keys => {} };
}

sub _remember {
	my ($client, $id, $key) = @_;
	return unless $client;
	my $h = _hist($client);
	$h->{ids}{$id}++   if defined $id;
	$h->{keys}{$key}++ if defined $key;
	push @{ $h->{order} }, [$id, $key];
	while (@{ $h->{order} } > HISTORY_MAX) {
		my ($oid, $okey) = @{ shift @{ $h->{order} } };
		delete $h->{ids}{$oid}   if defined $oid  && --$h->{ids}{$oid}   <= 0;
		delete $h->{keys}{$okey} if defined $okey && --$h->{keys}{$okey} <= 0;
	}
}

# Note rows we're about to add to a player's queue (see %_recentAdds).
sub _noteAdded {
	my ($client, $rows) = @_;
	return unless $client;
	my $ra  = $_recentAdds{ $client->id } ||= {};
	my $now = time();
	for my $t (@{ $rows || [] }) {
		my $id = $t->{item_id} // $t->{id};
		$ra->{$id} = [$now, _rowKey($t)] if defined $id;
	}
}

sub _rememberTrackObj {
	my ($client, $track) = @_;
	return unless $track;
	my $id = eval { $track->id };
	return unless defined $id && $id =~ /\A\d+\z/;
	my $key = eval { _trackKey($track->title, $track->artistName) };
	_remember($client, "$id", $key);
}

# Ids + keys to keep out of an append: the whole current queue, plus the
# player's history when $withHistory.
sub _exclusionSet {
	my ($client, $withHistory) = @_;
	my %ids; my %keys;
	if ($client) {
		my $count = Slim::Player::Playlist::count($client) || 0;
		# Very long queues: the newest 2000 entries are what matters.
		my $from = $count > 2000 ? $count - 2000 : 0;
		for my $i ($from .. $count - 1) {
			my $t = Slim::Player::Playlist::track($client, $i) or next;
			my $id = eval { $t->id };
			next unless defined $id;
			$ids{$id} = 1;
			my $key = eval { _trackKey($t->title, $t->artistName) };
			$keys{$key} = 1 if defined $key;
		}
		if ($withHistory) {
			my $h = _hist($client);
			$ids{$_}  = 1 for keys %{ $h->{ids} };
			$keys{$_} = 1 for keys %{ $h->{keys} };
		}
		my $ra = $_recentAdds{ $client->id } || {};
		my $now = time();
		for my $id (keys %$ra) {
			if ($now - $ra->{$id}[0] > RECENT_ADD_TTL) { delete $ra->{$id}; next; }
			$ids{$id} = 1;
			$keys{ $ra->{$id}[1] } = 1 if defined $ra->{$id}[1];
		}
	}
	return { ids => \%ids, keys => \%keys };
}

# Filter result rows: Lyrion-numeric ids only, nothing in $excl (by id or
# song key), no duplicates within the rows. Accepted rows are added to
# $excl, so calling it again across fallback attempts keeps accumulating.
# Returns at most $want rows (all when $want is 0/undef).
sub _freshRows {
	my ($rows, $excl, $want) = @_;
	$excl ||= { ids => {}, keys => {} };
	my @out;
	for my $t (@{ $rows || [] }) {
		last if $want && @out >= $want;
		next unless ref($t) eq 'HASH';
		my $id = $t->{item_id} // $t->{id};
		next unless defined $id && $id =~ /\A\d+\z/;
		next if $excl->{ids}{$id};
		my $key = _rowKey($t);
		next if defined $key && $excl->{keys}{$key};
		$excl->{ids}{$id} = 1;
		$excl->{keys}{$key} = 1 if defined $key;
		push @out, $t;
	}
	return \@out;
}

# AudioMuse's map of Lyrion track ids goes stale when Lyrion rescans and
# renumbers tracks (seen live: ~1 in 4 results pointed at ids Lyrion no
# longer has; playlistcontrol silently drops those). Resolve every row to a
# real local track: by id, else by title + primary artist via Lyrion's own
# search. Rows come back carrying LYRION's id/title/artist, so song keys are
# computed from the same metadata as the queue side.
sub _localizeRows {
	my $rows = shift;
	my (@out, $stale, $recovered);
	for my $t (@{ $rows || [] }) {
		next unless ref($t) eq 'HASH';
		my $id  = $t->{item_id} // $t->{id};
		my $obj = (defined $id && $id =~ /\A\d+\z/)
			? eval { Slim::Schema->find('Track', $id) } : undef;
		unless ($obj) {
			$stale++;
			$obj = _findLocalByTitle($t) or next;
			$recovered++;
		}
		my $lid = eval { $obj->id } // next;
		if (defined $id && "$id" ne "$lid") {
			%_amIdFor = () if keys %_amIdFor > 50000;
			$_amIdFor{$lid} = "$id";
		}
		push @out, { %$t,
			item_id => "$lid",
			title   => (eval { $obj->title }      // $t->{title}),
			author  => (eval { $obj->artistName } // $t->{author} // $t->{artist}),
		};
	}
	$log->info(sprintf('%d result id(s) not in the Lyrion library (stale AudioMuse '
		. 'mapping - run "Align music servers" in AudioMuse); %d recovered by title',
		$stale, $recovered // 0)) if $stale;
	return \@out;
}

sub _findLocalByTitle {
	my $t = shift;
	my $want = _rowKey($t) or return undef;
	my $title = _trim($t->{title} // '');
	return undef unless length $title;
	my $hit;
	eval {
		my $req = Slim::Control::Request::executeRequest(undef,
			['titles', 0, 20, "search:$title", 'tags:a']);
		for my $r (@{ ($req && $req->getResult('titles_loop')) || [] }) {
			next unless defined $r->{id};
			my $k = _trackKey($r->{title}, $r->{artist});
			next unless defined $k && $k eq $want;
			$hit = Slim::Schema->find('Track', $r->{id}) and last;
		}
	};
	return $hit;
}

# The id AudioMuse knows a Lyrion track by (they differ after a rescan).
sub _amId {
	my $id = shift;
	return defined $id && exists $_amIdFor{$id} ? $_amIdFor{$id} : $id;
}

# Run $call->($audioMuseId, $ok, $err) for Lyrion track $tid. If AudioMuse
# answers 404 (it doesn't know this Lyrion id — renumbered by a rescan and
# not yet re-mapped), look the song up in AudioMuse by artist + title and
# retry once with AudioMuse's own id for it.
sub _withAmSeed {
	my ($tid, $call, $ok, $err) = @_;
	my $first = _amId($tid);
	$call->($first, $ok, sub {
		my $e = shift // '';
		return $err->($e) unless $e =~ /\b404\b/;
		my $obj    = eval { Slim::Schema->find('Track', $tid) } or return $err->($e);
		my $title  = eval { $obj->title }      // '';
		my $artist = eval { $obj->artistName } // '';
		my $want   = _trackKey($title, $artist) or return $err->($e);
		Plugins::AudioMuseAI::API::search_query("$artist $title",
			sub {
				my $rows = shift;
				my ($hit) = grep {
					ref($_) eq 'HASH' && defined $_->{item_id}
						&& $_->{item_id} ne $first && (_rowKey($_) // '') eq $want
				} (ref($rows) eq 'ARRAY' ? @$rows : ());
				return $err->($e) unless $hit;
				$_amIdFor{$tid} = '' . $hit->{item_id};
				$log->info("track $tid unknown to AudioMuse; using its id $hit->{item_id} for the same song");
				$call->($_amIdFor{$tid}, $ok, $err);
			},
			sub { $err->($e) },
		);
	});
}

# Paths (find path / journeys) must keep their final song: dedupe the
# middle against the endpoints rather than letting an earlier copy of the
# destination knock the destination itself out.
sub _dedupePath {
	my $rows = shift;
	my @r = grep { ref($_) eq 'HASH' } @{ $rows || [] };
	return \@r if @r < 3;
	my $last = $r[-1];
	my $excl = { ids => {}, keys => {} };
	my $lid  = $last->{item_id} // $last->{id};
	$excl->{ids}{$lid} = 1 if defined $lid;
	my $lkey = _rowKey($last);
	$excl->{keys}{$lkey} = 1 if defined $lkey;
	my $mid = _freshRows([ @r[0 .. $#r - 1] ], $excl);
	return [ @$mid, $last ];
}

# Request size for a fresh load: a little headroom so de-duplicating
# (same song, other copy) still leaves a full playlist.
sub _loadN {
	my $n = _count(shift) + 10;
	return $n > FETCH_MAX ? FETCH_MAX : $n;
}

# How many to ask AudioMuse for so $want survive the filters.
sub _oversample {
	my $want = shift || 10;
	my $n = $want * 3 + 10;
	$n = 30 if $n < 30;
	$n = FETCH_MAX if $n > FETCH_MAX;
	return $n;
}

# The last few track ids in the queue (newest last) — seeds for extends.
sub _queueTailIds {
	my ($client, $max) = @_;
	my $count = Slim::Player::Playlist::count($client) || 0;
	my @ids;
	for (my $i = $count - 1; $i >= 0 && @ids < $max; $i--) {
		my $t = Slim::Player::Playlist::track($client, $i) or next;
		my $id = eval { $t->id };
		unshift @ids, "$id" if defined $id && $id =~ /\A\d+\z/;
	}
	return \@ids;
}

# Run fetch attempts in order until $want fresh rows are collected (or the
# attempts run out). Each attempt is sub { my ($ok, $err) = @_; API... }.
# $done->(\@rows, $lastError) — the error only matters when no rows came back.
sub _runAttempts {
	my ($attempts, $excl, $want, $done, $got, $lastErr) = @_;
	$got ||= [];
	return $done->($got, $lastErr) if @$got >= $want || !@$attempts;
	my ($first, @rest) = @$attempts;
	my $next = sub { _runAttempts(\@rest, $excl, $want, $done, @_) };
	$first->(
		sub {
			my $fresh = _freshRows(_localizeRows(_extractTracks(shift)), $excl, $want - @$got);
			$next->([ @$got, @$fresh ], $lastErr);
		},
		sub {
			my $err = shift // 'unknown';
			$log->info("fetch attempt failed: $err");
			$next->($got, $err);
		},
	);
}

# User-requested "similar to <track>" APPEND: new tracks only, widening the
# fetch once if the first batch is all already queued / recently played.
sub _appendSimilar {
	my ($request, $client, $seed) = @_;
	my $want  = _count($client);
	my $excl  = _exclusionSet($client, 1);
	$excl->{ids}{$seed} = 1;
	my $fetch = _oversample($want);
	my $sim = sub { my $n = shift; sub { _withAmSeed($seed, sub {
		Plugins::AudioMuseAI::API::similar_tracks($_[0], $n, $_[1], $_[2]) }, @_) } };
	my @attempts = ($sim->($fetch));
	push @attempts, $sim->(FETCH_MAX) if $fetch < FETCH_MAX;
	$request->setStatusProcessing;
	_runAttempts(\@attempts, $excl, $want, sub {
		my ($rows, $err) = @_;
		return _notifyError($request, $err) if !@$rows && defined $err;
		_queueResults($request, $client, $rows, 0, { exclude => { $seed => 1 } });
	});
}

# Fetch $want NEW tracks to continue the player's queue in $mode
# (similar | semgrove | album | fingerprint), then $done->(\@rows).
sub _extendFetch {
	my ($client, $mode, $want, $done) = @_;
	my $excl  = _exclusionSet($client, 1);
	my $fetch = _oversample($want);
	my $tail  = _queueTailIds($client, 5);
	my $last  = $tail->[-1];

	my $similar = sub {
		my $seed = shift;
		return () unless $seed;
		return sub { _withAmSeed($seed, sub {
			Plugins::AudioMuseAI::API::similar_tracks($_[0], $fetch, $_[1], $_[2]) }, @_) };
	};
	# Blend of the last few queued tracks (temperature > 0 samples, so it
	# also varies between calls) — the general-purpose fallback.
	my @amTail = map { _amId($_) } @$tail;
	my $blend = @amTail
		? sub { Plugins::AudioMuseAI::API::alchemy(\@amTail, [], $fetch, @_) }
		: ();

	my @attempts;
	if ($mode eq 'fingerprint') {
		# Deterministic for a given listening history, so widen the window
		# by how much this player has already heard.
		my $hist = scalar @{ _hist($client)->{order} };
		my $n = $fetch + $hist;
		$n = FETCH_MAX if $n > FETCH_MAX;
		push @attempts, sub { Plugins::AudioMuseAI::API::sonic_fingerprint($n, @_) };
		push @attempts, $similar->($last), $blend;
	}
	elsif ($mode eq 'album') {
		my $ids = _dstmSeedAlbumTrackIds($client) || [];
		$excl->{ids}{$_} = 1 for @$ids;
		my @amIds = map { _amId($_) } @$ids;
		push @attempts, sub { Plugins::AudioMuseAI::API::alchemy(\@amIds, [], $fetch, @_) }
			if @amIds;
		push @attempts, $similar->($last), $blend;
	}
	elsif ($mode eq 'semgrove') {
		push @attempts, sub { _withAmSeed($last, sub {
			Plugins::AudioMuseAI::API::sem_grove($_[0], $fetch, $_[1], $_[2]) }, @_) }
			if $last;
		push @attempts, $similar->($last), $blend;
	}
	else { # similar
		push @attempts, $similar->($last), $blend;
		# Last resort: an earlier queue track as a fresh seed.
		push @attempts, $similar->($tail->[0]) if @$tail > 1;
	}
	_runAttempts([ grep { $_ } @attempts ], $excl, $want, $done);
}

1;
