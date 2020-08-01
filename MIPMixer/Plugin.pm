package Plugins::MIPMixer::Plugin;

#
# Forked from MusicMagic Plugin from Logitech Media Server...
#

# Logitech Media Server Copyright 2001-2020 Logitech
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use Scalar::Util qw(blessed);
use LWP::UserAgent;
use URI::Escape qw(uri_escape_utf8);
use JSON::XS::VersionOneAndTwo;
use File::Basename;
use File::Slurp;

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Prefs;

use Data::Dumper;

if ( main::WEBUI ) {
    require Plugins::MIPMixer::Settings;
}

use Plugins::MIPMixer::Common;
use Plugins::MIPMixer::Settings;

my $initialized = 0;
my $MIPPort;
my @genreSets = ();
my $xmasGenres = {};
my $allConfiguredGenres = {};
my $NUM_TRACKS = 150; # Request a *LOT* of tracks so that we can filter on genre, artist, and album
my $NUM_TRACKS_REPEAT_ARTIST = 25;
my $NUM_TRACKS_TO_USE = 5;
my $NUM_TRACKS_TO_SHUFFLE = 12;
my $NUM_SEED_TRACKS = 5;
my $NUM_PREV_TRACKS_FILTER_ARTIST = 15;
my $NUM_PREV_TRACKS_FILTER_ALBUM = 25; # Must >= NUM_PREV_TRACKS_FILTER_ARTIST

my @XMAS_GENRES = ( 'Christmas', 'XMas', 'xmas', 'Xmas' );

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.mipmixer',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.mipmixer');

sub shutdownPlugin {
    $initialized = 0;
}

sub initPlugin {
    my $class = shift;

    return 1 if $initialized;

    $prefs->init({
        mix_type        => 0,
        mix_style       => 20,
        mix_variety     => 0,
        filter_genres   => 1,
        filter_xmas     => 1,
        exclude_artists => '',
        exclude_albums  => '',
        min_duration    => 0,
        max_duration    => 0,
        port            => 10002
    });

    if ( main::WEBUI ) {
        Plugins::MIPMixer::Settings->new;
    }

    _initGenres();
    $initialized = 1;
    return $initialized;
}

