package Slim::Player::ProtocolHandlers;
our %handlers;
sub registerHandler { my ($class, $scheme, $pkg) = @_; $handlers{$scheme} = $pkg; 1 }
1;
