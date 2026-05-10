package Slim::Utils::Prefs;
# In-memory pref store keyed by namespace, with per-client sub-hashes.
# Tests can read / write via the same API the plugin uses; values seed
# from the plugin's $prefs->init({...}) call at load time.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw(preferences);

my %store;       # $store{$ns}{$key} = value
my %client_store; # $client_store{$ns}{$client_id}{$key} = value

sub preferences {
    my $ns = shift // '';
    return bless { _ns => $ns }, __PACKAGE__;
}

sub init {
    my ($self, $defaults) = @_;
    for my $k (keys %$defaults) {
        $store{$self->{_ns}}{$k} //= $defaults->{$k};
    }
    return 1;
}

sub get {
    my ($self, $key) = @_;
    return $store{$self->{_ns}}{$key};
}

sub set {
    my ($self, $key, $val) = @_;
    $store{$self->{_ns}}{$key} = $val;
    return 1;
}

sub client {
    my ($self, $client) = @_;
    my $id = ref($client) ? ($client->id // '_anon') : ($client // '_anon');
    return bless { _ns => $self->{_ns}, _client => $id }, '_ClientPrefs';
}

package _ClientPrefs;
sub get {
    my ($self, $key) = @_;
    return $client_store{$self->{_ns}}{$self->{_client}}{$key};
}
sub set {
    my ($self, $key, $val) = @_;
    $client_store{$self->{_ns}}{$self->{_client}}{$key} = $val;
    return 1;
}

1;
