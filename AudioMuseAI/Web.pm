package Plugins::AudioMuseAI::Web;

# Default web UI support (issue #6): puts "AudioMuse-AI" under My Music on
# Lyrion's Default / Classic skins, next to Random Mix etc.
#
# Those skins only show plugins that provide an XMLBrowser (OPML) feed; the
# plugin's menus are Jive item_loops for controllers (Material, iPeng,
# Squeezer, Jive players). Instead of a second hand-written copy of every
# menu, this adapter runs the SAME `audiomuseai ...` dispatch commands and
# converts their item_loop into OPML on the fly:
#   - item with actions.go        -> 'link' that runs that command
#   - item with an `input` block  -> 'search' box; the typed text replaces
#                                     the __TAGGEDINPUT__ parameter
#   - anything else               -> plain 'text' (notifications, headers)
# So every menu, picker and action — and anything added later — shows up in
# the web UI with no extra code.

use strict;
use warnings;

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Web::Pages;
use Slim::Web::XMLBrowser;
use URI::Escape qw(uri_escape_utf8);

my $log = logger('plugin.audiomuseai');

use constant URL     => 'plugins/AudioMuseAI/index.html';
# Context-menu (track / artist / album info) entries link here: the Default
# skin needs a URL string for them, not a callback.
use constant RUN_URL => 'plugins/AudioMuseAI/run.html';

# Commands the run page will execute, and the params each may take.
my %RUN_CMDS = (
	similar_track  => [qw(track_id)],
	semgrove_track => [qw(track_id)],
	album_track    => [qw(track_id)],
	explore_track  => [qw(track_id mode)],
	similar_artist => [qw(artist artist_id)],
	alchemy_album  => [qw(album_id)],
);
# XMLBrowser re-runs the coderefs of every level above the one being shown,
# and a browser refresh / back re-runs the current one. That's harmless for
# menu builders, but would re-queue tracks for actions — so an identical
# action for the same player within this window returns the earlier result.
use constant REPEAT_GUARD_SECS => 15;

# Commands that only build menus (safe to run again).
my %MENU_CMD = map { $_ => 1 } qw(
	menu menu_mood menu_alchemy menu_findpath menu_dynamic menu_status
	menu_instant menu_similar_song menu_similar_artist menu_top_queries
	menu_radios menu_explore menu_sonic_moods menu_sonic_mood
	menu_lyric_themes menu_concepts filter_artists browse_artists
	similar_song_search findpath_search alchemy_pick
	status_active status_last open_map
);

my %_recent;   # "clientid|cmd..." => [epoch, feed]

