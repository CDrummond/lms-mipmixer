package Plugins::MIPMixer::Plugin;

#
# LMS-MIPMixer
#
# Copyright (c) 2020-2021 Craig Drummond <craig.p.drummond@gmail.com>
#
# GPLv2 license.
#

# - Initially based upon MusicMagic Plugin of LMS 8.0 -

# Logitech Media Server Copyright 2001-2020 Logitech
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use Scalar::Util qw(blessed);
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
my @genreSets = ();
my $xmasGenres = {};
my $allConfiguredGenres = {};
my $NUM_TRACKS = 50; # Request a *LOT* of tracks so that we can filter on genre, artist, and album
my $NUM_TRACKS_REPEAT_ARTIST = 25;
my $DESIRED_NUM_TRACKS_TO_USE = 10;
my $MIN_NUM_TRACKS_TO_USE = 5;
my $NUM_TRACKS_TO_SHUFFLE = 25;
my $NUM_SEED_TRACKS = 5;
my $DEF_NUM_PREV_TRACKS_FILTER_ARTIST = 15;
my $DEF_NUM_PREV_TRACKS_FILTER_ALBUM = 25; # Must >= NUM_PREV_TRACKS_FILTER_ARTIST
my $DEF_NUM_PREV_TRACKS_NO_DUPE = 100;
my $MAX_NUM_PREV_TRACKS = 200;

my @XMAS_GENRES = ( 'Christmas', 'XMas', 'xmas', 'Xmas' );

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.mipmixer',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.mipmixer');
my $serverprefs = preferences('server');

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
        port            => 10002,
        mip_path        => '',
        convert_ext     => 0,
        no_repeat_artist => $DEF_NUM_PREV_TRACKS_FILTER_ARTIST,
        no_repeat_album  => $DEF_NUM_PREV_TRACKS_FILTER_ALBUM,
        no_repeat_track  => $DEF_NUM_PREV_TRACKS_NO_DUPE
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

    # If user has the Don't Stop The Music plugin enabled, register ourselves
    if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
        require Slim::Plugin::DontStopTheMusic::Plugin;
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('MIPMIXER_MIX', sub {
            my ($client, $cb) = @_;

            my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, $NUM_SEED_TRACKS);

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

                if (scalar @seedsToUse > 0) {
                    my %seedIdHash = map { $_ => 1 } @seedIds;
                    my $previousTracks = _getPreviousTracks($client, \%seedIdHash);
                    my $url = _getMixUrl(\@seedsToUse);

                    Slim::Networking::SimpleAsyncHTTP->new(
                        sub {
                            my $response = shift;
                            main::DEBUGLOG && $log->debug("Recevied MIP response");
                            my $mix = _handleMipResponse($response->content);
                            my @tracks = _getTracksFromMix(\@$mix, \@$previousTracks, \@seedsToUse, \%seedIdHash, \@seedGenres);
                            if (scalar @tracks > 0) {
                                $cb->($client, @tracks);
                            } else {
                                _mixFailed($client, $cb);
                            }
                        },
                        sub {
                            my $response = shift;
                            if ($response->code == 500 && $prefs->get('mix_filter')) {
                                $log->warn("No mix returned with filter involved - we might want to try without it");
                                $url =~ s/filter=/xfilter=/;
                                Slim::Networking::SimpleAsyncHTTP->new(
                                    sub {
                                        my $response = shift;
                                        main::DEBUGLOG && $log->debug("Recevied MIP response");
                                        my $mix = _handleMipResponse($response->content);
                                        my @tracks = _getTracksFromMix(\@$mix, \@$previousTracks, \@seedsToUse, \%seedIdHash, \@seedGenres);
                                        if (scalar @tracks > 0) {
                                            $cb->($client, @tracks);
                                        } else {
                                            _mixFailed($client, $cb);
                                        }
                                    },
                                    sub {
                                        main::DEBUGLOG && $log->debug("Failed to fetch mix");
                                        _mixFailed($client, $cb);
                                    }
                                )->get($url);
                            } else {
                                main::DEBUGLOG && $log->debug("Failed to fetch mix");
                                _mixFailed($client, $cb);
                            }
                        }
                    )->get($url);
                } else {
                    _mixFailed($client, $cb);
                }
            } else {
                _mixFailed($client, $cb);
            }
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

