#!/usr/bin/env perl
# Request-payload tests: for every public method in API.pm, fire it
# against the test mock HTTP layer and assert on the URL + JSON body.
#
# Adding a new API method? Add a check() block below. The mock captures
# every request in @Slim::Networking::SimpleAsyncHTTP::captured_posts /
# ::captured_gets; reset between tests via reset_captures().
#
# Run via tests/run-all.sh, or directly:
#   PERL5LIB=tests/stubs perl tests/02-payloads.pl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/stubs";

package main;
use constant WEBUI => 0;

require Plugins::AudioMuseAI::API;
use Slim::Networking::SimpleAsyncHTTP;
use JSON::PP qw(decode_json encode_json);

my ($pass, $fail) = (0, 0);
sub check {
    my ($desc, $ok, $detail) = @_;
    if ($ok) { print "PASS  $desc\n"; $pass++; }
    else     { print "FAIL  $desc\n      $detail\n"; $fail++; }
}
sub last_post { $Slim::Networking::SimpleAsyncHTTP::captured_posts[-1] }
sub last_get  { $Slim::Networking::SimpleAsyncHTTP::captured_gets[-1]  }

# NOTE: wrap a bare `$x =~ m{...}` argument in scalar(...). In check()'s
# argument list a FAILED match returns an empty list, so $detail slides into
# $ok and the check silently PASSES (spotted by Tstassin, PR #8).

# Convenience: fire an API call, return decoded payload from last POST.
sub fire_post {
    my ($code) = @_;
    Slim::Networking::SimpleAsyncHTTP::reset_captures();
    $code->();
    my $r = last_post() or return (undef, undef);
    return ($r->{url}, decode_json($r->{body}));
}

# Convenience: same for last GET (just URL — GETs have no body).
sub fire_get {
    my ($code) = @_;
    Slim::Networking::SimpleAsyncHTTP::reset_captures();
    $code->();
    my $r = last_get() or return undef;
    return $r->{url};
}

