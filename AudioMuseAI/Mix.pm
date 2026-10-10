package Plugins::AudioMuseAI::Mix;

# Mix filters — applied to the candidates AudioMuse returns before anything
# is queued. Ideas from Craig Drummond's AudioMuse Mixer DSTM plugin
# (https://github.com/CDrummond/lms-audiomuse-mixer), reimplemented here:
#
#   hard filters (never relaxed):
#     - minimum / maximum duration
#     - Christmas-tagged tracks only in December
#     - excluded artists, excluded albums ("Artist//Album" or "Album")
#     - genre groups: stay within the seed tracks' genre group(s)
#   soft filters (relaxed when too few candidates survive):
#     - don't repeat an artist within N tracks
#     - don't repeat an album within N tracks (Various Artists exempt)
#   variety:
#     - shuffle the best 2 x $want candidates, so the same seed doesn't
#       always produce the same order
#
# Rows are the plugin's normal result rows ({ item_id, title, author, ... })
# already resolved to local Lyrion track ids (Plugin::_localizeRows).

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.audiomuseai');
my $prefs = preferences('plugin.audiomuseai');

my %XMAS_GENRES = map { $_ => 1 } qw(christmas xmas);

# Parsed copies of the list prefs, rebuilt only when the pref text changes.
my %_cache;   # name => [ pref text, parsed value ]

sub _num {
	my ($name, $default) = @_;
	my $v = $prefs->get($name);
	return $default unless defined $v && $v =~ /\A\s*-?\d+\s*\z/;
	$v = int($v);
	return $v < 0 ? 0 : $v;
}

