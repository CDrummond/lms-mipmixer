# MusicIP Mixer

This is a forked version of the `Don't Stop The Music` mixer part of LMS's
standard `MusicMagic`/`MusicIP` plugin. *Only* the mixer part remains, with the
following modifications:

1. Option to restrict tracks to those within a set of genres matching the seed tracks genres
2. Filter out tracks with matching artist from last 15 tracks
3. Filter out tracks with matching artist+album from last 25 tracks
4. Filter out tracks with matching artist from seed tracks
5. Option to filter on duration
6. Option to exclude artists
7. Option to exclude albums
8. Option to exclude Chistmas genres if not December
9. Only 1 request (per mix) is made with all 5 seed tracks, as opposed to 1 request per track
10. Handles `file://` URLs being returned from MusicIP. This is to help with CUE
file support. To allow MusicIP to use CUE files, see the `analyser` and `proxy`
scripts located at [https://github.com/CDrummond/musicip](https://github.com/CDrummond/musicip)

## Genre groups

Genres are configured in the plugin's LMS settings page. Each line in this
settings section is a genre group - and is a list of comma separated genres.

If a seed track has `Hard Rock` as its genre, then only tracks with `Rock`, 
`Hard Rock`, or `Metal` will be allowed. If a seed track has a genre that is not
listed here then any track returned by MusicIP, whose genre is not in one of
these groups, will be considered acceptable.

## Filtering

If too many tracks are filtered out due to matching previous, current, or seed
tracks, or not having genre in a group, then some of these filtered tracks will
be used to obtain the minimum required.
