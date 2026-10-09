#!/usr/bin/env perl
# Anti-repeat tests: the song-identity key, the fresh-row filter, path
# de-duplication, steering parsing, and a simulated long auto-extend run.
#
# The simulation stubs the player queue and the AudioMuse API with a
# deliberately "loopy" similarity graph (neighbours wrap inside a small
# cluster, like the real index does) plus alternate copies of the same song
# under other ids ("Song (Live)", "Song - 2011 Remaster"). A correct
# extender must never queue the same track id OR the same song twice.
#
# Run via tests/run-all.sh or:
#   PERL5LIB=tests/stubs perl tests/05-antirepeat.pl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/stubs";

package main;
use constant WEBUI => 0;

require Plugins::AudioMuseAI::Plugin;
use JSON::PP qw(encode_json);

my ($pass, $fail) = (0, 0);
sub check {
    my ($desc, $ok, $detail) = @_;
    if ($ok) { print "PASS  $desc\n"; $pass++; }
    else     { print "FAIL  $desc\n      " . ($detail // '') . "\n"; $fail++; }
}

my $P = 'Plugins::AudioMuseAI::Plugin';
my $key = \&{"${P}::_trackKey"};

# --- _trackKey -------------------------------------------------------------
check('key: bracketed qualifiers ignored',
    $key->('Recovery (Live From Show 3000)', 'Frank Turner') eq $key->('Recovery', 'Frank Turner'));
check('key: dash remaster suffix ignored',
    $key->('Song - 2011 Remaster', 'X') eq $key->('Song', 'X'));
check('key: case / punctuation ignored',
    $key->("I Ain't Worried", 'OneRepublic') eq $key->('i aint worried', 'onerepublic'));
check('key: different artists differ',
    $key->('Intro', 'A') ne $key->('Intro', 'B'));
check('key: dash in a real title kept',
    $key->('Love - Hate', 'X') ne $key->('Love', 'X'));
check('key: empty title -> undef', !defined $key->('', 'X'));
check('key: featured / secondary artists ignored',
    $key->("I Ain't Worried (Latin Version)", 'OneRepublic, Becky G') eq $key->("I Ain\x{2019}t Worried", 'OneRepublic'));
check('key: feat. in artist ignored', $key->('Song', 'A feat. B') eq $key->('Song', 'A'));

# --- _freshRows ------------------------------------------------------------
{
    my $rows = [
        { item_id => '1', title => 'A',          author => 'X' },
        { item_id => '2', title => 'A (Live)',   author => 'X' },   # same song
        { item_id => '1', title => 'A',          author => 'X' },   # same id
        { item_id => 'fp_abc', title => 'Z',     author => 'X' },   # non-Lyrion id
        { item_id => '3', title => 'B',          author => 'X' },
        { item_id => '4', title => 'C',          author => 'Y' },
    ];
    my $excl = { ids => { 4 => 1 }, keys => {} };
    my $out = Plugins::AudioMuseAI::Plugin::_freshRows($rows, $excl);
    check('freshRows: keeps only new, distinct songs',
        join(',', map { $_->{item_id} } @$out) eq '1,3',
        encode_json([ map { $_->{item_id} } @$out ]));
    my $again = Plugins::AudioMuseAI::Plugin::_freshRows($rows, $excl);
    check('freshRows: accumulates exclusions across calls', !@$again,
        encode_json([ map { $_->{item_id} } @$again ]));
    my $cap = Plugins::AudioMuseAI::Plugin::_freshRows($rows, { ids => {}, keys => {} }, 1);
    check('freshRows: honours $want', @$cap == 1);
}

# --- _dedupePath -----------------------------------------------------------
{
    my $path = [
        { item_id => '10', title => 'Start', author => 'S' },
        { item_id => '11', title => 'Mid',   author => 'M' },
        { item_id => '12', title => 'Mid (Live)', author => 'M' },
        { item_id => '13', title => 'End (Remastered)', author => 'E' },
        { item_id => '14', title => 'End',   author => 'E' },
    ];
    my $out = Plugins::AudioMuseAI::Plugin::_dedupePath($path);
    check('dedupePath: drops repeats, keeps start and destination',
        join(',', map { $_->{item_id} } @$out) eq '10,11,14',
        encode_json([ map { $_->{item_id} } @$out ]));
}

# --- _parseSteering --------------------------------------------------------
{
    my ($q, $s) = Plugins::AudioMuseAI::Plugin::_parseSteering('jazz with viola | +Viola x3, -drums, female vocals*5');
    check('steering: query split from concepts', $q eq 'jazz with viola', $q);
    check('steering: parsed terms/directions/weights',
        JSON::PP->new->canonical->encode($s) eq JSON::PP->new->canonical->encode([
            { term => 'viola', direction => 'more', weight => 3 },
            { term => 'drums', direction => 'less' },
            { term => 'female vocals', direction => 'more', weight => 5 },
        ]), encode_json($s));
    ($q, $s) = Plugins::AudioMuseAI::Plugin::_parseSteering('plain prompt');
    check('steering: no | means no steering', $q eq 'plain prompt' && !@$s);
}

# --- simulated auto-extend ---------------------------------------------------
# Library: songs 1..400. Song n has alternate copies 1000+n ("(Live)") and
# 2000+n (" - 2011 Remaster"). Similarity is a loopy graph: neighbours of n
# are the other members of its 40-song cluster, nearest first, plus the
# alternate copies — so naive "similar to the last track" chaining loops.
package FakeTrack;
sub new   { my ($c, $id) = @_; bless { id => $id }, $c }
sub id    { $_[0]{id} }
sub base  { my $i = $_[0]{id}; $i > 2000 ? $i - 2000 : $i > 1000 ? $i - 1000 : $i }
sub title { my $s = $_[0]; my $b = $s->base; $s->{id} > 2000 ? "Song $b - 2011 Remaster"
                                           : $s->{id} > 1000 ? "Song $b (Live)" : "Song $b" }
sub artistName { 'Artist ' . int(($_[0]->base - 1) / 10) }
sub url   { 'file:///music/' . $_[0]{id} . '.flac' }
package main;

sub row { my $t = FakeTrack->new(shift); +{ item_id => '' . $t->id, title => $t->title, author => $t->artistName } }

sub neighbours {
    my ($seed, $n) = @_;
    my $b = FakeTrack->new($seed)->base;
    my $c0 = int(($b - 1) / 40) * 40;
    my @out;
    for my $d (1 .. 39) {
        my $m = $c0 + (($b - 1 - $c0 + $d) % 40) + 1;
        push @out, row($m), row(1000 + $m), row(2000 + $m);
    }
    return [ @out[0 .. ($n > @out ? $#out : $n - 1)] ];
}

my @queue;      # FakeTrack objects
my $playing = 0;
my %calls;
{
    no warnings qw(redefine once);
    *Slim::Player::Playlist::count = sub { scalar @queue };
    *Slim::Player::Playlist::track = sub { $queue[$_[1]] };
    *Slim::Player::Playlist::song  = sub { $queue[$playing] };
    # Every id resolves locally except the 3000-range (stale AudioMuse ids).
    *Slim::Schema::find = sub { my (undef, undef, $id) = @_; $id < 3000 ? FakeTrack->new($id) : undef };
    *Plugins::AudioMuseAI::API::similar_tracks = sub {
        my ($seed, $n, $ok) = @_; $calls{similar}++; $ok->(neighbours($seed, $n));
    };
    # Blend: union of the seeds' neighbourhoods, then the NEXT cluster over
    # (alchemy drifts) — lets the extender escape an exhausted cluster.
    *Plugins::AudioMuseAI::API::alchemy = sub {
        my ($seeds, undef, $n, $ok) = @_; $calls{alchemy}++;
        my $b = FakeTrack->new($seeds->[-1])->base;
        my $next = (($b + 40 - 1) % 400) + 1;
        $ok->({ results => [ @{ neighbours($seeds->[-1], $n) }, @{ neighbours($next, $n) } ] });
    };
    # Deterministic, like the real endpoint: always the same top list.
    *Plugins::AudioMuseAI::API::sonic_fingerprint = sub {
        my ($n, $ok) = @_; $calls{fingerprint}++;
        $ok->([ map { row($_) } 1 .. ($n > 400 ? 400 : $n) ]);
    };
    *Plugins::AudioMuseAI::API::sem_grove = sub {
        my ($seed, $n, $ok) = @_; $calls{semgrove}++;
        $ok->({ results => [ { %{ row($seed) }, is_seed => JSON::PP::true }, @{ neighbours($seed, $n) } ] });
    };
}

my $client = bless { id => 'aa:bb:cc' }, 'FakeClient';
sub FakeClient::id { $_[0]{id} }

for my $mode (qw(similar fingerprint semgrove)) {
    %Plugins::AudioMuseAI::Plugin::_history = ();   # fresh player history
    @queue = (FakeTrack->new(5)); $playing = 0; %calls = ();
    for my $round (1 .. 20) {
        Plugins::AudioMuseAI::Plugin::_rememberTrackObj($client, $queue[$playing]);
        my $got;
        Plugins::AudioMuseAI::Plugin::_extendFetch($client, $mode, 10, sub { $got = shift });
        push @queue, map { FakeTrack->new($_->{item_id}) } @$got;
        $playing = $#queue - 3 if $#queue - 3 > $playing;   # listener catches up
    }
    my (%ids, %songs, $dupId, $dupSong);
    for my $t (@queue) {
        $dupId++   if $ids{ $t->id }++;
        $dupSong++ if $songs{ $t->base }++;
    }
    check("extend[$mode]: 20 rounds queue no repeated track id",
        !$dupId, ($dupId // 0) . ' repeats in ' . scalar(@queue));
    check("extend[$mode]: no repeated song (alt copies filtered)",
        !$dupSong, ($dupSong // 0) . ' repeats in ' . scalar(@queue));
    check("extend[$mode]: keeps finding new songs (>=150 queued)",
        @queue >= 150, scalar(@queue) . ' queued; calls ' . encode_json(\%calls));
}

# --- stale ids (not in the Lyrion library) never get queued ---------------
{
    my $rows = Plugins::AudioMuseAI::Plugin::_localizeRows([ row(5), { item_id => '3005', title => 'Gone', author => 'Nobody' } ]);
    check('localize: drops ids Lyrion does not have', @$rows == 1 && $rows->[0]{item_id} eq '5',
        encode_json($rows));
}

# --- a renumbered Lyrion track still seeds AudioMuse ------------------------
{
    no warnings qw(redefine once);
    # AudioMuse knows song 9 as id 3009 (stale); Lyrion now calls it 9.
    my @seen;
    local *Plugins::AudioMuseAI::API::search_query = sub {
        my (undef, $ok) = @_;
        $ok->([ { item_id => '3009', title => 'Song 9', author => 'Artist 0' } ]);
    };
    my $call = sub { my ($id, $ok, $err) = @_; push @seen, $id;
        $id eq '3009' ? $ok->('found') : $err->('404 NOT FOUND') };
    my $res;
    Plugins::AudioMuseAI::Plugin::_withAmSeed('9', $call, sub { $res = shift }, sub { $res = 'ERR ' . shift });
    check('withAmSeed: 404 -> looks song up by title and retries with AudioMuse id',
        ($res // '') eq 'found' && "@seen" eq '9 3009', "res=$res seen=@seen");
    @seen = ();
    Plugins::AudioMuseAI::Plugin::_withAmSeed('9', $call, sub { $res = shift }, sub { $res = 'ERR ' . shift });
    check('withAmSeed: remembers the mapping (no second 404)', "@seen" eq '3009', "seen=@seen");
    Plugins::AudioMuseAI::Plugin::_withAmSeed('8', sub { $_[2]->('500 boom') }, sub {}, sub { $res = shift });
    check('withAmSeed: non-404 errors pass straight through', $res eq '500 boom', $res);
}

# --- an add LMS hasn't applied yet still counts (fast skipping race) ------
{
    %Plugins::AudioMuseAI::Plugin::_history = ();
    %Plugins::AudioMuseAI::Plugin::_recentAdds = ();
    @queue = (FakeTrack->new(5));
    my ($a, $b);
    Plugins::AudioMuseAI::Plugin::_extendFetch($client, 'fingerprint', 10, sub { $a = shift });
    Plugins::AudioMuseAI::Plugin::_noteAdded($client, $a);   # added, but queue not updated yet
    Plugins::AudioMuseAI::Plugin::_extendFetch($client, 'fingerprint', 10, sub { $b = shift });
    my %first = map { $_->{item_id} => 1 } @$a;
    check('recent adds: second extend before the queue updates gets different tracks',
        @$b == 10 && !grep({ $first{ $_->{item_id} } } @$b),
        encode_json([ map { $_->{item_id} } @$b ]));
}

# --- history survives tracks leaving the queue -----------------------------
{
    %Plugins::AudioMuseAI::Plugin::_history = ();
    Plugins::AudioMuseAI::Plugin::_rememberTrackObj($client, FakeTrack->new(7));
    @queue = (FakeTrack->new(6));   # 7 played earlier, since removed
    my $got;
    Plugins::AudioMuseAI::Plugin::_extendFetch($client, 'similar', 50, sub { $got = shift });
    check('history: a played track that left the queue is not re-added',
        !grep({ FakeTrack->new($_->{item_id})->base == 7 } @$got),
        encode_json([ map { $_->{item_id} } @$got ]));
}

print "\n----\n05-antirepeat: $pass passed, $fail failed\n";
exit($fail ? 1 : 0);
