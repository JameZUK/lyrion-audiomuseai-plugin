package Slim::Utils::Timers;
# No-op timer stub. Plugin uses setTimer for the deferred startup
# health-check; tests don't actually fire timed work.

use strict;
use warnings;

sub setTimer     { 1 }
sub killSpecific { 1 }

1;
