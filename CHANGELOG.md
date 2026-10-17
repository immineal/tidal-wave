# Changelog

Notable changes to Tidal Wave, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Tidal Wave is an
application rather than a library, so the version numbers are release
milestones and not a semver promise about an API.

## [0.4.2] - 2026-10-12

### Added

- An album page ends with a row, Other versions, when Tidal's own album page
  names other versions of the record. Under each card stands what tells that
  version apart: explicit or clean, and Dolby Atmos or the quality. A card
  opens the version, and its play button plays it.

### Changed

- An artist page shows each album, EP and single once. Tidal lists the
  explicit and the clean version of a record as entries of their own, and each
  of the two again in 16-bit, in hi-res and in Dolby Atmos. 0.4.1 showed a
  card for every entry, so an album that exists in all six stood on the page
  six times.
- The one card of a record opens its explicit version in hi-res stereo where
  there is one, and the album page leads to the others. Entries count as one
  record when they have the same title, the same number of tracks and nearly
  the same length, so a deluxe edition keeps a card of its own. For six
  artists looked at, the 1140 entries of their own releases became 605 cards.
- A playlist keeps the id a track had when it was added, and Tidal stops
  streaming some of these ids while the recording stays on another release.
  - Such a track is now played from the other release, which the program
    finds by the recording's code (ISRC). It does so when the track is picked
    and when the queue reaches it.
  - In 0.4.1 a picked track gave the message "This track is no longer
    available on Tidal." at the Low and High settings, and "This track is not
    available for your account or region." at Lossless and Hi-Res. A running
    queue passed it over.
  - The row in the list is shown as playing. The player names the release the
    track is played from, so its album and cover can differ from the row's.
  - Of twenty such tracks looked at, sixteen had another release. A track
    without one is reported and passed over as before.

### Fixed

- A track that Tidal has only in AAC plays at the Lossless and Hi-Res
  settings. It plays in AAC, and the player shows it as High. In 0.4.1 it
  ended with "Could not load this track for playback." at these two settings,
  and a running queue stopped on it.
- The line under an album's title called a Dolby Atmos album "Low", which is
  how Tidal lists it, and a hi-res album "Lossless". It now says "Dolby Atmos,
  plays in stereo" for the first and "Max" for the second, the name the player
  uses for hi-res.
- On an album page the bar with the album's title came in only after the
  first tracks had passed under it, so rows showed through a bar that was
  half drawn, and an album whose page ended there kept it so. The bar now
  comes in as the top of the page leaves and is whole when the first track
  reaches it.

### Known issues

- Dolby Atmos is not played. A Dolby Atmos version of an album plays in
  stereo.
- Search results list every version of a record, as before.
- The Other versions row can hold fewer versions than exist. For one album
  with five other versions, Tidal's page named three.
- Two different records with the same title, the same number of tracks and
  nearly the same length share one card on an artist page.
- A track with no other release of the same recording still cannot be played.
  Casting a track that Tidal no longer streams under its id still fails, and
  so does a download from its row.
- A download of a track that Tidal has only in AAC is refused, as in 0.4.1.
- The two issues listed under 0.4.1 for Qt 6.4 are unchanged.

## [0.4.1] - 2026-10-12

### Added

