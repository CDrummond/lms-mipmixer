# MusicIP Mixer

This is a forked version of the `Don't Stop The Music` mixer part of LMS's
standard `MusicMagic`/`MusicIP` plugin. *Only* the mixer part remains, with the
following modifications:

1. Option to restrict tracks to those within a set of genres matching the seed tracks genres
2. Handles `file://` URLs being returned from MusicIP. This is to help with CUE
file support. To allow MusicIP to use CUE files, see the `analyser` and `proxy`
scripts located at [https://github.com/CDrummond/musicip](https://github.com/CDrummond/musicip)

Genres are configured via editing `genres.json` using the following syntax:

```
[
 [ "Rock", "Hard Rock", "Metal" ],
 [ "Pop", "Dance", "R&B"]
]
```

If a seed track has `Hard Rock` as its genre, then only tracks with `Rock`, 
`Hard Rock`, or `Metal` will be allowed. If a seed track has a genre that is not
listed here then any track returned by MusicIP will be considered acceptable.

`genres.json` should be placed within you LMS's `prefs` folder. If this is not
found there, then the plugin will use its own version.