sub _mixFailed {
    my ($client, $cb) = @_;
    if (exists $INC{'Plugins/LastMix/DontStopTheMusic.pm'}) {
        main::DEBUGLOG && $log->debug("Call through to LastMix");
        Plugins::LastMix::DontStopTheMusic::please($client, $cb);
    } else {
        main::DEBUGLOG && $log->debug("Return empty list");
        $cb->($client, []);
    }
}

sub _getPreviousTracks {
    my $client = shift;
    my $seedsHashRef = shift;
    my %seedsHash = %$seedsHashRef;
    my @tracks = ();

    return \@tracks unless $client;

    $client = $client->master;
    my ($trackId, $artist, $title, $duration, $mbid, $artist_mbid);

    my $maxNumPrevTracks = $prefs->get('no_repeat_track');
    if ($maxNumPrevTracks<0 || $maxNumPrevTracks>$MAX_NUM_PREV_TRACKS) {
        $maxNumPrevTracks = $DEF_NUM_PREV_TRACKS_NO_DUPE;
    }

    if ($maxNumPrevTracks > 0 ) {
        foreach (reverse(@{ Slim::Player::Playlist::playList($client) })) {
            ($artist, $title, $duration, $trackId, $mbid, $artist_mbid) = Slim::Plugin::DontStopTheMusic::Plugin->getMixablePropertiesFromTrack($client, $_);
            next unless defined $artist && defined $title && !exists($seedsHash{$trackId});
            my ($trackObj) = Slim::Schema->find('Track', $trackId);
            if ($trackObj) {
                push @tracks, $trackObj;
            }
            if (scalar(@tracks) >= $maxNumPrevTracks) {
                last;
            }
        }
    }
    return \@tracks
}

sub _durationInRange {
    my $minDuration = shift;
    my $maxDuration = shift;
    my $candidate = shift;
    my $duration = $candidate->secs;

    if ($minDuration > 0 && $duration < $minDuration) {
        main::DEBUGLOG && $log->debug("EXCLUDE " . $candidate->url . " - duration (" . $duration . ") too short");
        return 0;
    }
    if ($maxDuration > 0 && $duration > $maxDuration) {
        main::DEBUGLOG && $log->debug("EXCLUDE " .$candidate->url . " - duration (" . $duration . ") too long");
        return 0;
    }
    return 1;
}

sub _excludeByGenre {
    my $genrehashRef = shift;
    my $filterGenres = shift;
    my $filterXmas = shift;
    my $candidate = shift;

    if (!$genrehashRef && !%$allConfiguredGenres && !$filterXmas) {
        return 0;
    }

    my @cgenres = _getCandidateGenres($candidate->get_column('id'));
    my $count = scalar @cgenres;

    if ($filterXmas) {
        my %hash = %$xmasGenres;
        for (my $i = 0; $i < $count; $i++) {
            if (exists($hash{$cgenres[$i]})) {
                main::DEBUGLOG && $log->debug("EXCLUDE " .$candidate->url . " - matched christmas " . $cgenres[$i]);
                return 1;
            }
        }
    }

    if ($filterGenres) {
        if ($genrehashRef) {
            my %hash = %$genrehashRef;
            for (my $i = 0; $i < $count; $i++) {
                if (exists($hash{$cgenres[$i]})) {
                    main::DEBUGLOG && $log->debug($candidate->url . " matched on configured genre " . $cgenres[$i]);
                    return 0;
                }
            }
            main::DEBUGLOG && $log->debug("EXCLUDE " . $candidate->url . " - failed to match genre");
            return 1;
        } elsif (%$allConfiguredGenres) {
            # No seed genres - i.e. genre of seed track was not in configured list, so check this tracks genre is not in list...
            my %hash = %$allConfiguredGenres;
            for (my $i = 0; $i < $count; $i++) {
                if (exists($hash{$cgenres[$i]})) {
                    main::DEBUGLOG && $log->debug("EXCLUDE " . $candidate->url . " - matched on configured genre " . $cgenres[$i] . " not in seeds");
                    return 2;
                }
            }
        }
    }

    return 0;
}