sub postinitPlugin {
    my $class = shift;

    # if user has the Don't Stop The Music plugin enabled, register ourselves
    if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
        require Slim::Plugin::DontStopTheMusic::Plugin;
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('MIPMIXER_MIX', sub {
            my ($client, $cb) = @_;

            my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, $NUM_SEED_TRACKS);
            my $previousTracks = [];
            my $tracks = [];
            my $tracksFilteredBySeeds = [];    # MIP tracks that matched seeds
            my $tracksFilteredByCurrent = []; # MIP tracks that matched tracks already picked
            my $tracksFilteredByPrev = [];    # MIP tracks that matched artists/albums already in queue

            # don't seed from radio stations - only do if we're playing from some track based source
            # Get list of valid seeds...
            if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
                my @seedGenres = ();
                my @seedIds = ();
                my @seedsToUse = ();
                foreach my $seedTrack (@$seedTracks) {
                    my ($trackObj) = Slim::Schema->find('Track', $seedTrack->{id});
                    if ($trackObj) {
                        my @genres = _getSeedGenres($trackObj->id);
                        main::DEBUGLOG && $log->debug("Seed " . $trackObj->path . " id:" . $seedTrack->{id} . " genres:" . Data::Dump::dump(@genres));
                        if (scalar @genres > 1) {
                            push @seedGenres, @genres;
                        }
                        push @seedsToUse, $trackObj;
                        push @seedIds, $seedTrack->{id};
                    }
                }

                $previousTracks = _getPreviousTracks($client, \@seedIds);

                if (scalar @seedsToUse > 0) {
                    my $mix = _getMix(\@seedsToUse, \@seedIds);
                    main::idleStreams();

                    if ($mix && scalar @$mix) {
                        # Ensure no duplicates in mix
                        $mix = Slim::Plugin::DontStopTheMusic::Plugin->deDupe($mix);
                        main::idleStreams();
                        # Ensure no tracks already in queue...
                        $mix = Slim::Plugin::DontStopTheMusic::Plugin->deDupePlaylist($client, $mix);
                        main::idleStreams();

                        my %genrehash = undef;
                        my %xmashash = undef;
                        if (scalar @seedGenres > 1) {
                            %genrehash = map { $_ => 1 } @seedGenres;
                        }

                        my $minDuration = $prefs->get('min_duration') || 0;
                        my $maxDuration = $prefs->get('max_duration') || 0;
                        my $filterXmas = $prefs->get('filter_xmas');
                        if ($filterXmas) {
                            my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
                            if ($mon != 11) { # Months are 0..11
                                $filterXmas = 0;
                            }
                        }

                        my $excludeArtists = [];
                        my $excludeAlbums = [];
                        my $exclude = $prefs->get('exclude_artists');
                        if ($exclude) {
                            my @entries = split /,/, $exclude;
                            foreach my $entry (@entries) {
                                $entry =~ s/^\s+|\s+$//g;
                                push @$excludeArtists, lc $entry;
                            }
                        }
                        $exclude = $prefs->get('exclude_albums');
                        if ($exclude) {
                            my @entries = split /,/, $exclude;
                            foreach my $entry (@entries) {
                                $entry =~ s/^\s+|\s+$//g;
                                push @$excludeArtists, lc $entry;
                            }
                        }

                        foreach my $candidate (@$mix) {
                            if (!_durationInRange($minDuration, $maxDuration, $candidate)) {
                                next;
                            }
                            if (_excludeByGenre(%genrehash ? \%genrehash : undef, $filterXmas, $candidate)) {
                                next;
                            }
                            if (_excludeArtist(\@$excludeArtists, $candidate)) {
                                next;
                            }
                            if (_excludeAlbum(\@$excludeAlbums, $candidate)) {
                                next;
                            }
                            if (_sameArtistOrAlbum(\@seedsToUse, $candidate, 0, 0)) {
                                main::DEBUGLOG && $log->debug($candidate->url . " matched seed track metadata");
                                push @$tracksFilteredBySeeds, $candidate;
                                next;
                            }
                            if (_sameArtistOrAlbum(\@$tracks, $candidate, 0, 0)) {
                                main::DEBUGLOG && $log->debug($candidate->url . " matched current track metadata");
                                push @$tracksFilteredByCurrent, $candidate;
                                next;
                            }
                            if (blessed $previousTracks) {
                                if (_sameArtistOrAlbum(\@$previousTracks, $candidate, $NUM_PREV_TRACKS_FILTER_ARTIST, 0)) {
                                    main::DEBUGLOG && $log->debug($candidate->url . " matched previous artist metadata");
                                    push @$tracksFilteredByPrev, $candidate;
                                    next;
                                }
                                if (_sameArtistOrAlbum(\@$previousTracks, $candidate, $NUM_PREV_TRACKS_FILTER_ALBUM, 1)) {
                                    main::DEBUGLOG && $log->debug($candidate->url . " matched previous album metadata");
                                    push @$tracksFilteredByPrev, $candidate;
                                    next;
                                }
                            }

                            push @$tracks, $candidate;
                            my $numTracks = scalar(@$tracks);
                            main::DEBUGLOG && $log->debug($candidate->url . " passed all filters, count:" . $numTracks);
                            if ($numTracks >= $NUM_TRACKS_TO_SHUFFLE) {
                                main::DEBUGLOG && $log->debug("Have sufficient tracks");
                                last;
                            }
                        }
                    }
                }
            }

            # Too few tracks? Add some from the filtered lists
            my $numTracks = scalar @$tracks;
            if ( $numTracks < $NUM_TRACKS_TO_USE && scalar @$tracksFilteredByPrev > 0) {
                main::DEBUGLOG && $log->debug("Add some tracks from tracksFilteredByPrev " . $numTracks . "/" . scalar @$tracksFilteredByPrev);
                $tracks = [ $tracks, splice(@$tracksFilteredByPrev, 0, $NUM_TRACKS_TO_USE - scalar(@$tracks)) ];
                $numTracks = scalar @$tracks;
            }
            if ( $numTracks < $NUM_TRACKS_TO_USE && scalar @$tracksFilteredByCurrent > 0) {
                main::DEBUGLOG && $log->debug("Add some tracks from tracksFilteredByCurrent " . $numTracks . "/" . scalar @$tracksFilteredByCurrent);
                $tracks = [ $tracks, splice(@$tracksFilteredByCurrent, 0, $NUM_TRACKS_TO_USE - $numTracks) ];
                $numTracks = scalar @$tracks;
            }
            if ( $numTracks < $NUM_TRACKS_TO_USE && scalar @$tracksFilteredBySeeds > 0) {
                main::DEBUGLOG && $log->debug("Add some tracks from tracksFilteredByPrev " . $numTracks . "/" . scalar @$tracksFilteredBySeeds);
                $tracks = [ $tracks, splice(@$tracksFilteredBySeeds, 0, $NUM_TRACKS_TO_USE - $numTracks) ];
                $numTracks = scalar @$tracks;
            }

            # Shuffle tracks...
            Slim::Player::Playlist::fischer_yates_shuffle($tracks);

            # If we have more than num tracks, then use 1st num...
            if ( $numTracks > $NUM_TRACKS_TO_USE ) {
                main::DEBUGLOG && $log->debug("Trimming tracks (" . $numTracks . ")");
                $tracks = [ splice(@$tracks, 0, $NUM_TRACKS_TO_USE) ];
                $numTracks = scalar @$tracks;
            }

            main::DEBUGLOG && $log->debug("Return " . $numTracks . " tracks");
            $cb->($client, $tracks);
        });
    }
}

