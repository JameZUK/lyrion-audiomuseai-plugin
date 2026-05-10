package Slim::Networking::SimpleAsyncHTTP;
# Test mock for Lyrion's async HTTP client. Captures every GET/POST so
# tests can assert on the URL and JSON payload the plugin would send.
# Fires the success callback synchronously with whatever body has been
# stashed in $next_response_body — set this to the JSON you want the
# plugin to receive before invoking the API method under test.

use strict;
use warnings;

our @captured_posts;
our @captured_gets;
our $next_response_body = '{}';

sub reset_captures {
    @captured_posts  = ();
    @captured_gets   = ();
    $next_response_body = '{}';
}

sub new {
    my ($class, $cb_ok, $cb_err, $opts) = @_;
    return bless {
        cb_ok  => $cb_ok,
        cb_err => $cb_err,
        opts   => $opts,
    }, $class;
}

sub get {
    my ($self, $url, @headers) = @_;
    push @captured_gets, { url => $url, headers => [@headers] };
    my $resp = bless { _body => $next_response_body }, '_FakeResp';
    $self->{cb_ok}->($resp);
}

sub post {
    my ($self, $url, @rest) = @_;
    # Plugin's API.pm calls $http->post($url, _headers(), 'Content-Type' =>
    # 'application/json', $body); the body is always the last arg.
    my $body = pop @rest;
    push @captured_posts, { url => $url, body => $body, headers => [@rest] };
    my $resp = bless { _body => $next_response_body }, '_FakeResp';
    $self->{cb_ok}->($resp);
}

package _FakeResp;
sub content { $_[0]->{_body} }

1;
