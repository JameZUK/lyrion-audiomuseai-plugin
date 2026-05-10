package Slim::Utils::Strings;
# Identity stub for string lookups — returns the key as-is, which is
# what tests want (we assert on key names rather than localized text).
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(string cstring);

sub string  { return shift }
sub cstring { return shift }

1;
