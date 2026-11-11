#!/usr/bin/env perl
# Features that need a newer AudioMuse-AI (issue #11): an AudioMuse without
# Album Creation / the Hyperbolic Explorer answers 404 (no such endpoint).
# The plugin must then say which AudioMuse version the feature needs, not
# "this song isn't analysed".
#
# Run via tests/run-all.sh or:
#   PERL5LIB=tests/stubs perl tests/10-version.pl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/stubs";

package main;
use constant WEBUI => 0;

require Plugins::AudioMuseAI::Plugin;
no warnings qw(once redefine);

my ($pass, $fail) = (0, 0);
sub check {
    my ($desc, $got, $want) = @_;
    $got //= '(nothing)';
    if ($got eq $want) { print "PASS  $desc\n"; $pass++; }
    else { print "FAIL  $desc\n      got '$got', want '$want'\n"; $fail++; }
}

my $P = 'Plugins::AudioMuseAI::Plugin';

# --- _verNum ---------------------------------------------------------------
my $ver = \&{"${P}::_verNum"};
check('verNum v3.6.2',        $ver->('v3.6.2'), 3006002);
check('verNum without v',     $ver->('3.10.0'), 3010000);
check('verNum two parts',     $ver->('v4.1'),   4001000);
check('verNum orders 3.10 > 3.9', ($ver->('v3.10.0') > $ver->('v3.9.9') ? 1 : 0), 1);
check('verNum no number',     $ver->('dev') // 'undef', 'undef');

# --- fakes -------------------------------------------------------------------
package FakeClient;
sub new { bless { id => 'aa:bb:cc:dd:ee:ff' }, shift }
sub id  { $_[0]{id} }

package FakeRequest;
sub new { my ($c, %p) = @_; bless { p => \%p, client => FakeClient->new }, $c }
sub client              { $_[0]{client} }
sub getParam            { $_[0]{p}{$_[1]} }
sub setStatusProcessing { }
sub setStatusBadParams  { }
package main;

# Real message templates for the new strings (the stub returns keys).
my %TEXT = (
    PLUGIN_AUDIOMUSEAI_NEEDS_VERSION       => '%s needs %s; yours is %s',
    PLUGIN_AUDIOMUSEAI_NEEDS_VERSION_OLDER => '%s needs %s; yours is older',
    PLUGIN_AUDIOMUSEAI_FEATURE_ALBUM       => 'Album Creation',
    PLUGIN_AUDIOMUSEAI_FEATURE_HYPERBOLIC  => 'Hyperbolic Explorer',
    PLUGIN_AUDIOMUSEAI_FEATURE_JOURNEY     => 'Hyperbolic Path',
);
*Plugins::AudioMuseAI::Plugin::string = sub { $TEXT{ $_[0] } // $_[0] };

my $shown;
*Plugins::AudioMuseAI::Plugin::_emit = sub { $shown = $_[1][0]{text} };

# Every feature endpoint answers 404; /api/version answers $version.
my $version;      # hashref = 200 body; 'missing' = 404; 'down' = timeout
our $featureErr = '404 NOT FOUND';
*Plugins::AudioMuseAI::API::album_creation     = sub { $_[3]->($featureErr) };
*Plugins::AudioMuseAI::API::hyperbolic_similar = sub { $_[4]->($featureErr) };
*Plugins::AudioMuseAI::API::hyperbolic_journey = sub { $_[4]->($featureErr) };
*Plugins::AudioMuseAI::API::version = sub {
    my ($ok, $err) = @_;
    return $err->('404 NOT FOUND') if $version eq 'missing';
    return $err->('Timed out waiting for data') if $version eq 'down';
    $ok->($version);
};

sub album {
    ($version, $shown) = (shift, undef);
    Plugins::AudioMuseAI::Plugin::_albumCreate(FakeRequest->new, FakeClient->new, 'song', '123');
    return $shown;
}
sub explore {
    ($version, $shown) = (shift, undef);
    Plugins::AudioMuseAI::Plugin::_exploreRun(FakeRequest->new, FakeClient->new, '123', 'similar');
    return $shown;
}
sub journey {
    ($version, $shown) = (shift, undef);
    Plugins::AudioMuseAI::Plugin::_findPathExecute(
        FakeRequest->new(start_id => '1', end_id => '2', method => 'hyperbolic'));
    return $shown;
}

# --- Album Creation (v3.6.2) -------------------------------------------------
check('album: AudioMuse older than v3.6.2 (no /api/version)',
    album('missing'), 'Album Creation needs v3.6.2; yours is older');
check('album: AudioMuse reports an older version',
    album({ app_version => 'v3.6.1' }), 'Album Creation needs v3.6.2; yours is v3.6.1');
check('album: new enough -> song not analysed',
    album({ app_version => 'v3.7.1' }), 'PLUGIN_AUDIOMUSEAI_ALBUM_NO_SEED');
check('album: version unknown (timeout) -> song not analysed',
    album('down'), 'PLUGIN_AUDIOMUSEAI_ALBUM_NO_SEED');
check('album: unparsable version -> song not analysed',
    album({ app_version => 'dev' }), 'PLUGIN_AUDIOMUSEAI_ALBUM_NO_SEED');
{
    local $featureErr = '400 BAD REQUEST';
    check('album: 400 still means the feature is disabled',
        album({ app_version => 'v3.7.1' }), 'PLUGIN_AUDIOMUSEAI_ALBUM_UNAVAILABLE');
}

# --- Hyperbolic Explorer (v3.3.0) ----------------------------------------------
check('explore: AudioMuse older than v3.6.2 (no /api/version)',
    explore('missing'), 'Hyperbolic Explorer needs v3.3.0; yours is older');
check('explore: AudioMuse reports an older version',
    explore({ app_version => 'v3.2.0' }), 'Hyperbolic Explorer needs v3.3.0; yours is v3.2.0');
check('explore: new enough -> usual not-indexed message',
    explore({ app_version => 'v3.7.1' }), 'PLUGIN_AUDIOMUSEAI_TRACK_NOT_INDEXED');
{
    local $featureErr = '400 BAD REQUEST';
    check('explore: 400 still means the index is not ready',
        explore({ app_version => 'v3.7.1' }), 'PLUGIN_AUDIOMUSEAI_EXPLORE_UNAVAILABLE');
}

# --- Hyperbolic Path (v3.5.0) ----------------------------------------------------
check('journey: AudioMuse reports an older version',
    journey({ app_version => 'v3.4.0' }), 'Hyperbolic Path needs v3.5.0; yours is v3.4.0');
check('journey: AudioMuse older than v3.6.2 (no /api/version)',
    journey('missing'), 'Hyperbolic Path needs v3.5.0; yours is older');
check('journey: new enough -> usual not-indexed message',
    journey({ app_version => 'v3.6.4' }), 'PLUGIN_AUDIOMUSEAI_TRACK_NOT_INDEXED');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