sub _excludeArtist {
    my $artistsHashRef = shift;
    my $candidate = shift;
    my %artistsHash = %$artistsHashRef;
    my $cArtist = lc $candidate->artistName();
    if (exists($artistsHash{$cArtist})) {
        main::DEBUGLOG && $log->debug("EXCLUDE " . $candidate->url . " - matched artist " . $cArtist);
        return 1;
    }
    return 0;
}

sub _excludeAlbum {
    my $albumsHashRef = shift;
    my $candidate = shift;
    my %albumssHash = %$albumsHashRef;
    my $albumArtist = $candidate->contributorsOfType('ALBUMARTIST')->single || $candidate->contributorsOfType('ARTIST')->single || $candidate->contributorsOfType('TRACKARTIST')->single;
    my $albumArtistName = $albumArtist ? $albumArtist->name() : $candidate->artistName();
    my $cAlbum = lc ($albumArtistName . " - " . $candidate->albumname());
    if (exists($albumssHash{$cAlbum})) {
        main::DEBUGLOG && $log->debug("EXCLUDE " . $candidate->url . " - matched album " . $cAlbum);
        return 1;
    }
    return 0;
}

sub _idInList {
    my $cat = shift;
    my $idHashRef = shift;
    my $candidate = shift;
    my %hash = %$idHashRef;
    if (exists($hash{$candidate->id})) {
        main::DEBUGLOG && $log->debug("EXCLUDE " . $candidate->url . " - matched ID " . $candidate->id . "(" . $cat . ")");
        return 1;
    }
    return 0;
}

sub _normalize {
    my $str = shift;
    $str = lc $str;
    $str =~ s/\(live\)//o;
    $str =~ s/\[live\]//o;
    $str = lc Slim::Utils::Text::ignorePunct($str);
    $str =~ s/\sfeaturing\s/ ft /o;
    $str =~ s/\sfeat\s/ ft /o;
    return $str;
}

sub _sameArtistAndTitle {
    my $trks = shift;
    my $candidate = shift;
    my @tracks = @$trks;
    my $cArtist = _normalize($candidate->artistName());
    my $cTitle = _normalize($candidate->title);

    foreach my $track (@tracks) {
        if ( (_normalize($track->artistName()) eq $cArtist) && (_normalize($track->title) eq $cTitle) ) {
            main::DEBUGLOG && $log->debug("FILTER " . $candidate->url . " - matched artist & title " . $track->artistName() . " - " . $track->title);
            return 1;
        }
    }
    return 0;
}