- The AppImage carries its version and its update information, and a release
  has a `.zsync` file beside it.
  [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) and
  [AppImageLauncher](https://github.com/TheAssassin/AppImageLauncher) read
  both when they add the file to the application menu. With the 0.4.0 file
  Gear Lever showed no version and no update source. The README names the two
  tools.

### Changed

- An artist page has a row of its own, Appears On, for the records the artist
  is only a guest on, with up to fifty of them. In 0.4.0 they sat under Albums
  among the artist's own records.
- When the queue reaches a track that Tidal reports as gone, or that the
  account or region may not play, the program names the track and goes on to
  the next one. After five such tracks in a row it stops and says so. In 0.4.0
  playback stopped at the first one without a word.
- Next and Previous from a media key or a desktop widget leave a paused player
  paused, as MPRIS asks. In 0.4.0 they started playback. The program's own
  buttons and shortcuts start the track as before.
- The AppImage leaves out the Qt modules, styles and translations the program
  never loads. The 0.4.0 file, repacked the same way, went from 61 MB to
  52 MB.
- CI runs the tests on the Qt of Ubuntu 24.04, Debian 13, Ubuntu 26.04,
  Fedora 44 and Arch, and on Qt 6.5, 6.7, 6.8 and 6.11 from the Qt installer.
  For 0.4.0 they ran on Qt 6.4 and 6.12 only.

### Fixed

- A suspended computer could leave the program with a dead sign-in token.
  0.4.0 renewed the token with a single timer, and that timer stands still
  while the machine sleeps. After a sleep longer than the token had left,
  nothing loaded until the late renewal or a restart. The program now compares
  the token's expiry with the clock every 30 seconds, and it repeats a request
  that Tidal refuses for its token once, with a new token. The tests move the
  clock against a local server. No real suspend was tried.
- A start in the last minute of a token's life left the program signed in with
  a token that it never renewed. Signing out while a renewal was under way
  signed the program in again.
- The sign-in token goes to Tidal's two API hosts only. 0.4.0 also sent it
  with every audio file it fetched and with the cover of a download, to
  whichever host served them. The program no longer follows a redirect to
  another host with a request that carries the token.
- Four faults on Debian 12 and Ubuntu 24.04, which ship Qt 6.4. The fixes ran
  with PulseAudio in a container and on two virtual machines.
  - Starting a track with no audio device crashed the program. It now refuses
    the start with a message.
  - After a restart of the sound server the next track crashed the program.
    It now says that the sound output was lost and asks to be restarted.
  - When the sound server went away under a playing track, the track stood
    still and was shown as playing, and a quit could leave the process behind.
    The program now says that the sound output was lost, pauses the track, and
    ends when it is quit.
  - After the headphones or the USB device a track played on were unplugged,
    the next track could freeze the program. It now plays on an output that is
    still there.
- A track that could not be loaded said nothing, and the play button went from
  loading back to play. A short message at the play button now says why: the
  track could not be loaded, Tidal no longer has it, or it is not available
  for the account or region. Pressing play again asks for the track again. In
  0.4.0 that did nothing after a failed download.
- A press on play or pause while a track was still loading was lost. It now
  decides whether the track plays once it has loaded. A track picked at
  startup, while the track of the last session was still loading, came up
  paused. It plays.
- A like, a save, a follow or a playlist edit that Tidal refused could be
  shown as done. The heart filled, the playlist took its new name or the track
  left the list, and the next load took it all back. 0.4.0 read Tidal's usual
  error answer as a yes. The program now reports it as a refusal.
- Media keys and desktop media widgets (MPRIS):
  - The status is Playing, Paused or Stopped. 0.4.0 said "Loading" while a
    track loaded, which MPRIS does not have, and Paused with an empty queue.
  - The position is announced after a seek. 0.4.0 announced every position
    report as a seek, several hundred a minute.
  - A widget learns which controls work. With an empty queue none do, and the
    last track of a queue that does not repeat has no Next. 0.4.0 offered all
    five at all times.
  - Changes of repeat, shuffle and volume made in the program are announced.
    A position set for another track, or for a place outside the track, is
    dropped.
  - Raise brings the window back, from the tray as well. It did nothing.
  - Each artist of a track is listed on its own. A track without a cover, an
    album or a track number leaves that field out. 0.4.0 sent all the names
    as one string, and an empty value or a 0.
- Faults with Qt 6.5 and 6.6. None of the tested distributions ships these
  versions, so they concern a build from source with the Qt installer. The
  fixes ran in containers, with wheel input from the test library only.
  - On Qt 6.5 the rows below the window on Home and on an artist page could
    not be scrolled to, the search results did not scroll, and Settings
    scrolled far past its last row.
  - On Qt 6.5 Play did nothing after the queue had ended.
  - On Qt 6.5 and 6.6 the update prompt was 14 px too short for its text. With
    reduced motion, Now Playing kept the title and the controls 30 px below
    the middle of the artwork after the window was narrowed and widened again.
- On Fedora, whose default font is Noto Sans, the sleep timer changed its
  width by a pixel while it counted, and a long artist line could run up to
  three pixels past its end.
- A window of the AppImage that Gear Lever or AppImageLauncher added to the
  menu is matched to its menu entry on Wayland. With the 0.4.0 file GNOME
  showed it as an application of its own with a generic icon, and Plasma did
  not group it under a pinned entry.
- A radio started from a row of a radio page left the first radio on screen.
  The new one replaces it.
- A search tab loads more results when the window grows past the end of its
  list. In 0.4.0 the rest could not be reached until the tab was switched.
  Search also asked for pages of results that nobody had scrolled to.
- With the language set to System, the program starts in the system's display
  language. 0.4.0 asked the regional format first, which is a separate setting
  on Windows, so a German Windows with an English format started in English.
  On Windows the program now asks Windows which language it displays. On a
  Windows 11 machine with the German display language and English formats,
  0.4.0 started in English and 0.4.1 starts in German.
- Quitting printed about ninety QML errors to the terminal. It prints none.
- When a new playlist could not be created, the dialog could show the address
  of the request, which holds the user id. It shows Tidal's reason or none.
- A double click on a track could fetch it twice. The track then started over
  when the second copy arrived, and one file stayed behind in the temp
  directory.
- A track that did not fit on the disk could play cut short. The program now
  reports it.

### Known issues

- On Qt 6.4 with `QT_MEDIA_BACKEND=gstreamer` set by hand, a seek can leave
  the rest of a track silent. The cause is in Qt's GStreamer backend. Left
  alone, the program uses the FFmpeg backend on Qt 6.4.
- On Qt 6.4, when the sound server ends the stream of a playing track while
  the server itself keeps running, the next track, a change of output or a
  quit can still freeze or end the program.

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

[0.4.2]: https://github.com/immineal/tidal-wave/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/immineal/tidal-wave/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/immineal/tidal-wave/compare/v0.3.1...v0.4.0
