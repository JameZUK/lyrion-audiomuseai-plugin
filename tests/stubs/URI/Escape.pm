package URI::Escape;
# Real URL-encoding so tests catch bad values in path/query construction.
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(uri_escape uri_escape_utf8);

# Minimal RFC 3986 unreserved-chars escaper. Plugin only uses
# uri_escape_utf8 with track ids / artist names; this is sufficient.
sub uri_escape_utf8 {
    my $s = shift // '';
    utf8::encode($s) if utf8::is_utf8($s);
    $s =~ s/([^A-Za-z0-9\-\._~])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}
*uri_escape = \&uri_escape_utf8;

1;