sub _sameArtistOrAlbum {
    my $cat = shift;
    my $trks = shift;
    my $candidate = shift;
    my $isPrevTracks = shift;
    my $numTracksFilterArtist = shift;
    my $numTracksFilterAlbum = shift;
    my @tracks = @$trks;
    my $cArtist = _normalize($candidate->artistName());
    my $cAlbumId = $candidate->albumid();
    my $cAlbumArtist = undef;
    my $cIsVarious = 0;
    my $checked = 0;

    if ($numTracksFilterArtist>0 || $numTracksFilterAlbum>0) {
        foreach my $track (@tracks) {
            if (_normalize($track->artistName()) eq $cArtist) {
                if ($isPrevTracks && $checked > $numTracksFilterArtist) {
                    if ($track->albumid() == $cAlbumId) {
                        main::DEBUGLOG && $log->debug("FILTER " . $candidate->url . " - matched album " . $track->artistName() . " - " . $track->albumname() . " (" . $cat . ")");
                        return 1;
                    }
                } else {
                    main::DEBUGLOG && $log->debug("FILTER " . $candidate->url . " - matched artist " . $track->artistName() . " (" . $cat . ")");
                    return 1;
                }
            } elsif ($isPrevTracks) {
                if (!$cAlbumArtist) {
                    my $aa = $candidate->contributorsOfType('ALBUMARTIST')->single || $candidate->contributorsOfType('ARTIST')->single || $candidate->contributorsOfType('TRACKARTIST')->single;
                    $cAlbumArtist = lc ($aa ? $aa->name() : $track->artistName());
                    if ($cAlbumArtist eq 'various' || $cAlbumArtist eq 'various artists') {
                        $cIsVarious = 1;
                    }
                }
                if ($cIsVarious == 0) {
                    if ($track->albumid() == $cAlbumId) {
                        main::DEBUGLOG && $log->debug("FILTER " . $candidate->url . " - matched album/artist " . $cAlbumArtist . " - " . $track->albumname() . " (" . $cat . ")");
                        return 1;
                    }
                }
            }

            $checked++;
            if ($isPrevTracks==1 && $checked >= $numTracksFilterAlbum) {
                return 0;
            }
        }
    }

    return 0;
}

sub _convertToMip {
    my $path = shift;
    my $mipPath = shift;
    my $lmsPath = shift;
    my $convertExt = shift;
    my $fixed = $path;

    if ($convertExt) {
        my @parts = split(/#/, $path);
        if (2==scalar(@parts)) {
            $fixed = $parts[0] . ".CUE_TRACK." . $parts[1] . ".mp3";
        }
        if (!main::ISWINDOWS && !main::ISMAC) {
            #if (! ('.mp3' eq substr $fixed, -length('.mp3'))) {
            #    $fixed = $fixed . ".mp3";
            #}
            if ('.m4a' eq substr $fixed, -length('.m4a')) {
                $fixed = $fixed . ".mp3";
            }
        }
    }
    if ($mipPath) {
        $fixed =~ s/$lmsPath/$mipPath/g;
    }

    if ($convertExt || $mipPath) {
        main::DEBUGLOG && $log->debug("TO MIP: " . $path . " -> " . $fixed);
    }
    return $fixed;
}

sub _convertFromMip {
    my $path = shift;
    my $mipPath = shift;
    my $lmsPath = shift;
    my $convertExt = shift;
    my $fixed = $path;

    if ($convertExt) {
        my @parts = split(/\.CUE_TRACK\./, $path);
        if (2==scalar(@parts)) {
            my $end = substr $parts[1], 0, -4; # Remove .mp3 ext
            $fixed = $parts[0] . "#" . $end;
        }
        if (!main::ISWINDOWS && !main::ISMAC) {
            if ('.m4a.mp3' eq substr $fixed, -length('.m4a.mp3')) {
                $fixed = substr $fixed, 0, -4;
            #} elsif ('.ogg.mp3' eq substr $fixed, -length('.ogg.mp3')) {
            #    $fixed = substr $fixed, 0, -4;
            #} elsif ('.flac.mp3' eq substr $fixed, -length('.flac.mp3')) {
            #    $fixed = substr $fixed, 0, -4;
            }
        }
    }
    if ($mipPath) {
        $fixed =~ s/$mipPath/$lmsPath/g;
    }

    if ($convertExt || $mipPath) {
        main::DEBUGLOG && $log->debug("FROM MIP: " . $path . " -> " . $fixed);
    }
    return $fixed;
}

sub _getMixUrl {
    my $seedTracks = shift;
    my @tracks = @$seedTracks;
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
    my $mipPath = $prefs->get('mip_path');
    my $mediaDirs = $serverprefs->get('mediadirs');
    my $lmsPath = @$mediaDirs[0];
    my $convertExt = $prefs->get('convert_ext');
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
        'song=' . Plugins::MIPMixer::Common::escape(_convertToMip($id, $mipPath, $lmsPath, $convertExt));
    } @tracks);

    my $url = "http://localhost:" . $prefs->get('port') . "/api/mix?$mixArgs\&$argString";
    main::DEBUGLOG && $log->debug("Request $url");
    return $url;
}