sub init {
	Slim::Web::Pages->addPageLinks('browse', { PLUGIN_AUDIOMUSEAI => URL });
	Slim::Web::Pages->addPageLinks('icons',
		{ PLUGIN_AUDIOMUSEAI => 'plugins/AudioMuseAI/html/images/icon_svg.png' });
	Slim::Web::Pages->addPageFunction(URL, sub {
		my $client = $_[0];
		Slim::Web::XMLBrowser->handleWebIndex({
			client  => $client,
			feed    => \&_topFeed,
			type    => 'link',
			title   => string('PLUGIN_AUDIOMUSEAI'),
			# Album creation / chat playlists can take a while.
			timeout => 180,
			args    => \@_,
		});
	});
	Slim::Web::Pages->addPageFunction(RUN_URL, sub {
		my ($client, $params) = @_;
		my $cmd = ref($params) eq 'HASH' ? ($params->{cmd} // '') : '';
		my $feed;
		if (my $allowed = $RUN_CMDS{$cmd}) {
			my %p = map { $_ => $params->{$_} }
				grep { defined $params->{$_} && length $params->{$_} } @$allowed;
			$feed = sub { my ($c, $cb) = @_; _run($c, ['audiomuseai', $cmd], \%p, $cb) };
		}
		else {
			$feed = sub { $_[1]->(_textFeed(string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'))) };
		}
		Slim::Web::XMLBrowser->handleWebIndex({
			client  => $client,
			feed    => $feed,
			type    => 'link',
			title   => string('PLUGIN_AUDIOMUSEAI'),
			timeout => 180,
			args    => \@_,
		});
	});
	$log->info('default web UI pages registered at ' . URL . ' and ' . RUN_URL);
}

# web.url for an info-menu item (the skin appends &player=...).
sub runUrl {
	my ($cmd, $params) = @_;
	$params ||= {};
	return RUN_URL . '?' . join('&', 'cmd=' . uri_escape_utf8($cmd),
		map { $_ . '=' . uri_escape_utf8($params->{$_}) } sort keys %$params);
}

sub _topFeed {
	my ($client, $cb) = @_;
	_run($client, ['audiomuseai', 'menu'], {}, $cb);
}

# Coderef behind every converted link / search item.
sub _runItem {
	my ($client, $cb, $args, $cmd, $params, $inputKey) = @_;
	my %p = %{ $params || {} };
	if (defined $inputKey) {
		my $q = ref($args) eq 'HASH' ? $args->{search} : undef;
		$q = '' unless defined $q;
		$p{$inputKey} = $q;
	}
	_run($client, $cmd, \%p, $cb);
}

# Run one `audiomuseai ...` command for $client and hand its menu to $cb as
# an OPML feed.
sub _run {
	my ($client, $cmd, $params, $cb) = @_;
	my @c = (@$cmd, map { "$_:$params->{$_}" } sort keys %$params);
	my $isAction = !$MENU_CMD{ $cmd->[1] // '' };

	my $key = join('|', ($client ? $client->id : '-'), @c);
	if ($isAction) {
		my $hit = $_recent{$key};
		if ($hit && time() - $hit->[0] < REPEAT_GUARD_SECS) {
			$log->info('web: suppressing repeat of ' . join(' ', @c));
			return $cb->($hit->[1]);
		}
		# Expire old entries so the hash can't grow without bound.
		for (keys %_recent) {
			delete $_recent{$_} if time() - $_recent{$_}[0] >= REPEAT_GUARD_SECS;
		}
	}

	my $done = sub {
		my $request = shift;
		my $feed = _toOpml($client, $request);
		$_recent{$key} = [time(), $feed] if $isAction;
		$cb->($feed);
	};

	my $request = Slim::Control::Request::executeRequest($client, \@c);
	unless ($request) {
		return $cb->(_textFeed(string('PLUGIN_AUDIOMUSEAI_GENERIC_ERROR')));
	}
	# Player-scoped commands without a player selected in the web UI.
	if (!$client && ($request->isStatusNeedsClient || $request->isStatusBadDispatch)) {
		return $cb->(_textFeed(string('PLUGIN_AUDIOMUSEAI_WEB_NO_PLAYER')));
	}
	if ($request->isStatusProcessing) {
		$request->callbackFunction(sub { $done->($request) });
		return;
	}
	$done->($request);
}

# Jive item_loop -> OPML items.
sub _toOpml {
	my ($client, $request) = @_;
	my $loop = $request->getResult('item_loop') || [];
	my @items;
	for my $it (@$loop) {
		next unless ref($it) eq 'HASH';
		my $name = $it->{text} // '';
		my $go   = ref($it->{actions}) eq 'HASH' ? $it->{actions}{go} : undef;
		if (ref($go) eq 'HASH' && ref($go->{cmd}) eq 'ARRAY') {
			my %p = %{ ref($go->{params}) eq 'HASH' ? $go->{params} : {} };
			my ($inputKey) = grep { ($p{$_} // '') eq '__TAGGEDINPUT__' } keys %p;
			if ($it->{input} && defined $inputKey) {
				delete $p{$inputKey};
				push @items, {
					name        => $name,
					type        => 'search',
					url         => \&_runItem,
					passthrough => [ $go->{cmd}, \%p, $inputKey ],
				};
			}
			else {
				push @items, {
					name        => $name,
					type        => 'link',
					url         => \&_runItem,
					passthrough => [ $go->{cmd}, \%p ],
				};
			}
		}
		else {
			push @items, { name => $name, type => 'text' };
		}
	}
	return @items ? { items => \@items } : _textFeed(string('PLUGIN_AUDIOMUSEAI_NO_RESULTS'));
}

# Tests only: forget recent actions.
sub _resetGuard { %_recent = () }

sub _textFeed {
	return { items => [ { name => shift, type => 'text' } ] };
}

1;
