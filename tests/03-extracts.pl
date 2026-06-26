#!/usr/bin/env perl
# Response-shape tests for Plugin.pm::_extractTracks. For every shape an
# AudioMuse endpoint actually returns, feed a canonical fixture through
# the extractor and confirm it yields the right list (or [] for errors).
#
# Adding support for a new response shape? Add a fixture below AND extend
# _extractTracks in Plugin.pm. Each fixture's comment should cite the
# upstream blueprint file that produces the shape.
#
# Run via tests/run-all.sh or:
#   PERL5LIB=tests/stubs perl tests/03-extracts.pl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/stubs";

package main;
use constant WEBUI => 0;

require Plugins::AudioMuseAI::Plugin;
use JSON::PP qw(encode_json);

my $extract = \&Plugins::AudioMuseAI::Plugin::_extractTracks;
my ($pass, $fail) = (0, 0);
sub check {
    my ($desc, $ok, $detail) = @_;
    if ($ok) { print "PASS  $desc\n"; $pass++; }
    else     { print "FAIL  $desc\n      $detail\n"; $fail++; }
}

# --- fixtures (each cites the upstream source it mirrors) ---

# app_voyager.py::get_similar_tracks_endpoint — bare array.
my $similar_tracks_fx = [
    { item_id => '1001', title => 'A', author => 'X', album => 'Alb', distance => 0.12 },
    { item_id => '1002', title => 'B', author => 'Y', album => 'Alb', distance => 0.18 },
];

# app_voyager.py::search_tracks_endpoint — bare array.
my $search_tracks_fx = [
    { item_id => '1', title => 't1', author => 'a', album => 'A' },
    { item_id => '2', title => 't2', author => 'a', album => 'A' },
];

# app_sonic_fingerprint.py — bare array.
my $sonic_fp_fx = [
    { item_id => '5', title => 's', author => 'x', distance => 0.1 },
];

# app_clap_search.py::clap_search_api — wrapped {query, results, count}.
my $clap_fx = {
    query   => 'x',
    count   => 3,
    results => [
        { item_id => '10', title => 'Q1', author => 'A1', album => 'B1', similarity => 0.95 },
        { item_id => '20', title => 'Q2', author => 'A2', album => 'B2', similarity => 0.92 },
        { item_id => '30', title => 'Q3', author => 'A3', album => 'B3', similarity => 0.90 },
    ],
};

# app_lyrics.py::lyrics_search_text_api — same wrap as clap.
my $lyrics_fx = {
    query   => 'rainy heartbreak',
    count   => 2,
    results => [
        { item_id => 'L1', title => 'Lyric song 1' },
        { item_id => 'L2', title => 'Lyric song 2' },
    ],
};

# Lyrics 404 path — server returns {error, query, results: []}.
my $lyrics_empty_fx = {
    error   => 'No lyrics found.',
    query   => 'gibberish',
    results => [],
};

# app_alchemy.py::alchemy_api — full upstream return.
my $alchemy_fx = {
    results       => [
        { item_id => '100', title => 'Mix A', author => 'X', distance => 0.1 },
        { item_id => '200', title => 'Mix B', author => 'Y', distance => 0.2 },
    ],
    filtered_out  => [{ item_id => '999' }],
    centroid_2d   => [0.1, 0.2],
    add_points    => [],
    sub_points    => [],
    projection    => 'pca',
};

# app_path.py::find_path_endpoint — wrapped {path, total_distance}.
my $find_path_fx = {
    path => [
        { item_id => '1', title => 'Start' },
        { item_id => '2', title => 'Mid'   },
        { item_id => '3', title => 'End'   },
    ],
    total_distance => 1.234,
};

# app_chat.py::chatPlaylist — _chatPlaylist already unwraps `response`,
# but _extractTracks should ALSO cope with a bare {query_results: [...]}.
my $chat_inner_fx = {
    query_results => [
        { item_id => 'q1', title => 'AI pick 1' },
        { item_id => 'q2', title => 'AI pick 2' },
    ],
};

# --- assertions ---

my @ok_cases = (
    [ 'similar_tracks (array)',       $similar_tracks_fx, 2,  '1001' ],
    [ 'search_tracks (array)',        $search_tracks_fx, 2,   '1'    ],
    [ 'sonic_fingerprint (array)',    $sonic_fp_fx, 1,         '5'    ],
    [ 'clap_search ({results})',      $clap_fx, 3,            '10'   ],
    [ 'lyrics_search ({results})',    $lyrics_fx, 2,          'L1'   ],
    [ 'alchemy ({results, ...})',     $alchemy_fx, 2,         '100'  ],
    [ 'find_path ({path})',           $find_path_fx, 3,       '1'    ],
    [ 'chat-playlist inner ({query_results})', $chat_inner_fx, 2, 'q1' ],
);

for my $case (@ok_cases) {
    my ($name, $fx, $want_count, $want_first_id) = @$case;
    my $got = $extract->($fx);
    my $ok = ref($got) eq 'ARRAY' && @$got == $want_count;
    $ok &&= ($got->[0]{item_id} // '') eq $want_first_id if defined $want_first_id;
    my $id_part = defined $want_first_id ? " starting with id=$want_first_id" : '';
    check("_extractTracks: $name", $ok,
        "expected $want_count item(s)$id_part; got: " . encode_json($got));
}

# --- empty / malformed inputs must return [] (never undef) ---

my @empty_cases = (
    [ 'empty hash',             {} ],
    [ 'undef input',            undef ],
    [ 'results value not-array', { results => 'oops' } ],
    [ 'path value not-array',    { path    => 'oops' } ],
    [ 'lyrics 404 body',         $lyrics_empty_fx ],
);

for my $case (@empty_cases) {
    my ($name, $fx) = @$case;
    my $got = $extract->($fx);
    check("_extractTracks: $name → []",
        ref($got) eq 'ARRAY' && @$got == 0,
        'got: ' . (defined $got ? encode_json($got) : 'undef'));
}

# ---------------------------------------------------------------------------
print "\n----\n03-extracts: $pass passed, $fail failed\n";
exit($fail ? 1 : 0);
