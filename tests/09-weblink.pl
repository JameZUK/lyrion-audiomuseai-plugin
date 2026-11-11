#!/usr/bin/env perl
# "Open Music Map" link: the url pref is how Lyrion reaches AudioMuse, but
# the link is opened by a browser on another device, so a loopback host
# must become the Lyrion server's address.
#
# Run via tests/run-all.sh or:
#   PERL5LIB=tests/stubs perl tests/09-weblink.pl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/stubs";

package main;
use constant WEBUI => 0;

require Plugins::AudioMuseAI::Plugin;
use Slim::Utils::Prefs;
no warnings qw(once redefine);

my ($pass, $fail) = (0, 0);
sub check {
    my ($desc, $got, $want) = @_;
    if ($got eq $want) { print "PASS  $desc\n"; $pass++; }
    else { print "FAIL  $desc\n      got '$got', want '$want'\n"; $fail++; }
}

my $prefs = preferences('plugin.audiomuseai');
sub webUrl {
    my ($url, $addr) = @_;
    $prefs->set('url', $url);
    local $Slim::Utils::Network::serverAddr = $addr // '192.168.1.10';
    return Plugins::AudioMuseAI::Plugin::_webUrl();
}

# Loopback hosts become the Lyrion server's address; port and path are kept.
check('localhost',            webUrl('http://localhost:8000'),        'http://192.168.1.10:8000/');
check('localhost, any case',  webUrl('http://LocalHost:8000'),        'http://192.168.1.10:8000/');
check('127.0.0.1',            webUrl('http://127.0.0.1:8000'),        'http://192.168.1.10:8000/');
check('other 127.x address',  webUrl('http://127.0.1.1:8000'),        'http://192.168.1.10:8000/');
check('[::1]',                webUrl('http://[::1]:8000'),            'http://192.168.1.10:8000/');
check('0.0.0.0',              webUrl('http://0.0.0.0:8000'),          'http://192.168.1.10:8000/');
check('https, no port',       webUrl('https://localhost'),            'https://192.168.1.10/');
check('path kept',            webUrl('http://localhost:8000/am/'),    'http://192.168.1.10:8000/am/');
check('no scheme in pref',    webUrl('localhost:8000'),               'http://192.168.1.10:8000/');
check('IPv6 server address',  webUrl('http://localhost:8000', 'fd00::5'), 'http://[fd00::5]:8000/');

# Anything a browser can already reach is left alone.
check('LAN hostname',         webUrl('http://music.lan:8000'),        'http://music.lan:8000/');
check('LAN address',          webUrl('http://192.168.1.20:8000'),     'http://192.168.1.20:8000/');
check('localhost-like name',  webUrl('http://localhost.example:8000'), 'http://localhost.example:8000/');

# No usable server address: keep the pref as it was.
check('no server address',    webUrl('http://localhost:8000', ''),    'http://localhost:8000/');
check('loopback server addr', webUrl('http://localhost:8000', '127.0.0.1'), 'http://localhost:8000/');
check('empty pref',           webUrl(''),                             '/');

# The link opens the Music Map page, under any path in the pref.
sub mapUrl {
    my ($url) = @_;
    $prefs->set('url', $url);
    local $Slim::Utils::Network::serverAddr = '192.168.1.10';
    return Plugins::AudioMuseAI::Plugin::_mapUrl();
}
check('map page',             mapUrl('http://localhost:8000'),        'http://192.168.1.10:8000/map');
check('map page, path kept',  mapUrl('http://localhost:8000/am/'),    'http://192.168.1.10:8000/am/map');
check('map page, LAN host',   mapUrl('http://music.lan:8000'),        'http://music.lan:8000/map');

# The menu command shows the same URL as text.
{
    my $emitted;
    local *Plugins::AudioMuseAI::Plugin::_emit = sub { $emitted = $_[1] };
    $prefs->set('url', 'http://localhost:8000');
    Plugins::AudioMuseAI::Plugin::_openMap(undef);
    check('open_map text', $emitted->[1]{text} // '', 'http://192.168.1.10:8000/map');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