sub _lines {
	my $text = shift // '';
	return grep { length } map { my $l = $_; $l =~ s/\A\s+|\s+\z//g; $l } split /\r?\n/, $text;
}

# Parsed value for $key, rebuilt only when $text (the source settings) changes.
sub _cached {
	my ($name, $build, $text) = @_;
	$text //= $prefs->get($name) // '';
	my $hit = $_cache{$name};
	return $hit->[1] if $hit && $hit->[0] eq $text;
	my $val = $build->($prefs->get($name) // '');
	$_cache{$name} = [ $text, $val ];
	return $val;
}

# Lyrion invalidates ids on a rescan; forget parsed lists so they re-resolve.
sub resetCaches { %_cache = () }

sub _contributorIds {
	my $name = shift;
	my @ids;
	eval {
		my $rs = Slim::Schema->rs('Contributor')->search_rs({ 'me.name' => $name });
		while (my $c = $rs->next) { push @ids, $c->id }
	};
	return @ids;
}

sub excludedArtists {
	return _cached('mix_exclude_artists', sub {
		my %ids;
		$ids{$_} = 1 for map { _contributorIds($_) } _lines(shift);
		return \%ids;
	});
}

sub excludedAlbums {
	return _cached('mix_exclude_albums', sub {
		my %ids;
		for my $line (_lines(shift)) {
			my ($artist, $album) = $line =~ m{\A(.*?)//(.*)\z} ? ($1, $2) : (undef, $line);
			eval {
				my %where = ('me.title' => $album);
				if (defined $artist && length $artist) {
					my @a = _contributorIds($artist) or return;
					$where{'me.contributor'} = { -in => \@a };
				}
				my $rs = Slim::Schema->rs('Album')->search_rs(\%where);
				while (my $al = $rs->next) { $ids{ $al->id } = 1 }
			};
		}
		return \%ids;
	});
}

# [ { genre => 1, ... }, ... ] — one hash per configured group, plus (with
# "use the track's own genre") a single-genre group for every library genre
# that isn't in a configured group.
sub genreGroups {
	my $useOwn = $prefs->get('mix_use_track_genre') ? 1 : 0;
	return _cached('mix_genre_groups', sub {
		my @groups;
		my %inGroup;
		for my $line (_lines(shift)) {
			my %g = map { $_ => 1 } grep { length }
				map { my $x = $_; $x =~ s/\A\s+|\s+\z//g; lc $x } split /;/, $line;
			next unless %g;
			$inGroup{$_} = 1 for keys %g;
			push @groups, \%g;
		}
		if ($useOwn) {
			eval {
				my $req = Slim::Control::Request::executeRequest(undef, ['genres', 0, 5000]);
				for my $g (@{ ($req && $req->getResult('genres_loop')) || [] }) {
					my $n = lc($g->{genre} // $g->{name} // '');
					push @groups, { $n => 1 } if length $n && !$inGroup{$n}++;
				}
			};
		}
		return \@groups;
	}, ($prefs->get('mix_genre_groups') // '') . "\0$useOwn");
}

sub _trackGenres {
	my $track = shift;
	my @g;
	eval { @g = map { lc($_->name // '') } $track->genres };
	return grep { length } @g;
}

sub _inGroup {
	my ($genres, $group, $matchAll) = @_;
	return 0 unless @$genres;
	if ($matchAll) {
		for (@$genres) { return 0 unless $group->{$_} }
		return 1;
	}
	for (@$genres) { return 1 if $group->{$_} }
	return 0;
}

sub _isXmas {
	my $track = shift;
	for (_trackGenres($track)) { return 1 if $XMAS_GENRES{$_} }
	return 0;
}

sub _december { return (localtime)[4] == 11 }

sub _artistId { my $t = shift; return eval { $t->artistid } }
sub _albumId  { my $t = shift; return eval { $t->albumid } }

my $_vaId;
sub _variousArtistsId {
	return $_vaId //= eval { Slim::Schema->variousArtistsObject->id } // -1;
}

# Settings snapshot (also handy for tests).
sub settings {
	return {
		no_repeat_artist => _num('mix_no_repeat_artist', 10),
		no_repeat_album  => _num('mix_no_repeat_album', 20),
		min_duration     => _num('mix_min_duration', 0),
		max_duration     => _num('mix_max_duration', 0),
		filter_xmas      => $prefs->get('mix_filter_xmas') ? 1 : 0,
		filter_genres    => $prefs->get('mix_filter_genres') ? 1 : 0,
		match_all_genres => $prefs->get('mix_match_all_genres') ? 1 : 0,
		shuffle          => $prefs->get('mix_shuffle') ? 1 : 0,
	};
}

# Hard filter for a single Lyrion track (also used to pick seeds).
sub durationOk {
	my ($track, $cfg) = @_;
	$cfg ||= settings();
	my $secs = eval { $track->secs } // 0;
	return 0 if $cfg->{min_duration} && $secs && $secs < $cfg->{min_duration};
	return 0 if $cfg->{max_duration} && $secs && $secs > $cfg->{max_duration};
	return 1;
}

# Apply the filters.
#   $rows  — candidate rows, best first
#   %ctx   — want     => how many to return (0 = all that pass)
#            prev     => [ Lyrion track objects ] just before, oldest first
#                        (the queue tail) — for artist / album spacing
#            seeds    => [ Lyrion track objects ] — for genre groups
#            shuffle  => override the shuffle pref (0 for ordered output)
# Returns the filtered rows (at most `want`).
sub apply {
	my ($rows, %ctx) = @_;
	my $cfg  = settings();
	my $want = $ctx{want} || 0;
	my $shuffle = exists $ctx{shuffle} ? $ctx{shuffle} : $cfg->{shuffle};
	my $exA  = excludedArtists();
	my $exAl = excludedAlbums();
	my $xmas = $cfg->{filter_xmas} && !_december();

	# Genre groups from the seeds. If no seed is in any group, then the
	# candidates must not be in a group either (as in AudioMuse Mixer).
	my ($accept, $reject);
	if ($cfg->{filter_genres} && @{ $ctx{seeds} || [] }) {
		my $groups = genreGroups() || [];
		if (@$groups) {
			my %acc;
			for my $s (@{ $ctx{seeds} }) {
				my @sg = _trackGenres($s);
				for my $g (@$groups) {
					%acc = (%acc, %$g) if _inGroup(\@sg, $g, $cfg->{match_all_genres});
				}
			}
			if (%acc) { $accept = \%acc }
			else      { $reject = { map { %$_ } @$groups } }
		}
	}

	# Positions of artists / albums in the recent past.
	my (%artistAt, %albumAt);
	my $pos = 0;
	for my $t (@{ $ctx{prev} || [] }) {
		my $a  = _artistId($t);
		my $al = _albumId($t);
		$artistAt{$a}  = $pos if defined $a;
		$albumAt{$al}  = $pos if defined $al;
		$pos++;
	}

	my $va = _variousArtistsId();
	my (@usable, @spacedArtist, @spacedAlbum);
	my %count = map { $_ => 0 } qw(duration xmas excluded genre artist album);
	for my $r (@$rows) {
		my $t = $r->{_obj} || eval { Slim::Schema->find('Track', $r->{item_id}) } or next;
		$r->{_obj} = $t;
		if (!durationOk($t, $cfg))            { $count{duration}++; next }
		if ($xmas && _isXmas($t))             { $count{xmas}++;     next }
		my $a  = _artistId($t);
		my $al = _albumId($t);
		if ((defined $a && $exA->{$a}) || (defined $al && $exAl->{$al})) { $count{excluded}++; next }
		if ($accept || $reject) {
			my @g = _trackGenres($t);
			if (($accept && !_inGroup(\@g, $accept, $cfg->{match_all_genres}))
				|| ($reject && _inGroup(\@g, $reject, 0))) { $count{genre}++; next }
		}
		if ($cfg->{no_repeat_artist} && defined $a && exists $artistAt{$a}
			&& $pos - $artistAt{$a} <= $cfg->{no_repeat_artist}) {
			$count{artist}++; push @spacedArtist, $r; next;
		}
		if ($cfg->{no_repeat_album} && defined $al && (!defined $a || $a != $va)
			&& exists $albumAt{$al} && $pos - $albumAt{$al} <= $cfg->{no_repeat_album}) {
			$count{album}++; push @spacedAlbum, $r; next;
		}
		$artistAt{$a} = $pos if defined $a;
		$albumAt{$al} = $pos if defined $al;
		push @usable, $r;
		$pos++;
	}

	# Too few? Relax the spacing (artist first, then album) before giving up.
	if ($want && @usable < $want) {
		for my $r (@spacedArtist, @spacedAlbum) {
			last if @usable >= $want;
			push @usable, $r;
		}
	}

	if ($shuffle && @usable > 1) {
		my $pool = $want ? 2 * $want : scalar @usable;
		@usable = @usable[0 .. $pool - 1] if @usable > $pool;
		for (my $i = $#usable; $i > 0; $i--) {
			my $j = int rand($i + 1);
			@usable[$i, $j] = @usable[$j, $i];
		}
	}
	@usable = @usable[0 .. $want - 1] if $want && @usable > $want;

	$log->info(sprintf('mix filters: %d of %d kept (dropped: %s)',
		scalar @usable, scalar @$rows,
		join(', ', map { "$_ $count{$_}" } grep { $count{$_} } sort keys %count) || 'none'))
		if @$rows;
	return \@usable;
}

# Seed tracks from the end of a player's queue: library files only (no
# radio / remote streams), duration-filtered where possible.
#   $n      — how many seeds
#   $strict — take exactly the last $n; otherwise sample $n at random from
#             the last 2 x $n (or from the last 4 when $n == 1)
sub seedTracks {
	my ($client, $n, $strict) = @_;
	$n = 1 unless $n && $n > 0;
	my $pool = $strict ? $n : ($n == 1 ? 4 : 2 * $n);
	my $cfg = settings();
	my (@ok, @long);
	my $count = Slim::Player::Playlist::count($client) || 0;
	for (my $i = $count - 1; $i >= 0 && @ok < $pool; $i--) {
		my $t = Slim::Player::Playlist::track($client, $i) or next;
		next unless eval { $t->id } && eval { $t->id } =~ /\A\d+\z/;
		my $url = eval { $t->url } // '';
		next if eval { $t->remote } || ($url ne '' && $url !~ /\Afile:/);
		if (durationOk($t, $cfg)) { push @ok, $t } else { push @long, $t }
	}
	# Too few that pass the duration filter: fall back to those that don't.
	push @ok, splice(@long, 0, $n - @ok) if @ok < $n && @long;
	return [ reverse @ok ] if $strict || @ok <= $n;
	my @pick = @ok;
	for (my $i = $#pick; $i > 0; $i--) { my $j = int rand($i + 1); @pick[$i, $j] = @pick[$j, $i] }
	return [ @pick[0 .. $n - 1] ];
}

1;
