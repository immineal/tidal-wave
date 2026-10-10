# Changelog

Notable changes to Tidal Wave, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Tidal Wave is an
application rather than a library, so the version numbers are release
milestones and not a semver promise about an API.

## [0.4.0] - 2026-10-05

### Added

- Six themes: three dark (Sea, Pine, Rust) and three light (Sky, Sand, Clay),
  with a pure-black switch that pulls any dark theme to true black for OLED
  screens. Switching repaints the running app.
- A complete German translation. The language follows your system locale and
  can be changed without restarting.
- A Settings panel.
- Pinning for albums, playlists, artists and mixes, reorderable by dragging,
  stored per Tidal user id.
- The sidebar is now one list under the pinned block, ordered by when you last
  played or saved each thing, with a search field and filter chips above it.
  Below 820px of window width it collapses to an icon rail that hover-expands
  back over the content, and its border is a drag handle.
- Creating a playlist, which the app could not do at all before.
- Search pages as you scroll, remembers recent queries, finds mixes, and can be
  sorted.
- Lyrics, a fullscreen reading view, and track credits.
- A sleep timer in Now Playing with presets, a custom slider, an optional
  fade-out and an end-of-track mode.
- A spectrum analyser in the player bar, and pages tinted from the cover art.
- Live audio output switching. The player follows the system default device as
  it changes, or stays on one you pick, keeping position and play state across
  the switch.
- An update check against the GitHub releases API, at most once a day, offered
  at the next launch rather than mid-session. It never downloads or installs
  anything, and it can be turned off.
- A software rendering switch for machines where the GPU path misbehaves.
- Reduced motion is honoured throughout, not in one place.
- Two feedback buttons in Settings. Both hand a prefilled draft to your browser
  or mail client; the app sends nothing itself.
- Saved radios and saved mixes appear in the sidebar, including two mixes that
  nothing in the app could previously reach.
- AppStream metainfo, a `.desktop` entry named after the app id, and a PKGBUILD,
  so Linux software stores can list the app.
- Every artist in a track row is its own link.

### Changed

- The sidebar's alphabetical tier is gone. Saving an album used to put it at
  alphabetical position 589 of 971, which is the same as not appearing.
- Plainer theme names, and a neutral theme by default.
- Drawn icons replace the typographic glyphs that were standing in for them,
  and every context menu entry has one.
- The tab and chip highlight travels to its new position instead of fading out
  in one place and in somewhere else.
- The volume control is a speaker you point at, opening an upright slider, and
  the readout sits with its icon at the end of the transport row.
- Video mixes are dropped from the generated mixes page, because the app has no
  video support and those tiles opened empty. A video mix you saved yourself is
  kept.

### Fixed

- Lossless was serving the same 320 kbps AAC file as High. The playback
  endpoint returned an identical manifest for both qualities on 27 of 27
  tracks, so the setting labelled "Lossless (16-bit)" was inert and nothing
  said so. The FLAC tiers now go to a different endpoint that serves real FLAC.
  The same bug made every "FLAC" download of a non-hi-res track a lossy AAC
  stream re-encoded into a lossless container.
- Lossless could not play at all on a build made against the Qt installer.
  Lossless arrives as MPEG-DASH, which needs FFmpeg's DASH demuxer, and the
  FFmpeg bundled with the Qt installer is built without it. Every DASH track
  was rejected as InvalidMedia in under a millisecond with nothing in the log.
  Whether lossless worked came down to which Qt the packager happened to have.
  The app now fetches and joins the DASH segments itself.
- A logout or a SIGTERM left the playing track behind in `/tmp`. Neither
  ran the destructors, so the temp file holding the current track was never
  removed. They had been piling up at 1.5 to 13 MB each.
- An album whose id Tidal no longer serves opened a blank page. Both
  callbacks dropped the error, so a delisted favourite and a broken app looked
  identical. The page now says the album is unavailable and suggests searching
  for the title. The artist, playlist, mix and radio pages had the same dropped
  error and now say why they are empty too.
- Track radio had two different viewers and could be neither saved nor unsaved.
- The artist discography never showed singles, EPs or compilations, because the
  API call was missing its `filter` parameter.
- A stream that stops answering is given up on, and the preload starts early
  enough to finish.
- Qt 6.4 and Debian 12: the `.deb` installed and then died at load, every type
  in the QML module reported "not a type", and one `.deb` shipped without a QML
  module behind a check that could not fail.
- The app deadlocked when an audio output device changed.
- Theme switching did nothing at all.
- Renaming a playlist never reached the server.
- A playlist's track count was wrong, and a pinned playlist was writing a
  translated count to disk.
- A like or save the server refused was shown as having worked, at all eleven
  places it could happen.
- Liked, saved and played each meant something other than what they showed.
- Dragging a pin did nothing. It then failed depending on how many pins you
  had, and was broken again by the animations.
- Escape bounced between two pages instead of walking back out of them.
- F11 restored the window but not the view it had navigated away from.
- The sidebar kept showing the favourites list it had fetched at sign-in.
- A mix or playlist opened by id alone had no hero.
- Startup failures stranded people with no message, and an offline start lost
  the saved session.
- The packaged app could not start at all, and an installed binary could not
  find the Qt it was built against.
- English strings in the middle of a German UI, including "14 track(s)".
- 37 ms of every launch was spent failing to find a font.
- Sidebar thumbnails were being decoded at full size.
- The sleep timer popup hung off the bottom of a short window.
- Every label on an accent fill was black.
- Share links took a `/browse/` detour they did not need.

## Earlier releases

0.3.1 and everything before it predate this file. See the
[releases page](https://github.com/immineal/tidal-wave/releases) and `git log`.

[0.4.0]: https://github.com/immineal/tidal-wave/compare/v0.3.1...v0.4.0