sub _handleMipResponse {
    my $response = shift;

    my @songs = split(/\n/, $response);
    my $count = scalar @songs;
    my @mix = ();
    my $mipPath = $prefs->get('mip_path');
    my $mediaDirs = $serverprefs->get('mediadirs');
    my $lmsPath = @$mediaDirs[0];
    my $convertExt = $prefs->get('convert_ext') || 1;

    main::DEBUGLOG && $log->debug('Num tracks in response:' . $count);
    for (my $j = 0; $j < $count; $j++) {
        my $id = _convertFromMip($songs[$j], $mipPath, $lmsPath, $convertExt);
        # Bug 4281 - need to convert from UTF-8 on Windows.
        if (main::ISWINDOWS && !-e $id && -e Win32::GetANSIPathName($id)) {
            $id = Win32::GetANSIPathName($id);
        }

        if ( -e $id || -e Slim::Utils::Unicode::utf8encode_locale($id) || index($id, 'file:///')==0) {
            my $track = Slim::Schema->objectForUrl(Slim::Utils::Misc::fileURLFromPath($id));

            if (blessed $track) {
                push @mix, $track;
            } else {
                main::DEBUGLOG && $log->debug('Failed to get track object for ' . $id);
            }
        } else {
            $log->error('MIP attempted to mix in a song at ' . $id . ' that can\'t be found at that location');
        }
    }

    return \@mix;
}

