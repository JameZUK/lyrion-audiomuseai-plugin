package Slim::Web::Pages;
use strict;
use warnings;

our (%links, %functions);
sub addPageLinks    { my ($class, $cat, $l) = @_; $links{$cat} = { %{ $links{$cat} || {} }, %$l }; }
sub addPageFunction { my ($class, $url, $fn) = @_; $functions{$url} = $fn; }

1;
