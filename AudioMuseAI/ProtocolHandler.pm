package Plugins::AudioMuseAI::ProtocolHandler;

# audiomuse:// URLs — save an AudioMuse mix as a Lyrion favourite (or put it
# on a Material custom button / Home Assistant script). Playing the URL
# builds a fresh mix (audiomuseai mix) and replaces the queue.
# (Idea from Craig Drummond's AudioMuse Mixer, which has audiomusemixer://.)
#
#   audiomuse://?artist=Iron%20Maiden
#   audiomuse://?artist=Iron%20Maiden&album=Somewhere%20In%20Time
#   audiomuse://?genre=Heavy%20Metal
#   audiomuse://?path=%2Fmedia%2Fmusic%2F...%2F02%20Wasted%20Years.mp3
#   audiomuse://?track_id=123   (also artist_id / album_id / genre_id)
#   ...&count=15   number of tracks
#   ...&dstm=1     then keep going with AudioMuse "Don't Stop The Music"

use strict;
use warnings;

use URI::Escape qw(uri_unescape);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

my $log = logger('plugin.audiomuseai');

# Parse an audiomuse:// URL into its query parameters (undef if not ours).
sub params {
	my ($class, $url) = @_;
	return undef unless defined $url && $url =~ m{\Aaudiomuse://}i;
	my %p;
	my ($q) = $url =~ /\?(.*)\z/s;
	for my $pair (split /&/, $q // '') {
		my ($k, $v) = split /=/, $pair, 2;
		next unless defined $k && length $k;
		$v = '' unless defined $v;
		$v =~ tr/+/ /;
		$p{ lc uri_unescape($k) } = uri_unescape($v);
	}
	return \%p;
}

sub _firstId {
	my ($rs) = @_;
	my $o = eval { $rs->first };
	return $o ? $o->id : undef;
}

# Resolve names / paths to Lyrion ids; returns the `audiomuseai mix` params.
sub mixParams {
	my ($class, $p) = @_;
	my %m;
	for my $k (qw(track_id album_id artist_id genre_id)) {
		$m{$k} = $p->{$k} if defined $p->{$k} && $p->{$k} =~ /\A\d+\z/;
	}
	unless (%m) {
		if (defined $p->{path} && length $p->{path}) {
			my $url = $p->{path} =~ m{\Afile:}i ? $p->{path} : eval { Slim::Utils::Misc::fileURLFromPath($p->{path}) };
			my $t = eval { Slim::Schema->objectForUrl({ url => $url }) };
			$m{track_id} = $t->id if $t && eval { $t->id };
		}
		elsif (defined $p->{genre} && length $p->{genre}) {
			my $id = _firstId(eval { Slim::Schema->rs('Genre')->search_rs({ 'me.name' => $p->{genre} }) });
			$m{genre_id} = $id if defined $id;
		}
		elsif (defined $p->{artist} && length $p->{artist}) {
			my $aid = _firstId(eval { Slim::Schema->rs('Contributor')->search_rs({ 'me.name' => $p->{artist} }) });
			if (defined $aid && defined $p->{album} && length $p->{album}) {
				my $alid = _firstId(eval { Slim::Schema->rs('Album')->search_rs(
					{ 'me.title' => $p->{album}, 'me.contributor' => $aid }) });
				$m{album_id} = $alid if defined $alid;
			}
			$m{artist_id} = $aid if defined $aid && !$m{album_id};
		}
	}
	$m{count}  = $p->{count} if defined $p->{count} && $p->{count} =~ /\A\d+\z/;
	$m{dstm}   = 1 if ($p->{dstm} // '') eq '1';
	$m{artist} = $p->{artist} if defined $p->{artist} && length $p->{artist};
	return \%m;
}

sub overridePlayback {
	my ($class, $client, $url) = @_;
	return unless $client;
	my $p = $class->params($url) or return;

	# Part of a playlist and the previous track is still playing: wait.
	if (Slim::Player::Source::streamingSongIndex($client)) {
		return if $client->controller()->playingSongDuration();
	}

	my $m = $class->mixParams($p);
	unless (grep { defined $m->{$_} } qw(track_id album_id artist_id genre_id)) {
		$log->info("audiomuse:// nothing in the library matches $url");
		if ($m->{artist} && exists $INC{'Plugins/LastMix/ProtocolHandler.pm'}) {
			$client->execute(['lastmix', 'play', "artist:$m->{artist}"]);
		}
		return 1;
	}
	my @cmd = ('audiomuseai', 'mix', map { "$_:$m->{$_}" } sort keys %$m);
	$log->info('audiomuse:// -> ' . join(' ', @cmd));
	Slim::Control::Request::executeRequest($client, \@cmd);
	return 1;
}

sub canDirectStream { 0 }
sub isRemote        { 0 }
sub contentType     { 'audiomuse' }

sub getIcon { 'plugins/AudioMuseAI/html/images/icon_svg.png' }

sub getMetadataFor {
	my ($class, $client, $url) = @_;
	my $p = $class->params($url) or return {};
	my $title = $p->{genre}
		// (defined $p->{artist} && defined $p->{album} ? "$p->{artist} - $p->{album}" : undef)
		// $p->{artist}
		// (defined $p->{path} ? (split m{/}, $p->{path})[-1] : undef)
		// '?';
	return {
		title  => $title,
		artist => string('PLUGIN_AUDIOMUSEAI_MIX'),
		cover  => $class->getIcon,
		icon   => $class->getIcon,
	};
}

1;
