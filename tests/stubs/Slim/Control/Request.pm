package Slim::Control::Request;
# Records every dispatcher the plugin registers so tests can assert on
# the registered set (we use this to verify "for every API endpoint, a
# corresponding dispatcher exists"). subscribe / unsubscribe are no-ops
# because tests don't drive event flow.

use strict;
use warnings;

our @dispatchers;  # each: { cmd => [...], spec => [...], handler => \&fn }

sub addDispatch {
    my ($cmd, $spec, $handler) = @_;
    push @dispatchers, {
        cmd     => $cmd,
        spec    => $spec,
        handler => $spec->[3],
    };
}

sub subscribe       { 1 }
sub unsubscribe     { 1 }
sub executeRequest  { return bless {}, __PACKAGE__ }
sub getResult       { return $_[0]->{$_[1]} }
sub addResult       { $_[0]->{$_[1]} = $_[2]; 1 }
sub setStatusDone        { 1 }
sub setStatusProcessing  { 1 }
sub setStatusBadParams   { 1 }
sub addParam            { 1 }
sub getParam            { return undef }
sub client              { return undef }

1;
