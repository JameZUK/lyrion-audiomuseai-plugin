package Slim::Web::Settings;
use strict;
use warnings;

# The plugin's Settings.pm subclasses this; tests don't exercise the web
# settings page, so a near-empty base class is enough to satisfy `use base`.

sub new       { bless {}, shift }
sub handler   { 1 }

1;
