package Slim::Utils::Cache;
# In-process key/value cache. The plugin uses this for short-TTL HTTP
# caching (active_tasks, search results); tests don't care about TTL.

use strict;
use warnings;

my %store;

sub new {
    my ($class, $ns) = @_;
    return bless { _ns => $ns // '' }, $class;
}

sub get {
    my ($self, $key) = @_;
    return $store{$self->{_ns}}{$key};
}

sub set {
    my ($self, $key, $val, $ttl) = @_;
    $store{$self->{_ns}}{$key} = $val;
    return 1;
}

sub remove {
    my ($self, $key) = @_;
    delete $store{$self->{_ns}}{$key};
}

1;
