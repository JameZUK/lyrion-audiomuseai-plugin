package Slim::Web::XMLBrowser;
use strict;
use warnings;

our @calls;
sub handleWebIndex { my ($class, $args) = @_; push @calls, $args; }

1;