sub prefName {
    my $class = shift;
    return lc($class->title);
}

sub title {
    my $class = shift;
    return 'MIPMIXER';
}

sub _getPreviousTracks() {
    my $client = shift;
    my $seedsRef = shift;
    my %seedsHash = map { $_ => 1 } @$seedsRef;
    return unless $client;

    $client = $client->master;
    my ($trackId, $artist, $title, $duration, $mbid, $artist_mbid, $tracks);

    foreach (reverse(@{ Slim::Player::Playlist::playList($client) })) {
        ($artist, $title, $duration, $trackId, $mbid, $artist_mbid) = Slim::Plugin::DontStopTheMusic::Plugin->getMixablePropertiesFromTrack($client, $_);
        next unless defined $artist && defined $title && !exists($seedsHash{$trackId});
        my ($trackObj) = Slim::Schema->find('Track', $trackId);
        if ($trackObj) {
            push @$tracks, $trackObj;
            if (scalar @$tracks >= $NUM_PREV_TRACKS_FILTER_ALBUM) {
                return reverse($tracks);
            }
        }
    }
    return reverse($tracks);
}

sub _durationInRange() {
    my $minDuration = shift;
    my $maxDuration = shift;
    my $candidate = shift;
    my $duration = $candidate->duration();

    if ($minDuration > 0 && $duration < $minDuration) {
        main::DEBUGLOG && $log->debug($candidate->url . " duration (" . $duration . ") too short");
        return 0;
    }
    if ($maxDuration > 0 && $duration > $maxDuration) {
        main::DEBUGLOG && $log->debug($candidate->url . " duration (" . $duration . ") too long");
        return 0;
    }
    return 1;
}

sub _excludeByGenre() {
    my $genrehashRef = shift;
    my $filterXmas = shift;
    my $candidate = shift;
    my @cgenres = _getCandidateGenres($candidate->get_column('id'));
    my $count = scalar @cgenres;

    if ($filterXmas) {
        my %hash = %$xmasGenres;
        for (my $i = 0; $i < $count; $i++) {
            if (exists($hash{$cgenres[$i]})) {
                main::DEBUGLOG && $log->debug($candidate->url . " matched christmas " . $cgenres[$i]);
                return 1;
            }
        }
    }

    if ($genrehashRef) {
        my %hash = %$genrehashRef;
        for (my $i = 0; $i < $count; $i++) {
            if (exists($hash{$cgenres[$i]})) {
                main::DEBUGLOG && $log->debug($candidate->url . " matched on configured genre " . $cgenres[$i]);
                return 0;
            }
        }
        main::DEBUGLOG && $log->debug($candidate->url . " FAILED to match genre");
        return 1;
    } else {
        # No seed genres - i.e. genre of seed track was not in configured list, so check this tracks genre is not in list...
        my %hash = %$allConfiguredGenres;
        for (my $i = 0; $i < $count; $i++) {
            if (exists($hash{$cgenres[$i]})) {
                main::DEBUGLOG && $log->debug($candidate->url . " matched on configured genre " . $cgenres[$i] . " not in seeds");
                return 1;
            }
        }
    }

    return 0;
}

