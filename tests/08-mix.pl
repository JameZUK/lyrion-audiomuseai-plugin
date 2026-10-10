#!/usr/bin/env perl
# Mix filters (Mix.pm), seed selection, the audiomuse:// URL handler and the
# "Don't Stop The Music only" interface mode.
#
# Run via tests/run-all.sh or:
#   PERL5LIB=tests/stubs perl tests/08-mix.pl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/stubs";

package main;
use constant WEBUI => 0;

require Plugins::AudioMuseAI::Plugin;
use JSON::PP;
no warnings qw(once redefine);

my ($pass, $fail) = (0, 0);
sub check {
    my ($desc, $ok, $detail) = @_;
    if ($ok) { print "PASS  $desc\n"; $pass++; }
    else     { print "FAIL  $desc\n      " . ($detail // '') . "\n"; $fail++; }
}

# --- fake Lyrion objects ---------------------------------------------------
package FGenre;  sub new { bless { n => $_[1] }, $_[0] } sub name { $_[0]{n} }
package FTrack;
my %T;
sub new {
    my ($c, %a) = @_;
    my $t = bless { secs => 200, genres => ['Rock'], %a }, $c;
    $T{ $t->{id} } = $t;
    return $t;
}
sub id       { $_[0]{id} }
sub secs     { $_[0]{secs} }
sub artistid { $_[0]{artist} }
sub albumid  { $_[0]{album} }
sub title    { "T$_[0]{id}" }
sub artistName { "A$_[0]{artist}" }
sub url      { "file:///m/$_[0]{id}.flac" }
sub remote   { 0 }
sub genres   { map { FGenre->new($_) } @{ $_[0]{genres} } }
package FRS;     # minimal result set for Slim::Schema->rs(...)->search(...)
sub new  { my ($c, @r) = @_; bless { r => [@r] }, $c }
sub next { shift @{ $_[0]{r} } }
sub first { $_[0]{r}[0] }
package FObj;    sub new { bless { id => $_[1] }, $_[0] } sub id { $_[0]{id} }
package main;

my %contributors = ('Bad Artist' => 900);
my %albums       = ('Bad Album'  => 800);
*Slim::Schema::find = sub { my (undef, undef, $id) = @_; $T{$id} };
*Slim::Schema::rs = sub {
    my (undef, $what) = @_;
    return bless { what => $what }, 'FRSFactory';
};
*Slim::Schema::variousArtistsObject = sub { FObj->new(1) };
package FRSFactory;
# Like DBIx::Class: search() in LIST context returns the rows, not a result
# set — so code must call search_rs() (or force scalar context).
sub search { my $rs = search_rs(@_); return wantarray ? @{ $rs->{r} } : $rs }
sub search_rs {
    my ($self, $where) = @_;
    my $name = $where->{'me.name'} // $where->{'me.title'} // '';
    return FRS->new(FObj->new($contributors{$name})) if $self->{what} eq 'Contributor' && $contributors{$name};
    return FRS->new(FObj->new($albums{$name}))       if $self->{what} eq 'Album' && $albums{$name};
    return FRS->new();
}
package main;

my $prefs = Slim::Utils::Prefs::preferences('plugin.audiomuseai');
sub resetPrefs {
    $prefs->set($_->[0], $_->[1]) for (
        [mix_no_repeat_artist => 0], [mix_no_repeat_album => 0], [mix_min_duration => 0],
        [mix_max_duration => 0], [mix_filter_xmas => 0], [mix_exclude_artists => ''],
        [mix_exclude_albums => ''], [mix_filter_genres => 0], [mix_genre_groups => ''],
        [mix_use_track_genre => 0], [mix_match_all_genres => 0], [mix_shuffle => 0]);
    Plugins::AudioMuseAI::Mix::resetCaches();
}
sub rows { [ map { { item_id => "$_" } } @_ ] }
sub ids  { join ',', map { $_->{item_id} } @{ $_[0] } }
my $M = 'Plugins::AudioMuseAI::Mix';

# Library: 1..40. Artist = int(id/10)+10, album = id (unique) unless set.
FTrack->new(id => $_, artist => 10 + int($_ / 10), album => 100 + $_) for 1 .. 40;
$T{5}{secs}   = 30;                      # very short
$T{6}{secs}   = 1200;                    # very long
$T{7}{genres} = ['Christmas'];
$T{8}{artist} = 900;                     # excluded artist
$T{9}{album}  = 800;                     # excluded album
$T{$_}{genres} = ['Jazz'] for 21 .. 30;

# --- hard filters ----------------------------------------------------------
resetPrefs();
$prefs->set(mix_min_duration => 60); $prefs->set(mix_max_duration => 600);
my $out = Plugins::AudioMuseAI::Mix::apply(rows(1 .. 10));
check('duration: too-short and too-long tracks dropped', ids($out) !~ /\b(5|6)\b/, ids($out));

resetPrefs();
$prefs->set(mix_filter_xmas => 1);
{
    local *Plugins::AudioMuseAI::Mix::_december = sub { 0 };
    $out = Plugins::AudioMuseAI::Mix::apply(rows(1 .. 10));
    check('xmas: Christmas track dropped outside December', ids($out) !~ /\b7\b/, ids($out));
}
{
    local *Plugins::AudioMuseAI::Mix::_december = sub { 1 };
    $out = Plugins::AudioMuseAI::Mix::apply(rows(1 .. 10));
    check('xmas: allowed in December', ids($out) =~ /\b7\b/, ids($out));
}

resetPrefs();
$prefs->set(mix_exclude_artists => "Bad Artist\n");
$prefs->set(mix_exclude_albums  => "Bad Album");
$out = Plugins::AudioMuseAI::Mix::apply(rows(1 .. 10));
check('excluded artist and album dropped', ids($out) !~ /\b(8|9)\b/, ids($out));
check('exclusions are hard (never relaxed even when short)',
    ids(Plugins::AudioMuseAI::Mix::apply(rows(8, 9), want => 2)) eq '', '');

# --- genre groups ------------------------------------------------------------
resetPrefs();
$prefs->set(mix_filter_genres => 1);
$prefs->set(mix_genre_groups => "Jazz; Blues\nRock; Metal");
$out = Plugins::AudioMuseAI::Mix::apply(rows(1 .. 40), seeds => [ $T{25} ]);
check('genre group: a jazz seed keeps only jazz-group tracks',
    ids($out) eq join(',', 21 .. 30), ids($out));
$prefs->set(mix_genre_groups => "Jazz; Blues");
Plugins::AudioMuseAI::Mix::resetCaches();
$out = Plugins::AudioMuseAI::Mix::apply(rows(1 .. 40), seeds => [ $T{1} ]);
check('genre group: an ungrouped seed excludes grouped tracks',
    ids($out) !~ /\b2[1-9]\b|\b30\b/, ids($out));

# --- spacing + relaxation ----------------------------------------------------
resetPrefs();
$prefs->set(mix_no_repeat_artist => 5);
# 11..19 are all artist 11; 31..39 artist 13.
$out = Plugins::AudioMuseAI::Mix::apply(rows(11 .. 19, 31 .. 39), want => 4);
my %art = map { $T{ $_->{item_id} }{artist} => 1 } @$out;
check('artist spacing: a single artist is not repeated back to back',
    ids($out) eq '11,31,12,32' || keys(%art) == 2, ids($out));
$out = Plugins::AudioMuseAI::Mix::apply(rows(11 .. 19), want => 4);
check('artist spacing relaxes when there are too few other artists',
    scalar(@$out) == 4, ids($out));
$out = Plugins::AudioMuseAI::Mix::apply(rows(11, 31), want => 2, prev => [ $T{12} ]);
check('artist spacing looks back at the queue (prev)', ids($out) eq '31,11', ids($out));

resetPrefs();
$prefs->set(mix_no_repeat_album => 3);
$T{$_}{album} = 555 for 33, 34;
$out = Plugins::AudioMuseAI::Mix::apply(rows(33, 34, 35), want => 2);
check('album spacing: second track of an album deferred', ids($out) eq '33,35', ids($out));
$T{$_}{artist} = 1 for 33, 34;   # Various Artists
$out = Plugins::AudioMuseAI::Mix::apply(rows(33, 34, 35), want => 2);
check('album spacing: Various Artists albums exempt', ids($out) eq '33,34', ids($out));

# --- shuffle -----------------------------------------------------------------
resetPrefs();
$prefs->set(mix_shuffle => 1);
my %seen; my $orders = 0;
for (1 .. 30) {
    my $o = Plugins::AudioMuseAI::Mix::apply(rows(1 .. 40), want => 5);
    $seen{$_->{item_id}}++ for @$o;
    $orders++ if ids($o) ne '1,2,3,4,5';
}
check('shuffle: varies the order', $orders > 0, "never varied");
check('shuffle: stays within the best 2 x want', !grep({ $_ > 10 } keys %seen),
    join(',', sort { $a <=> $b } keys %seen));
check('shuffle can be overridden off', ids(Plugins::AudioMuseAI::Mix::apply(rows(1 .. 40), want => 5, shuffle => 0)) eq '1,2,3,4,5');

# --- seeds from the queue ------------------------------------------------------
my @queue = map { $T{$_} } 1 .. 12;
*Slim::Player::Playlist::count = sub { scalar @queue };
*Slim::Player::Playlist::track = sub { $queue[$_[1]] };
resetPrefs();
my $s = Plugins::AudioMuseAI::Mix::seedTracks(bless({}, 'X'), 3, 1);
check('seeds strict: exactly the last 3, in order', join(',', map { $_->id } @$s) eq '10,11,12');
$s = Plugins::AudioMuseAI::Mix::seedTracks(bless({}, 'X'), 3, 0);
check('seeds sampled: 3 from the last 6', @$s == 3 && !grep({ $_->id < 7 } @$s),
    join(',', map { $_->id } @$s));
$prefs->set(mix_max_duration => 600);
@queue = map { $T{$_} } 1 .. 6;   # last one (6) is 20 minutes long
$s = Plugins::AudioMuseAI::Mix::seedTracks(bless({}, 'X'), 1, 1);
check('seeds: skip tracks outside the duration limits', $s->[0]->id == 5 || $s->[0]->id == 4,
    join(',', map { $_->id } @$s));

# --- audiomuse:// URLs ------------------------------------------------------------
my $PH = 'Plugins::AudioMuseAI::ProtocolHandler';
my $p = $PH->params('audiomuse://?artist=Iron%20Maiden&album=Somewhere+In+Time&count=15&dstm=1');
check('url: parses + unescapes params',
    $p->{artist} eq 'Iron Maiden' && $p->{album} eq 'Somewhere In Time' && $p->{count} == 15 && $p->{dstm} == 1,
    JSON::PP->new->canonical->encode($p));
check('url: other schemes ignored', !defined $PH->params('file:///x.mp3'));
my $m = $PH->mixParams({ track_id => 42, count => 'x', dstm => '1' });
check('url: ids pass through; bad count dropped; dstm kept',
    $m->{track_id} == 42 && !exists $m->{count} && $m->{dstm} == 1, JSON::PP->new->canonical->encode($m));
$m = $PH->mixParams({ artist => 'Bad Artist' });
check('url: artist name resolved to a contributor id', ($m->{artist_id} // '') eq '900',
    JSON::PP->new->canonical->encode($m));
my $md = $PH->getMetadataFor(undef, 'audiomuse://?genre=Heavy%20Metal');
check('url: favourite title from the genre', $md->{title} eq 'Heavy Metal');

# --- Don't Stop The Music only mode -------------------------------------------------
my (@deleted, @registered, @deregistered);
*Slim::Control::Jive::deleteMenuItem    = sub { push @deleted, shift };
*Slim::Control::Jive::registerPluginMenu = sub { push @registered, $_[0][0]{id} };
*Slim::Menu::TrackInfo::deregisterInfoProvider = sub { push @deregistered, $_[1] };
$prefs->set(ui_mode => 'full');
Plugins::AudioMuseAI::Plugin::_applyUiMode();     # ensure registered
@deleted = @registered = @deregistered = ();
$prefs->set(ui_mode => 'dstm');
Plugins::AudioMuseAI::Plugin::_applyUiMode();
check('dstm-only: My Music entry removed', "@deleted" eq 'pluginAudioMuseAI', "@deleted");
check('dstm-only: track context items removed', scalar(@deregistered) >= 4, "@deregistered");
$prefs->set(ui_mode => 'full');
Plugins::AudioMuseAI::Plugin::_applyUiMode();
check('full again: My Music entry re-registered', "@registered" eq 'pluginAudioMuseAI', "@registered");

print "\n----\n08-mix: $pass passed, $fail failed\n";
exit($fail ? 1 : 0);