# ---------------------------------------------------------------------------
# clap_search — must POST {query, limit} to /api/clap/search
# ---------------------------------------------------------------------------
{
    my ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::clap_search('upbeat summer', 25, sub {}, sub {});
    });
    check('clap_search: URL',
        scalar($url =~ m{/api/clap/search$}), $url // '(no request captured)');
    check('clap_search: payload uses `limit` (not legacy `n`)',
        defined $body->{limit} && !defined $body->{n},
        encode_json($body));
    check('clap_search: query forwarded verbatim',
        ($body->{query} // '') eq 'upbeat summer', encode_json($body));
    check('clap_search: count value passes through to `limit`',
        ($body->{limit} // 0) == 25, encode_json($body));
}

# ---------------------------------------------------------------------------
# alchemy — must POST {items: [{id, op, type}], n} to /api/alchemy
# ---------------------------------------------------------------------------
{
    my ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::alchemy(
            ['100', '200'], ['300'], 25, sub {}, sub {},
        );
    });
    check('alchemy: URL',
        scalar($url =~ m{/api/alchemy$}), $url // '(no request)');
    check('alchemy: payload uses items[] (not legacy add[]/sub[])',
        ref($body->{items}) eq 'ARRAY' && !defined($body->{add}) && !defined($body->{sub}),
        encode_json($body));
    check('alchemy: 2 ADD + 1 SUBTRACT items',
        scalar(@{$body->{items}}) == 3
          && (grep { $_->{op} eq 'ADD' }      @{$body->{items}}) == 2
          && (grep { $_->{op} eq 'SUBTRACT' } @{$body->{items}}) == 1,
        encode_json($body->{items}));
    check('alchemy: every item has type=song',
        (grep { ($_->{type} // '') eq 'song' } @{$body->{items}}) == 3,
        encode_json($body->{items}));
    check('alchemy: ids preserved in order',
        $body->{items}[0]{id} eq '100'
          && $body->{items}[1]{id} eq '200'
          && $body->{items}[2]{id} eq '300',
        encode_json($body->{items}));
    check('alchemy: n field present',
        ($body->{n} // 0) == 25, encode_json($body));

    # Empty subtract list still produces a valid items[] (regression check
    # for the path where only ADD entries exist).
    my ($url2, $body2) = fire_post(sub {
        Plugins::AudioMuseAI::API::alchemy(['42'], [], 5, sub {}, sub {});
    });
    check('alchemy: empty subtract list works',
        ref($body2->{items}) eq 'ARRAY'
          && scalar(@{$body2->{items}}) == 1
          && $body2->{items}[0]{op} eq 'ADD',
        encode_json($body2));
}

# ---------------------------------------------------------------------------
# clap_warmup — POST {} to /api/clap/warmup
# ---------------------------------------------------------------------------
{
    my ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::clap_warmup(sub {}, sub {});
    });
    check('clap_warmup: URL',
        scalar($url =~ m{/api/clap/warmup$}), $url // '(no request)');
    check('clap_warmup: empty body',
        encode_json($body) eq '{}', encode_json($body));
}

# ---------------------------------------------------------------------------
# lyrics_search — POST {query, limit} to /api/lyrics/search/text
# ---------------------------------------------------------------------------
{
    my ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::lyrics_search('rainy heartbreak', 50, sub {}, sub {});
    });
    check('lyrics_search: URL',
        scalar($url =~ m{/api/lyrics/search/text$}), $url // '(no request)');
    check('lyrics_search: payload uses {query, limit}',
        ($body->{query} // '') eq 'rainy heartbreak'
          && ($body->{limit} // 0) == 50,
        encode_json($body));
}

# ---------------------------------------------------------------------------
# chat_playlist — POST {userInput} to /chat/api/chatPlaylist
# ---------------------------------------------------------------------------
{
    my ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::chat_playlist('rainy afternoon', sub {}, sub {});
    });
    check('chat_playlist: URL (chat blueprint mount, NOT /api/...)',
        scalar($url =~ m{/chat/api/chatPlaylist$}), $url // '(no request)');
    check('chat_playlist: payload uses `userInput` (server-required key)',
        ($body->{userInput} // '') eq 'rainy afternoon',
        encode_json($body));
}

# ---------------------------------------------------------------------------
# GET endpoints — URL construction (no body to assert)
# ---------------------------------------------------------------------------
{
    my $url = fire_get(sub {
        Plugins::AudioMuseAI::API::similar_tracks('item123', 10, sub {}, sub {});
    });
    check('similar_tracks: URL has item_id, n, eliminate_duplicates',
        scalar($url =~ m{/api/similar_tracks\?item_id=item123&n=10&eliminate_duplicates=true$}),
        $url // '(no request)');

    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::search_tracks('U2', sub {}, sub {});
    });
    check('search_tracks: URL uses legacy `artist=` (server has back-compat)',
        scalar($url =~ m{/api/search_tracks\?artist=U2$}),
        $url // '(no request)');

    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::sonic_fingerprint(15, sub {}, sub {});
    });
    check('sonic_fingerprint: URL has ?n=',
        scalar($url =~ m{/api/sonic_fingerprint/generate\?n=15$}),
        $url // '(no request)');

    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::find_path('100', '200', 8, sub {}, sub {});
    });
    check('find_path: URL has start, end, max_steps',
        scalar($url =~ m{/api/find_path\?start_song_id=100&end_song_id=200&max_steps=8$}),
        $url // '(no request)');

    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::task_status('tid-x', sub {}, sub {});
    });
    check('task_status: URL embeds task id',
        scalar($url =~ m{/api/status/tid-x$}), $url // '(no request)');
}

# ---------------------------------------------------------------------------
# POST endpoints with simple `start` semantics — paths should not 404
# ---------------------------------------------------------------------------
{
    my ($url, undef) = fire_post(sub {
        Plugins::AudioMuseAI::API::start_analysis(sub {}, sub {});
    });
    check('start_analysis: URL',
        scalar($url =~ m{/api/analysis/start$}), $url // '(no request)');

    ($url, undef) = fire_post(sub {
        Plugins::AudioMuseAI::API::start_clustering(sub {}, sub {});
    });
    check('start_clustering: URL',
        scalar($url =~ m{/api/clustering/start$}), $url // '(no request)');

    ($url, undef) = fire_post(sub {
        Plugins::AudioMuseAI::API::cancel_task('tid-y', sub {}, sub {});
    });
    check('cancel_task: URL embeds task id',
        scalar($url =~ m{/api/cancel/tid-y$}), $url // '(no request)');
}

# ---------------------------------------------------------------------------
# v3.x additions
# ---------------------------------------------------------------------------
{
    my ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::alchemy(
            ['100', 'artist:184394', 'playlist:77', 'anchor:3'], ['artist:9'],
            25, sub {}, sub {});
    });
    my %t = map { ($_->{op} . ':' . $_->{type} . ':' . $_->{id}) => 1 } @{ $body->{items} || [] };
    check('alchemy: typed refs become {type,id} items',
        $t{'ADD:song:100'} && $t{'ADD:artist:184394'} && $t{'ADD:playlist:77'}
            && $t{'ADD:anchor:3'} && $t{'SUBTRACT:artist:9'},
        encode_json($body));
}
{
    my ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::album_creation('song', '123', sub {}, sub {});
    });
    check('album_creation(song): URL + body',
        $url =~ m{/api/album_creation/generate$} && $body->{seed_type} eq 'song'
            && $body->{item_id} eq '123', ($url // '') . ' ' . encode_json($body));
    (undef, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::album_creation('text', 'jazz piano', sub {}, sub {});
    });
    check('album_creation(text): query carried',
        $body->{seed_type} eq 'text' && $body->{query} eq 'jazz piano', encode_json($body));
}
{
    my ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::hyperbolic_similar('55', 'niche', 30, sub {}, sub {});
    });
    check('hyperbolic_similar: URL + mode + limit',
        $url =~ m{/api/hyperbolic/similar$} && $body->{mode} eq 'niche'
            && $body->{limit} == 30 && $body->{item_id} eq '55', encode_json($body));
    ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::hyperbolic_journey('1', '2', 14, sub {}, sub {});
    });
    check('hyperbolic_journey: URL + endpoints + length',
        $url =~ m{/api/hyperbolic/journey$} && $body->{start_item_id} eq '1'
            && $body->{end_item_id} eq '2' && $body->{length} == 14, encode_json($body));
}
{
    my $url = fire_get(sub {
        Plugins::AudioMuseAI::API::find_path('1', '2', 12, sub {}, sub {}, 'lyrics');
    });
    check('find_path(lyrics): path_space=lyrics',
        scalar(($url // '') =~ /path_space=lyrics/), $url // '');
    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::find_path('1', '2', 12, sub {}, sub {}, 'audio');
    });
    check('find_path(audio): no path_space', ($url // '') !~ /path_space/, $url // '');
    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::similar_by_mood('happy', 2, 20, sub {}, sub {});
    });
    check('similar_by_mood: mood + centroid_index',
        scalar(($url // '') =~ m{/api/similar_tracks\?mood=happy&centroid_index=2&n=20}), $url // '');
    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::similar_by_anchor(4, 20, sub {}, sub {});
    });
    check('similar_by_anchor: anchor_id', scalar(($url // '') =~ /anchor_id=4&n=20/), $url // '');
}
{
    my ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::lyrics_search_axes({ AXIS_1_SETTING => 'URBAN' }, 20, sub {}, sub {});
    });
    check('lyrics_search_axes: targets + limit',
        $url =~ m{/api/lyrics/search/axes$} && $body->{targets}{AXIS_1_SETTING} eq 'URBAN'
            && $body->{limit} == 20, encode_json($body));
    ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::clap_search('jazz', 20, sub {}, sub {},
            [{ term => 'piano', direction => 'more', weight => 5 }]);
    });
    check('clap_search: steering forwarded',
        ref($body->{steering}) eq 'ARRAY' && $body->{steering}[0]{term} eq 'piano',
        encode_json($body));
    ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::clap_search('jazz', 20, sub {}, sub {});
    });
    check('clap_search: no steering key when unused', !exists $body->{steering}, encode_json($body));
    ($url, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::chat_playlist('80s synth', 30, sub {}, sub {});
    });
    check('chat_playlist: n forwarded',
        $url =~ m{/chat/api/chatPlaylist$} && $body->{n} == 30 && $body->{userInput} eq '80s synth',
        encode_json($body));
}
# ---------------------------------------------------------------------------
# server_name — AudioMuse-AI multi-server selector (#7). Blank = no `server`
# param at all. Set = appended to the query string of every GET and added to
# the JSON body of every POST (AudioMuse reads either).
# Adapted from Tstassin's tests in PR #8, including the scalar() rule: in
# check()'s argument list a FAILED m// returns an empty list, shifting
# $detail into $ok -- a silent PASS. Every match below is wrapped.
# ---------------------------------------------------------------------------
{
    my $prefs = Slim::Utils::Prefs::preferences('plugin.audiomuseai');

    $prefs->set('server_name', '');
    my $url = fire_get(sub {
        Plugins::AudioMuseAI::API::similar_tracks('1', 10, sub {}, sub {});
    });
    check('server_name blank: no server param',
        scalar(($url // '') !~ /server=/), $url // '(no request)');
    my (undef, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::alchemy(['1'], [], 25, sub {}, sub {});
    });
    check('server_name blank: no server key in POST body',
        !exists $body->{server}, encode_json($body // {}));

    $prefs->set('server_name', 'Lyrion');
    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::similar_tracks('1', 10, sub {}, sub {});
    });
    check('server_name: appended with & when the path has a query',
        scalar(($url // '') =~ m{/api/similar_tracks\?item_id=1&n=10&eliminate_duplicates=true&server=Lyrion$}),
        $url // '(no request)');

    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::health(sub {}, sub {});
    });
    check('server_name: appended with ? when the path has no query',
        scalar(($url // '') =~ m{/api/health\?server=Lyrion$}), $url // '(no request)');

    my $purl;
    ($purl, $body) = fire_post(sub {
        Plugins::AudioMuseAI::API::alchemy(['1'], [], 25, sub {}, sub {});
    });
    check('server_name: POST carries it in the JSON body',
        ($body->{server} // '') eq 'Lyrion', encode_json($body // {}));
    check('server_name: POST URL left plain',
        scalar(($purl // '') =~ m{/api/alchemy$}), $purl // '(no request)');

    $prefs->set('server_name', '  Lyrion  ');
    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::health(sub {}, sub {});
    });
    check('server_name: surrounding whitespace trimmed',
        scalar(($url // '') =~ m{\?server=Lyrion$}), $url // '(no request)');

    $prefs->set('server_name', 'My LMS & Co');
    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::health(sub {}, sub {});
    });
    check('server_name: percent-encoded (space, &)',
        scalar(($url // '') =~ m{\?server=My%20LMS%20%26%20Co$}), $url // '(no request)');

    # A decoded character string, as Lyrion hands over settings-form input.
    my $name = "Salon \x{c9}ric";
    utf8::upgrade($name);
    $prefs->set('server_name', $name);
    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::health(sub {}, sub {});
    });
    check('server_name: non-ASCII percent-encoded as UTF-8',
        scalar(($url // '') =~ m{\?server=Salon%20%C3%89ric$}), $url // '(no request)');

    # A name containing CR/LF is treated as invalid and not sent at all.
    $prefs->set('server_name', "Ly\r\nrion");
    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::health(sub {}, sub {});
    });
    check('server_name: embedded CR/LF never reaches the request',
        scalar(($url // '') !~ /server=/ && ($url // '') !~ /[\r\n]/), $url // '(no request)');

    # peek_active_tasks must read the same (server-scoped) cache key that
    # active_tasks writes — and must not see another server's entry.
    $prefs->set('server_name', 'Lyrion');
    Slim::Networking::SimpleAsyncHTTP::reset_captures();
    $Slim::Networking::SimpleAsyncHTTP::next_response_body =
        '{"status":"RUNNING","task_id":"t-peek"}';
    Plugins::AudioMuseAI::API::active_tasks(sub {}, sub {});
    $url = last_get() ? last_get()->{url} : undef;
    check('server_name: active_tasks carries it',
        scalar(defined $url && $url =~ m{/api/active_tasks\?server=Lyrion$}),
        $url // '(no request)');
    my $peek = Plugins::AudioMuseAI::API::peek_active_tasks();
    check('server_name: peek_active_tasks hits the server-scoped cache',
        ref($peek) eq 'HASH' && ($peek->{task_id} // '') eq 't-peek',
        encode_json($peek // {}));

    $prefs->set('server_name', 'Other');
    $peek = Plugins::AudioMuseAI::API::peek_active_tasks();
    check("server_name: peek_active_tasks ignores another server's entry",
        !defined $peek, encode_json($peek // {}));

    $prefs->set('server_name', '');
    Slim::Networking::SimpleAsyncHTTP::reset_captures();
}

# ---------------------------------------------------------------------------
print "\n----\n02-payloads: $pass passed, $fail failed\n";
exit($fail ? 1 : 0);