sub _excludeArtist() {
    my $a = shift;
    my $candidate = shift;
    my @artists = @$a;
    my $cArtist = lc $candidate->artistName();
    foreach my $artist (@artists) {
        if ($artist eq $cArtist) {
            main::DEBUGLOG && $log->debug($candidate->url . " exclude artist " . $artist);
            return 1;
        }
    }
    return 0;
}

sub _excludeAlbum() {
    my $a = shift;
    my $candidate = shift;
    my @albums = @$a;
    my $cAlbum = lc ($candidate->artistName() . " - " . $candidate->albumname());
    foreach my $album (@albums) {
        if ($album eq $cAlbum) {
            main::DEBUGLOG && $log->debug($candidate->url . " exclude album " . $album);
            return 1;
        }
    }
    return 0;
}

sub _sameArtistOrAlbum() {
    my $trks = shift;
    my $candidate = shift;
    my $countToCheck = shift;
    my $checkAlbum = shift;
    my @tracks = @$trks;
    my $cArtist = lc $candidate->artistName();
    my $cAlbum = lc $candidate->albumname();
    my $checked = 0;

    foreach my $track (@tracks) {
        my $artist = lc $track->artistName();
        if ($artist eq $cArtist) {
            if ($checkAlbum) {
                my $album = lc $track->albumname();
                if ($album eq $cAlbum) {
                    main::DEBUGLOG && $log->debug($candidate->url . " matched album " . $artist . " - " . $album);
                    return 1;
                }
            } else {
                main::DEBUGLOG && $log->debug($candidate->url . " matched artist " . $artist);
                return 1;
            }
        }

        $checked++;
        if ($countToCheck > 0 && $checked >= $countToCheck) {
            last;
        }
    }

    return 0;
}

sub _getMix {
    my $seedTracks = shift;
    my @tracks = @$seedTracks;
    my $seedIds = shift;
    my %idHash = map { $_ => 1 } @$seedIds;
    my @mix = ();
    my $req;
    my $res;

    my %args = (
            # Set the size of the list
            'size'       => $NUM_TRACKS,
            'sizetype'   => 'tracks',

            # Set the style slider (default 20)
            'style'      => $prefs->get('mix_style'),

            # Set the variety slider (default 0)
            'variety'    => $prefs->get('mix_variety'),

            # Don't restrict to genre of current track - we will (optionally) filter results
            'mixgenre'   => '0',

            # Set the number of songs before allowing dupes
            'rejectsize' => $NUM_TRACKS_REPEAT_ARTIST,
            'rejecttype' => 'tracks'
        );

    my $filter = $prefs->get('mix_filter');

    if ($filter) {
        $filter = Slim::Utils::Unicode::utf8decode_locale($filter);
        main::DEBUGLOG && $log->debug("Filter $filter in use.");
        $args{'filter'} = Plugins::MIPMixer::Common::escape($filter);
    }

    my $argString = join( '&', map { "$_=$args{$_}" } keys %args );

    # url encode the request, but not the argstring
    my $mixArgs = join('&', map {
        my $id = index($_->url, '#')>0 ? $_->url : $_->path;
        $id = main::ISWINDOWS ? $id : Slim::Utils::Unicode::utf8decode_locale($id);
        'song=' . Plugins::MIPMixer::Common::escape($id);
    } @tracks);

    main::DEBUGLOG && $log->debug("Request http://localhost:$MIPPort/api/mix?$mixArgs\&$argString");

    my $response = _syncHTTPRequest("/api/mix?$mixArgs\&$argString");

    if ($response->is_error) {
        if ($response->code == 500 && $filter) {
            ::idleStreams();

            # try again without the filter
            $log->warn("No mix returned with filter involved - we might want to try without it");
            $argString =~ s/filter=/xfilter=/;
            $response = _syncHTTPRequest("/api/mix?$mixArgs\&$argString");

            Plugins::MIPMixer::Common->grabFilters();
        }

        if ($response->is_error) {
            $log->warn("Warning: Couldn't get mix: $mixArgs\&$argString");
            main::DEBUGLOG && $log->debug($response->as_string);
            return \@mix;
        }
    }

    my @songs = split(/\n/, $response->content);
    my $count = scalar @songs;

    main::DEBUGLOG && $log->debug('Num tracks in response:' . $count);
    for (my $j = 0; $j < $count; $j++) {
        # Bug 4281 - need to convert from UTF-8 on Windows.
        if (main::ISWINDOWS && !-e $songs[$j] && -e Win32::GetANSIPathName($songs[$j])) {
            $songs[$j] = Win32::GetANSIPathName($songs[$j]);
        }

        if ( -e $songs[$j] || -e Slim::Utils::Unicode::utf8encode_locale($songs[$j]) || index($songs[$j], 'file:///')==0) {
            my $track = Slim::Schema->objectForUrl(Slim::Utils::Misc::fileURLFromPath($songs[$j]));

            if (blessed $track) {
                if (exists($idHash{$track->get_column('id')})) {
                     main::DEBUGLOG && $log->debug('Skip seed track ' . $songs[$j]);
                } else {
                    #main::DEBUGLOG && $log->debug('MIP: ' . $track->url);
                    push @mix, $track;
                }
            } else {
                main::DEBUGLOG && $log->debug('Failed to get track object for ' . $songs[$j]);
            }
        } else {
            $log->error('MIP attempted to mix in a song at ' . $songs[$j] . ' that can\'t be found at that location');
        }
    }

    return \@mix;
}

