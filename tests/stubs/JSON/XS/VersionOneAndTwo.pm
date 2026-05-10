package JSON::XS::VersionOneAndTwo;
# Real JSON encode/decode for tests so payload assertions compare actual
# data, not '{}' from a no-op stub. Plugin uses from_json/to_json by name,
# both exported by default to match the upstream module's behavior.

use strict;
use warnings;
use JSON::PP ();
use Exporter 'import';

our @EXPORT = qw(from_json to_json);

sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }

1;
