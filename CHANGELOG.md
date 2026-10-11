# Changelog

Notable changes to Tidal Wave, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Tidal Wave is an
application rather than a library, so the version numbers are release
milestones and not a semver promise about an API.

## [0.4.0] - 2026-10-11

### Added

- Six themes: three dark (Sea, Pine, Rust) and three light (Sky, Sand, Clay),
  with a pure-black switch that pulls any dark theme to true black for OLED
  screens. Switching repaints the running app.
- A complete German translation. The language follows your system locale and
  can be changed without restarting.
- Pinning for albums, playlists, artists and mixes, reorderable by dragging,
  stored per Tidal user id.
- Creating a playlist from inside the app.
- Search pages as you scroll, remembers recent queries, finds mixes, and can be
  sorted.
- A fullscreen reading view for lyrics.
- Credits for tracks and albums.
- Fullscreen Now Playing on F11, with a background that takes its colour from
  the cover.
- The bars on the playing track can show a spectrum of the music. This is off
  until you switch it on.
- Live audio output switching. The player follows the system default device as
  it changes, or stays on one you pick, keeping position and play state across
  the switch.
- An update check against the GitHub releases API, at most once a day, offered
  at the next launch. It never downloads or installs anything, and it can be
  turned off.
- A software rendering switch for machines where the GPU path misbehaves.
- An interface size slider.
- A choice between quitting and hiding to the tray when the window is closed.
- The system's reduced-motion setting is honoured.
- Two feedback buttons in Settings. Both hand a prefilled draft to your browser
  or mail client; the app sends nothing itself.
- A track radio can be saved to your library and removed from it.
- Every artist in a track row is its own link.
- Debian 12 and Ubuntu 24.04 are supported with their own Qt 6.4, and CI runs
  the tests on it.
- An AppImage that carries its own Qt, for systems whose Qt is too old for the
  app or that have none.
- AppStream metainfo, a `.desktop` entry named after the app id, and a PKGBUILD,
  so Linux software stores can list the app.
- `SHA256SUMS` beside the downloads.

### Changed

- Settings is a panel with sections for appearance, language, playback,
  performance, updates, feedback, shortcuts and privacy. In 0.3.1 it was a
  popup holding the account, the streaming quality and the shortcut list.
- The sidebar lists the whole library. Pinned items come first, then
  everything you saved in one list, ordered by when you last played or saved
  each thing, with a search field and filter chips above it. In 0.3.1 it
  listed playlists only. Below 820px of window width it collapses to an icon
  rail that hover-expands back over the content, and its border is a drag
  handle.
- My Daily Discovery and My New Arrivals lead the row of mixes. They were the
  last two of ten.
- Drawn icons replace the emoji and typographic glyphs that were standing in
  for them, and every context menu entry has one.
- The tab and chip highlight travels to its new position.
- The volume control is a speaker you point at, which opens an upright slider.
- The queue opens with Ctrl+J. It was Ctrl+Q.
- Video mixes are dropped from the generated mixes page, because the app has no
  video support and those tiles opened empty. A video mix you saved yourself is
  kept.
- The `.deb` is built on Debian 12, the oldest system it supports, and is
  installed on Debian 12 and 13 and Ubuntu 24.04 before it is published. Its
  dependencies carry minimum versions, so apt refuses a system that is too old.
  The 0.3.1 package was built against Qt 6.11 and named no versions.
- The Windows zip brings the Visual C++ runtime with it.
- The macOS download is named for what it holds, `tidal-wave-macos-arm64.tar.gz`.
- The screenshots show an invented library.

### Fixed

- Lossless was serving the same 320 kbps AAC file as High. The playback
  endpoint returned an identical manifest for both qualities on 27 of 27
  tracks, so the Lossless setting was inert and nothing said so. The FLAC tiers
  now go to a different endpoint that serves real FLAC. The same bug made every
  "FLAC" download of a non-hi-res track a lossy AAC stream re-encoded into a
  lossless container.
- MPEG-DASH streams could not play at all on a build made against the Qt
  installer, which is how the 0.3.1 downloads were built. The FFmpeg bundled
  with the Qt installer has no DASH demuxer, so every DASH track was rejected
  as InvalidMedia in under a millisecond with nothing in the log. Lossless and
  hi-res both arrive as DASH. The app now fetches and joins the segments
  itself.
- A logout or a SIGTERM left the playing track behind in `/tmp`. Neither
  ran the destructors, so the temp file holding the current track was never
  removed. They had been piling up at 1.5 to 13 MB each.
- An album whose id Tidal no longer serves opened a blank page. The page now
  says the album is unavailable, and offers to search for another edition or
  to drop the album from your library. The artist, playlist, mix and radio
  pages dropped the same error and now say why they are empty too.
- The artist discography never showed singles, EPs or compilations, because the
  API call was missing its `filter` parameter.
- A stream that stops answering is given up on. No request on the playback path
  had a timeout.
- The `.deb` did not name `qml6-module-qtquick-shapes` among its dependencies.
  On a system without that module it installed and then showed no window.
- Renaming a playlist never reached the server.
- A playlist's track count stayed at its old value after tracks were added.
- A like or save the server refused failed without a word. It now says so.
- Escape and the back button bounced between two pages. They walk back through
  the pages you came from.
- A mix or playlist opened from "Playing from" in Now Playing had no title and
  no cover.
- An offline start lost the saved session.
- With no system tray, closing the window hid the app and left nothing on
  screen to bring it back or quit it.
- System proxy settings were ignored.
- A build installed to a prefix could not find the Qt it was built against.
- About 37 ms of every launch on macOS went to looking up fonts that are not
  installed.
- The sleep timer popup hung off the bottom of a short window.
- Share links took a `/browse/` detour they did not need.

### Fixed since the first publication

0.4.0 was first published on 5 October. These were wrong in that set of files
and are fixed in the set published on 11 October.

- The `.deb` could not be installed on any system. It asked for Qt 6.12 and a
  libstdc++ that no Debian or Ubuntu release had.
- Lossless did not play on Qt 6.4. The segment downloads broke down after the
  first few requests and the player stayed paused without a word.
- A seek inside a lossless track on Qt 6.4 silenced the rest of the track.
- Media keys and desktop media widgets (MPRIS) had stopped answering.
- A restored session lost its queue when the stream could not be requested at
  startup.
- Reopening a menu crashed the app under software rendering on Qt 6.4.
- The volume control sat on the shuffle button when a narrow window went
  fullscreen.
- The Windows build did not start on a machine without the Visual C++ runtime.

## Earlier releases

0.3.1 and everything before it predate this file. See the
[releases page](https://github.com/immineal/tidal-wave/releases) and `git log`.

[0.4.0]: https://github.com/immineal/tidal-wave/compare/v0.3.1...v0.4.0