sub _syncHTTPRequest {
    my $url = shift;
    $MIPPort = $prefs->get('port') unless $MIPPort;
    my $http = LWP::UserAgent->new;
    $http->timeout($prefs->get('timeout') || 5);
    return $http->get("http://localhost:$MIPPort$url");
}

sub _initGenres {
    my $filePath = Slim::Utils::Prefs::dir() . "/genres.json";
    if (! -e $filePath) {
        $filePath = dirname(__FILE__) . "/genres.json";
    }
    
    my $json = read_file($filePath);
    my $data = decode_json($json);
    my $dbh = Slim::Schema->dbh;
    my $sql = $dbh->prepare_cached( qq{SELECT genres.id FROM genres WHERE name = ? LIMIT 1} );
    my $count = 0;

    @genreSets = ();
    if ($data) {
        foreach my $s (@$data) {
            my $set = {};
            foreach my $genre (@$s) {
                $sql->execute($genre);
                if ( my $result = $sql->fetchall_arrayref({}) ) {
                    my $val = $result->[0]->{'id'} if ref $result && scalar @$result;
                    if ($val) {
                        $set->{$val}=1;
                        $count++;
                        $allConfiguredGenres->{$val}=1;
                    }
                }
            }

            if ($count>1) {
                push(@genreSets, $set);
            }
        }
    }

    # Chistmas...
    foreach my $genre (@XMAS_GENRES) {
        $sql->execute($genre);
        if ( my $result = $sql->fetchall_arrayref({}) ) {
            my $val = $result->[0]->{'id'} if ref $result && scalar @$result;
            if ($val) {
                $xmasGenres->{$val}=1;
                $count++;
            }
        }
    }
}

sub _getSeedGenres {
    my $track = shift;
    my @genres = ();
    if ($prefs->get('filter_genres')) {
        my @lmsgenres = ();
        # Get genres stored in LMS for this track
        my $dbh = Slim::Schema->dbh;
        my $sql = $dbh->prepare_cached( qq{SELECT genre FROM genre_track WHERE track = ?} );
        $sql->execute($track);
        if ( my $result = $sql->fetchall_arrayref({}) ) {
            if (ref $result && scalar @$result) {
                foreach my $r (@$result) {
                    push (@lmsgenres, $r->{'genre'})
                }
            }
        }

        foreach my $lmsgenre (@lmsgenres) {
            for my $href (@genreSets) {
                my %hash = %$href;
                if (exists($hash{$lmsgenre})) {
                    push (@genres, keys %hash); 
                }
            }
        }
    }

    return @genres;
}

sub _getCandidateGenres {
    my $id = shift;
    my @genres = ();
    my $dbh = Slim::Schema->dbh;
    my $sql = $dbh->prepare_cached( qq{SELECT genre FROM genre_track WHERE track = ?} );
    $sql->execute($id);
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        if (ref $result && scalar @$result) {
            foreach my $r (@$result) {
                push (@genres, $r->{'genre'})
            }
        }
    }
    main::DEBUGLOG && $log->debug("Candidate " . $id . " genres: " . Data::Dump::dump(@genres));
    return @genres;
}

1;

__END__
