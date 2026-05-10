package Slim::Utils::Log;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw(logger);

# All log calls become no-ops so test output stays clean. If you need to
# inspect log calls in a test, swap in a recording impl here.
sub logger          { return bless {}, __PACKAGE__ }
sub addLogCategory  { return bless {}, __PACKAGE__ }
sub debug { 1 }
sub info  { 1 }
sub warn  { 1 }
sub error { 1 }

1;
