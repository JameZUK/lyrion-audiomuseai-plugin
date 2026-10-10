#!/usr/bin/env perl
# Default web UI adapter (Web.pm, issue #6): page registration under
# My Music, Jive item_loop -> OPML conversion (links / search boxes / text),
# the typed search text reaching the command, the no-player message, and
# the repeat guard that stops a page refresh re-running an action.
#
# Run via tests/run-all.sh or:
#   PERL5LIB=tests/stubs perl tests/07-web.pl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/stubs";

package main;
use constant WEBUI => 0;

require Plugins::AudioMuseAI::Web;
use JSON::PP;
no warnings qw(once);

my ($pass, $fail) = (0, 0);
sub check {
    my ($desc, $ok, $detail) = @_;
    if ($ok) { print "PASS  $desc\n"; $pass++; }
    else     { print "FAIL  $desc\n      " . ($detail // '') . "\n"; $fail++; }
}
my $J = JSON::PP->new->canonical;

# --- fake request layer: records commands, answers with canned item_loops ---
package FakeReq;
sub new { my ($c, %a) = @_; bless { %a }, $c }
sub getResult { $_[0]{ $_[1] } }
sub isStatusProcessing   { $_[0]{processing} }
sub isStatusNeedsClient  { $_[0]{needsClient} }
sub isStatusBadDispatch  { 0 }
sub callbackFunction     { $_[0]{cb} = $_[1] }
package FakeClient;
sub id { 'aa:bb' }
package main;

my @ran;
my %answers = (
    menu => [
        { text => '* main_analysis - 43%' },
        { text => 'Similar to current track',
          actions => { go => { cmd => ['audiomuseai', 'similar_now'], player => 0 } },
          nextWindow => 'refresh' },
        { text => 'Instant Playlist...',
          input => { len => 1 },
          actions => { go => { cmd => ['audiomuseai', 'instant'], player => 0,
                               params => { prompt => '__TAGGEDINPUT__', extra => 'x' } } } },
    ],
);
{
    no warnings qw(redefine once);
    *Slim::Control::Request::executeRequest = sub {
        my ($client, $cmd) = @_;
        push @ran, join(' ', @$cmd);
        return FakeReq->new(needsClient => 1) if !$client && $cmd->[1] ne 'menu';
        my $loop = $answers{ $cmd->[1] } || [ { text => "ran $cmd->[1]" } ];
        return FakeReq->new(item_loop => $loop);
    };
}

my $client = bless {}, 'FakeClient';

# --- registration ---
Plugins::AudioMuseAI::Web::init();
check('registers a My Music (browse) link',
    ($Slim::Web::Pages::links{browse}{PLUGIN_AUDIOMUSEAI} // '') eq 'plugins/AudioMuseAI/index.html');
check('registers the page handler',
    ref $Slim::Web::Pages::functions{'plugins/AudioMuseAI/index.html'} eq 'CODE');

check('registers the context-menu run page',
    ref $Slim::Web::Pages::functions{'plugins/AudioMuseAI/run.html'} eq 'CODE');
check('runUrl escapes params',
    Plugins::AudioMuseAI::Web::runUrl('similar_artist', { artist => 'Simon & Garfunkel', artist_id => 7 })
        eq 'plugins/AudioMuseAI/run.html?cmd=similar_artist&artist=Simon%20%26%20Garfunkel&artist_id=7');
{
    @ran = ();
    Plugins::AudioMuseAI::Web::_resetGuard();
    $Slim::Web::Pages::functions{'plugins/AudioMuseAI/run.html'}->($client,
        { cmd => 'similar_track', track_id => 42, evil => 'x' });
    my $call = $Slim::Web::XMLBrowser::calls[-1];
    my $got; $call->{feed}->($client, sub { $got = shift });
    check('run page runs the whitelisted command with only its params',
        ($ran[-1] // '') eq 'audiomuseai similar_track track_id:42', $ran[-1]);
    @ran = ();
    $Slim::Web::Pages::functions{'plugins/AudioMuseAI/run.html'}->($client, { cmd => 'run_analysis' });
    $Slim::Web::XMLBrowser::calls[-1]{feed}->($client, sub { $got = shift });
    check('run page refuses other commands', !@ran, join(' / ', @ran));
}

# --- top menu conversion ---
my $feed;
Plugins::AudioMuseAI::Web::_topFeed($client, sub { $feed = shift });
my @items = @{ $feed->{items} || [] };
check('header item becomes text', $items[0]{type} eq 'text' && $items[0]{name} =~ /main_analysis/);
check('action item becomes a link', $items[1]{type} eq 'link' && ref $items[1]{url} eq 'CODE');
check('input item becomes a search box', $items[2]{type} eq 'search');

# --- search text reaches the command; static params kept ---
@ran = ();
my $res;
$items[2]{url}->($client, sub { $res = shift }, { search => 'late night jazz' }, @{ $items[2]{passthrough} });
check('search: typed text replaces __TAGGEDINPUT__',
    ($ran[0] // '') eq 'audiomuseai instant extra:x prompt:late night jazz', $ran[0]);
check('search: result rendered as text', $res->{items}[0]{name} eq 'ran instant', $J->encode($res));

# --- repeat guard: same action again (refresh / ancestor re-run) is not re-run ---
@ran = ();
$items[1]{url}->($client, sub { $res = shift }, {}, @{ $items[1]{passthrough} });
$items[1]{url}->($client, sub { $res = shift }, {}, @{ $items[1]{passthrough} });
check('repeat guard: action runs once within the window', @ran == 1, join(' / ', @ran));
check('repeat guard: second call still returns the result', $res->{items}[0]{name} eq 'ran similar_now');

# --- menus are NOT guarded (always fresh) ---
@ran = ();
Plugins::AudioMuseAI::Web::_topFeed($client, sub {});
Plugins::AudioMuseAI::Web::_topFeed($client, sub {});
check('menu builders always re-run', @ran == 2, join(' / ', @ran));

# --- no player selected ---
Plugins::AudioMuseAI::Web::_runItem(undef, sub { $res = shift }, {}, ['audiomuseai', 'sonic_fp'], {});
check('no player: explains instead of failing', $res->{items}[0]{name} eq 'PLUGIN_AUDIOMUSEAI_WEB_NO_PLAYER'
    || $res->{items}[0]{name} =~ /player/i, $J->encode($res));

# --- async (processing) commands deliver via callback ---
{
    no warnings 'redefine';
    my $pending;
    local *Slim::Control::Request::executeRequest = sub {
        $pending = FakeReq->new(processing => 1, item_loop => [ { text => 'Queued 25 tracks' } ]);
    };
    $res = undef;
    Plugins::AudioMuseAI::Web::_runItem($client, sub { $res = shift }, {}, ['audiomuseai', 'album_now'], {});
    check('async: nothing returned before completion', !defined $res);
    $pending->{cb}->($pending);
    check('async: result delivered on completion', $res && $res->{items}[0]{name} eq 'Queued 25 tracks');
}

print "\n----\n07-web: $pass passed, $fail failed\n";
exit($fail ? 1 : 0);