sub _getTracksFromMix {
    my $mix = shift;
    my $previousTracks = shift;
    my $seedsToUseRef = shift;
    my $seedIdHashRef = shift;
    my $seedGenresRef = shift;
    my @seedsToUse = @$seedsToUseRef;
    my %seedIdHash = %$seedIdHashRef;
    my @seedGenres = @$seedGenresRef;

    my @tracks = ();
    my @tracksFilteredBySeeds = ();               # MIP tracks that matched seeds
    my @tracksFilteredByCurrent = ();             # MIP tracks that matched tracks already picked
    my @tracksFilteredByPrev = ();                # MIP tracks that matched artists/albums already in queue
    my @tracksFilteredBySeedNotInGenreGroup = (); # MIP tracks that were in a genre group, but seed tracks were not
    if ($mix && scalar @$mix) {
        my %prevTrackIdHash = undef;
        my $numPrev = $previousTracks ? scalar(@$previousTracks) : 0;
        if ($numPrev > 0) {
            my $idList = [];
            foreach my $track (@$previousTracks) {
                push @$idList, $track->id;
            }
            %prevTrackIdHash = map { $_ => 1 } @$idList;
        }
        main::DEBUGLOG && $log->debug("Num tracks:" . scalar(@$mix) . ", seeds:" . scalar(@seedsToUse) . ", prev:" . $numPrev);

        my %genrehash = undef;
        my %xmashash = undef;
        my $filterGenres = $prefs->get('filter_genres');

        if ($filterGenres && scalar @seedGenres > 0) {
            %genrehash = map { $_ => 1 } @seedGenres;
        }

        my $minDuration = $prefs->get('min_duration') || 0;
        my $maxDuration = $prefs->get('max_duration') || 0;
        my $filterXmas = $prefs->get('filter_xmas');
        if ($filterXmas) {
            my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
            if ($mon == 11) { # Months are 0..11 Xmas filter is disabled for December
                $filterXmas = 0;
            }
        }

        my $excludeArtists = [];
        my $excludeAlbums = [];
        my $exclude = $prefs->get('exclude_artists');
        if ($exclude) {
            my @entries = split /\n/, $exclude;
            foreach my $entry (@entries) {
                $entry =~ s/^\s+|\s+$//g;
                if ($entry ne "") {
                    push @$excludeArtists, lc $entry;
                }
            }
        }
        $exclude = $prefs->get('exclude_albums');
        if ($exclude) {
            my @entries = split /\n/, $exclude;
            foreach my $entry (@entries) {
                $entry =~ s/^\s+|\s+$//g;
                if ($entry ne "") {
                    push @$excludeAlbums, lc $entry;
                }
            }
        }
        my %excludeArtistsHash = map { $_ => 1 } @$excludeArtists;
        my %excludeAlbumsHash = map { $_ => 1 } @$excludeAlbums;

        my $numTracksFilterArtist = $prefs->get('no_repeat_artist');
        if ($numTracksFilterArtist<0 || $numTracksFilterArtist>$MAX_NUM_PREV_TRACKS) {
            $numTracksFilterArtist = $DEF_NUM_PREV_TRACKS_FILTER_ARTIST;
        }
        my $numTracksFilterAlbum = $prefs->get('no_repeat_album');
        if ($numTracksFilterAlbum<0 || $numTracksFilterAlbum>$MAX_NUM_PREV_TRACKS) {
            $numTracksFilterAlbum = $DEF_NUM_PREV_TRACKS_FILTER_ALBUM;
        }

        foreach my $candidate (@$mix) {
            if (_idInList('seed', \%seedIdHash, $candidate)) {
                next;
            }
            if ($numPrev > 0 && _idInList('prev', \%prevTrackIdHash, $candidate)) {
                next;
            }
            if (!_durationInRange($minDuration, $maxDuration, $candidate)) {
                next;
            }
            if ($filterGenres || $filterXmas) {
                main::idleStreams();
                my $genreExclude = _excludeByGenre(scalar @seedGenres > 0 ? \%genrehash : undef, $filterGenres, $filterXmas, $candidate);
                if ($genreExclude > 0) {
                    if ($genreExclude > 1) {
                        push @tracksFilteredBySeedNotInGenreGroup, $candidate;
                    }
                    next;
                }
            }
            if (_excludeArtist(\%excludeArtistsHash, $candidate)) {
                next;
            }
            if (_excludeAlbum(\%excludeAlbumsHash, $candidate)) {
                next;
            }
            if (_sameArtistAndTitle(\@tracks, $candidate) || ($numPrev > 0 && _sameArtistAndTitle(\@$previousTracks, $candidate))) {
                next;
            }
            if (_sameArtistOrAlbum('seed', \@seedsToUse, $candidate, 0, $numTracksFilterArtist, $numTracksFilterAlbum)) {
                push @tracksFilteredBySeeds, $candidate;
                next;
            }
            if (_sameArtistOrAlbum('current', \@tracks, $candidate, 0, $numTracksFilterArtist, $numTracksFilterAlbum)) {
                push @tracksFilteredByCurrent, $candidate;
                next;
            }
            if ($numPrev > 0 && _sameArtistOrAlbum('prev', \@$previousTracks, $candidate, 1, $numTracksFilterArtist, $numTracksFilterAlbum)) {
                push @tracksFilteredByPrev, $candidate;
                next;
            }

            push @tracks, $candidate;
            my $numTracks = scalar(@tracks);
            main::DEBUGLOG && $log->debug($candidate->url . " passed all filters, count:" . $numTracks);
            if ($numTracks >= $NUM_TRACKS_TO_SHUFFLE) {
                main::DEBUGLOG && $log->debug("Have sufficient tracks");
                last;
            }
        }
    }

    # Too few tracks? Add some from the filtered lists
    my $numTracks = scalar @tracks;
    if ( $numTracks < $MIN_NUM_TRACKS_TO_USE && scalar @tracksFilteredByPrev > 0) {
        main::DEBUGLOG && $log->debug("Add some tracks from tracksFilteredByPrev " . $numTracks . "/" . scalar @tracksFilteredByPrev);
        @tracks = ( @tracks, splice(@tracksFilteredByPrev, 0, $MIN_NUM_TRACKS_TO_USE - scalar(@tracks)) );
        $numTracks = scalar @tracks;
    }
    if ( $numTracks < $MIN_NUM_TRACKS_TO_USE && scalar @tracksFilteredByCurrent > 0) {
        main::DEBUGLOG && $log->debug("Add some tracks from tracksFilteredByCurrent " . $numTracks . "/" . scalar @tracksFilteredByCurrent);
        @tracks = ( @tracks, splice(@tracksFilteredByCurrent, 0, $MIN_NUM_TRACKS_TO_USE - $numTracks) );
        $numTracks = scalar @tracks;
    }
    if ( $numTracks < $MIN_NUM_TRACKS_TO_USE && scalar @tracksFilteredBySeeds > 0) {
        main::DEBUGLOG && $log->debug("Add some tracks from tracksFilteredBySeeds " . $numTracks . "/" . scalar @tracksFilteredBySeeds);
        @tracks = ( @tracks, splice(@tracksFilteredBySeeds, 0, $MIN_NUM_TRACKS_TO_USE - $numTracks) );
        $numTracks = scalar @tracks;
    }
    if ( $numTracks < $MIN_NUM_TRACKS_TO_USE && scalar @tracksFilteredBySeedNotInGenreGroup > 0) {
        main::DEBUGLOG && $log->debug("Add some tracks from tracksFilteredBySeedNotInGenreGroup " . $numTracks . "/" . scalar @tracksFilteredBySeedNotInGenreGroup);
        @tracks = ( @tracks, splice(@tracksFilteredBySeedNotInGenreGroup, 0, $MIN_NUM_TRACKS_TO_USE - $numTracks) );
        $numTracks = scalar @tracks;
    }

    # Always take from 1st 2*DESIRED_NUM_TRACKS_TO_USE tracks
    if ( $numTracks > ($DESIRED_NUM_TRACKS_TO_USE*2) ) {
        main::DEBUGLOG && $log->debug("Pre-trimming tracks (" . $numTracks . ")");
        @tracks = splice(@tracks, 0, $DESIRED_NUM_TRACKS_TO_USE*2);
        $numTracks = scalar @tracks;
    }

    # Shuffle tracks...
    Slim::Player::Playlist::fischer_yates_shuffle(\@tracks);

    # If we have more than DESIRED_NUM_TRACKS_TO_USE tracks, then use 1st DESIRED_NUM_TRACKS_TO_USE...
    if ( $numTracks > $DESIRED_NUM_TRACKS_TO_USE ) {
        main::DEBUGLOG && $log->debug("Trimming tracks (" . $numTracks . ")");
        @tracks = splice(@tracks, 0, $DESIRED_NUM_TRACKS_TO_USE);
        $numTracks = scalar @tracks;
    }

    main::DEBUGLOG && $log->debug("Return " . $numTracks . " tracks");
    foreach my $track (@tracks) {
        main::DEBUGLOG && $log->debug(".... " . $track->title . ", " . $track->artistName . ", " . $track->albumname);
    }
    return \@tracks;
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
        main::DEBUGLOG && $log->debug("Confgured genres: " . Data::Dump::dump(@genreSets));
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
    main::DEBUGLOG && $log->debug("Christmas genres: " . Data::Dump::dump($xmasGenres));
}

sub _getSeedGenres {
    my $track = shift;
    my @genres = ();
    if ($prefs->get('filter_genres')>0) {
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
