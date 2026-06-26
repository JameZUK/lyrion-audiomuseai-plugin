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
        $url =~ m{/api/clap/search$}, $url // '(no request captured)');
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
        $url =~ m{/api/alchemy$}, $url // '(no request)');
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
        $url =~ m{/api/clap/warmup$}, $url // '(no request)');
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
        $url =~ m{/api/lyrics/search/text$}, $url // '(no request)');
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
        $url =~ m{/chat/api/chatPlaylist$}, $url // '(no request)');
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
        $url =~ m{/api/similar_tracks\?item_id=item123&n=10&eliminate_duplicates=true$},
        $url // '(no request)');

    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::search_tracks('U2', sub {}, sub {});
    });
    check('search_tracks: URL uses legacy `artist=` (server has back-compat)',
        $url =~ m{/api/search_tracks\?artist=U2$},
        $url // '(no request)');

    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::sonic_fingerprint(15, sub {}, sub {});
    });
    check('sonic_fingerprint: URL has ?n=',
        $url =~ m{/api/sonic_fingerprint/generate\?n=15$},
        $url // '(no request)');

    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::find_path('100', '200', 8, sub {}, sub {});
    });
    check('find_path: URL has start, end, max_steps',
        $url =~ m{/api/find_path\?start_song_id=100&end_song_id=200&max_steps=8$},
        $url // '(no request)');

    $url = fire_get(sub {
        Plugins::AudioMuseAI::API::task_status('tid-x', sub {}, sub {});
    });
    check('task_status: URL embeds task id',
        $url =~ m{/api/status/tid-x$}, $url // '(no request)');
}

# ---------------------------------------------------------------------------
# POST endpoints with simple `start` semantics — paths should not 404
# ---------------------------------------------------------------------------
{
    my ($url, undef) = fire_post(sub {
        Plugins::AudioMuseAI::API::start_analysis(sub {}, sub {});
    });
    check('start_analysis: URL',
        $url =~ m{/api/analysis/start$}, $url // '(no request)');

    ($url, undef) = fire_post(sub {
        Plugins::AudioMuseAI::API::start_clustering(sub {}, sub {});
    });
    check('start_clustering: URL',
        $url =~ m{/api/clustering/start$}, $url // '(no request)');

    ($url, undef) = fire_post(sub {
        Plugins::AudioMuseAI::API::cancel_task('tid-y', sub {}, sub {});
    });
    check('cancel_task: URL embeds task id',
        $url =~ m{/api/cancel/tid-y$}, $url // '(no request)');
}

# ---------------------------------------------------------------------------
print "\n----\n02-payloads: $pass passed, $fail failed\n";
exit($fail ? 1 : 0);
