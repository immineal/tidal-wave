# Changelog

Notable changes to Tidal Wave, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Tidal Wave is an
application rather than a library, so the version numbers are release
milestones and not a semver promise about an API.

## [0.5.0] - 2026-11-18

### Added

**Playback**

- The next track follows the last one without a gap. A second player loads
  the next track's file and starts it just before the current one ends.
  Where the next file is not ready in time, the change goes as in 0.4.2,
  which left a short silence between tracks. This needs Qt 6.5 or newer.
- Normalise loudness, a switch under Settings > Playback, on by default.
  Each track plays at the loudness Tidal measured for it, so a quiet master
  and a loud one come out about as loud. An album played from its page in
  its own order keeps the album's balance between its tracks. A track is
  never raised past what its peak allows.
- Crossfade between tracks, a switch under Settings > Playback, off by
  default, with a length from 1 to 12 seconds (5 to begin with). Tracks
  that follow each other on the album that plays, in its order, keep their
  gapless join. A skip changes at once. Settings shows the two rows on Qt
  6.5 and newer only.
- Autoplay similar tracks when the queue ends, a switch under Settings >
  Playback, off by default. With it on, the track radio of the last track
  joins the end of the queue, leaving out tracks already in it, and
  playback goes on into it. Repeat and casting leave the queue as it is.
- A lossless track starts once the first part of it has arrived. 0.4.2
  waited for the whole file. On Qt 6.4 and 6.5 the track still waits for
  the whole file.
- The quality badge shows the format of the stream that plays: "24-bit /
  96 kHz FLAC", "16-bit / 44.1 kHz FLAC" or "AAC 320 kbps". Now playing
  puts the tier in front, as in "Max · 24-bit / 96 kHz FLAC". 0.4.2 showed
  the tier alone. Where the stream does not say, the tier is shown as
  before.
- Version of records with explicit lyrics, under Settings > Playback:
  Explicit, the default, or Clean. Search results, an artist's popular
  tracks, the artist's discography and the rows Tidal puts on Home show
  that version where a record exists in both. A record with one version
  shows whatever the setting, and so does everything you saved. The album
  page's Other versions row lists the other one, and now also finds it
  where Tidal's own page names none.

**Lyrics**

- Settings has a new section, Experimental, above Privacy. It holds three
  switches for lyrics.
- Synced lyrics from LRCLIB, on by default. While the now playing page is
  open, a track that Tidal has no synced lyrics for is looked up on
  lrclib.net. Lyrics from more sites, off unless you turn it on, asks
  NetEase Cloud Music, KuGou and Genius after LRCLIB, in that order.
  - The asking stops at the first site with synced lyrics, and these follow
    the song as Tidal's do. Plain lyrics from Tidal stay on screen while the
    sites are asked.
  - A line at the foot of the lyrics names the site, and a click on it opens
    the site. A track that LRCLIB or NetEase knows as an instrumental says
    Instrumental.
  - Each site gets at most one request a second and is left alone for a
    while after it refuses one. Synced lyrics that are found are kept on
    disk, so the song is not looked up again. A track with plain lyrics only,
    or none, is looked up again after 30 days.
  - The privacy notice in Settings and the README say what each site
    receives, and that two of them are servers in China.
- Sync plain lyrics automatically, on by default. Lyrics without timings,
  from Tidal or from a site, are timed against the track's audio on this
  machine, and nothing is sent anywhere for it. It uses the audio the app
  has already downloaded to play the track, and runs at low priority in the
  background. While the lyrics are open, the next track is analysed ahead.
  - Timings it is unsure of are not shown. The ones shown follow the song
    and say "Synced automatically, may be off" under the lyrics. Synced
    lyrics from Tidal or a site are always preferred to them.
  - The timings are kept on disk next to the lyrics.
- Plain lyrics that are longer than the panel have a scroll bar in its
  right margin, which can be dragged. 0.4.2 showed none.

**Scrobbling**

- Settings has a new section, Scrobbling, below Playback, with a switch
  each for ListenBrainz and Last.fm. Both are off by default and can be on
  at once.
  - ListenBrainz takes the user token from your ListenBrainz settings page.
    Last.fm signs in through its own page in the browser: Connect with
    Last.fm, then I've allowed access.
  - A track counts once half of it, or 4 minutes, has really been played,
    and only if it is longer than 30 seconds. Pauses and seeks add nothing.
    Casting counts like playing here.
  - Each listen is kept on disk until the service has taken it, so a quit
    or a lost connection loses none. Disconnect forgets the account and
    keeps the listens not sent yet for when the same account connects
    again. Discard deletes them. Logging out of Tidal disconnects both.
  - The privacy notice in Settings and the README say what each service
    receives.

**Playlists and the collection**

- Ctrl+Z takes back the last change, and a notice above the player bar
  offers Undo for it. This covers liked tracks, saved albums and mixes,
  followed artists, tracks added to or removed from a playlist, a playlist
  reordered and the queue cleared, up to ten changes back. The app reads
  each change back from Tidal before it says it is done. A change Tidal
  does not show is reported as not confirmed, with no Undo. Deleting a
  playlist has no Undo.
- A playlist you made can be deleted, from Delete playlist… in its menu in
  the sidebar or from Delete in its Edit dialog. Both ask first.
- A playlist you made can be reordered by dragging its tracks, while it is
  shown in its own order and not filtered. The row stays in its place, a
  line shows where it will land, and a small chip with the title follows
  the pointer. Escape calls the drag off.
- A track can be dragged from any list onto one of your playlists in the
  sidebar, or into the queue. Held over the queue button in the player bar
  for a moment, it opens the queue and lands between the rows where it is
  let go. Let go on the button, it goes to the end of the queue.
- A whole album, playlist or mix goes into a playlist from Add to playlist
  in its header's menu or its card's menu.
- The Add to playlist picker has a search field and ticks the playlists
  that hold the track already.
- A playlist made with New playlist opens, from the sidebar, from
  Collection and from the picker. 0.4.2 left you where you were.
- Adding a track that a playlist holds already asks, "Already in …", with
  Add anyway and Cancel. 0.4.2 added it a second time without a word.
- An album or playlist can be downloaded whole, from a button in its
  header. The tracks go one at a time into a folder named after it, as
  FLAC, at least 20 seconds apart to keep clear of Tidal's limits. The
  button turns into Cancel while the run goes, and tracks already in the
  folder are skipped, so a run picks up where a cancelled one stopped.
- Settings > Playback has a Download folder, where the save dialog starts.
  After a download, the row's tick and Show in folder in its menu open the
  file manager at the file. A failed download says why in a tool tip over
  the row's button. 0.4.2 only turned the button red.
- A playlist has a field in its header, Find in this playlist…, that
  narrows the list to tracks whose title, artists or album hold the words.
- Liked tracks, playlists, mixes and track radios have column headings: #,
  Title, Album, Date added (on liked tracks and playlists) and Length. A
  click on Title, Album, Date added or Length sorts by it, a second click
  the other way round, a third returns to the list's own order. Scrolled
  down, the headings stay at the top. On liked tracks they take the place
  of the sort words. The album page has the same headings, which sort
  nothing there.
- Track rows show a filled heart on liked tracks, and an outline heart
  under the pointer on the others. A click on it likes or unlikes. An
  explicit track carries an "E" after its title, and a track's version
  follows the title, as "(Live)". The album name in a row is a link to the
  album.
- Copy link in the menu of albums, playlists, artists and mixes. Album,
  playlist, artist and mix pages have a More button that opens that menu.
- An album card's artists are links, and its menu has Go to artist.
- Collection has a button right of its search field. On the albums,
  artists, playlists and mixes tabs it is Surprise me and opens one of the
  items shown at random. On the tracks tab it is Shuffle and plays the
  tracks shown in random order. Both follow the search field and the sort.
- Saved albums can also be sorted by Artist or by Year.
- When Tidal cannot be reached, a strip above the page says so, with Try
  now, and the app keeps asking on its own. Your collection is shown as it
  was last saved on this computer. 0.4.2 started offline with an empty
  library and "No saved tracks".

**Pages**

- Home shows the rows Tidal's own apps put on their home page, around your
  own rows, in two tabs, For you and Staff picks, at the right end of the
  greeting's line. The row names come from Tidal in the app's language.
- Home's new row Recently played lists the albums, playlists, mixes and
  artists played lately, on any device, from Tidal's own list, with what
  was played here added. Tidal does not learn from this app what it plays.
- Under the greeting, Home shows the track in the player with a button to
  play it.
- An artist page has an Artist radio button where Tidal has a station for
  the artist, and Shuffle beside Play.
- Search leads with Tidal's top result on the All tab. Recent searches sit
  under the field.
- A track radio page has a header like the other pages, with Play and
  Shuffle. 0.4.2 had Play all over a bare list.
- The album page numbers each disc's tracks from 1 and puts a heading over
  each disc of an album with more than one. 0.4.2 numbered the rows
  through.
- Album, artist, playlist, mix and radio pages that fail to load offer Try
  again, and say so when Tidal cannot be reached.

**The queue**

- Every row still to come can be dragged, within its part of the queue or
  across into the other. 0.4.2 let only the hand-queued rows move. The row
  stays in its place while it is dragged, a chip with the title follows the
  pointer, and Escape calls the drag off.
- Every queue row has a menu: Play next, Add to playlist, Go to album, Go
  to artist and, for rows still to come, Remove from queue. 0.4.2 had Remove
  from queue on hand-queued rows only.
- The queue has a close button, and takes the keyboard while it is open.

**Desktop**

- The tray menu has Previous track, Play or Pause, and Next track, and the
  tray icon's tool tip names the track that plays.
- `tidal-wave --play-pause`, `--next` and `--previous` control the running
  app. `--help` and `--version` print and exit.
- Tidal links open in the app: tidal:// links and tidal.com and
  listen.tidal.com links, from the command line, the desktop's link
  handler, a drop on the window, a paste into Search or MPRIS. A track
  link opens its album.
- The desktop entry opens tidal:// links and has Play/Pause, Next Track
  and Previous Track in the launcher's menu.
- Desktop media widgets (MPRIS) can list the queue around the current
  track and skip to a track in it.
- On Windows and macOS the media keys work, and the system's now playing
  panel shows the track.
- Show a notification when a new track starts, under Settings > Window,
  off by default. Nothing is shown while the window is in front.
- The window opens at the size and place it was left, maximised if it was,
  on the page it showed. 0.4.2 opened at 1280 by 800 on Home.
- Reduce motion in Settings > Appearance: As the system says, On or Off.
  The system's setting is now read on Windows and macOS too.
- The mouse wheel over the volume sets it. A running sleep timer shows in
  the player bar with the time left, and a click on it opens now playing.

**Keyboard and screen readers**

- A screen reader can find, name and press the buttons, sliders, tabs,
  switches, cards and rows.
- A track list, the sidebar's library list, a row of cards and the queue
  are one tab stop each, walked with the arrow keys, Home and End. Enter
  plays, and the Menu key or Shift+F10 opens the row's menu. 0.4.2 made
  every row and every artist name a tab stop.
- The seek bar, the volume and the sleep timer work from the keyboard.
  Controls that answered only the mouse are tab stops: Collection's sort
  words, Playing from, the Lyrics and Credits chips, Show all, a card's
  play button and the rows of the playlist picker.
- Escape in a search field empties it, and in an empty one gives the
  keyboard back.
- Small buttons such as the clear crosses and the close buttons take
  presses over at least 32 by 32 pixels.
- New shortcuts: Ctrl+F and Ctrl+L go to the search field, Ctrl+N makes a
  new playlist, Ctrl+Z undoes, Ctrl+Q quits, and Alt+Shift+B likes or
  unlikes the playing track.

### Changed

- Shortcuts that moved: seeking is Shift+Left and Shift+Right, the volume
  is Ctrl+Up and Ctrl+Down, and now playing is Ctrl+4. In 0.4.2 the bare
  arrow keys seeked and set the volume, and Ctrl+N opened now playing.
  Space presses the control the keyboard is on, and plays or pauses
  everywhere else.
- Playback:
  - Next under repeat one goes to the next track. 0.4.2 started the same
    track over. A track that ends under repeat one starts over from the
    file it has, without asking Tidal again.
  - Shuffle from a page plays the track picked first and then the rest of
    the album or playlist in random order. 0.4.2 left out the rows above
    the one it started from.
  - The playing track stays marked while it is paused, and a click on it
    pauses or resumes it. 0.4.2 started it over.
  - A queue restored at start, and a step taken while paused, fetch
    nothing until Play. 0.4.2 downloaded the restored track at every start.
    Nothing is fetched ahead while the player is paused.
  - A run of quick presses on Next or Previous asks Tidal only for the
    track it ends on.
  - The whole queue is kept between sessions. 0.4.2 kept 50 rows before
    the current one and up to 650 after it.
  - The volume slider follows loudness, so its lower half is no longer
    nearly silent. A volume saved by 0.4.2 sounds the same after the
    update.
  - Removing the playing row at the end of the queue stops there. 0.4.2
    went back to the track before and played it.
  - Stop from a desktop media widget stops the track, and Play starts it
    from the beginning. 0.4.2 paused it.
  - The seek bar shows the track's length while the track loads. 0.4.2
    showed the previous track's.
  - The queue's first part is headed "Earlier in queue". 0.4.2 said
    "Played", also for rows that were skipped.
- Log out sits under Account at the top of Settings, beside the name of
  the account, and asks first. It stops playback, empties the queue and
  disconnects scrobbling. In 0.4.2 it was at the foot of the panel, and
  playback and the queue went on after it.
- Settings is laid out as rows under small headings, with a new Window
  section and the version under About at the end. The long privacy notes
  fold behind Details. Settings opens at the top each time, and a wheel
  notch moves it by the desktop's lines per notch. Pure black stays in
  place on a light theme, marked as for the dark themes.
- Add to playlist offers only the playlists you made, and Edit and Remove
  from playlist show only on those. 0.4.2 offered them on playlists of
  other users saved to the collection, and Tidal refused the change.
- Back returns to the last five pages as they were left, scrolled and
  loaded, without fetching them again. Collection keeps each tab's place.
- A mouse drag on a track row carries the track. To scroll a list, use the
  wheel, the scroll bar or a finger.
- Card rows scroll one card at a time from round arrows over their edges,
  with a sideways drag, and with a horizontal wheel or swipe. 0.4.2 scrolled
  them with Shift+wheel and the scroll bar only.
- Look:
  - Detail pages (album, artist, playlist, mix and radio) share one header
    and one bar, and the header takes its colour from the cover.
  - A card under the pointer dims its cover under a white play glyph, and
    nothing grows. Pages load behind a placeholder of their own shape
    instead of a spinner.
  - Confirmations are one notice above the player bar, in place of tool
    tips over the row. Tool tips and scroll bars take the theme's colours.
  - Menus group their entries, with Remove from playlist last, and the row
    a menu is for stays marked.
  - A missing cover shows a glyph. A playlist mosaic uses four different
    covers, or one when there are fewer.
  - While a track loads, the play button shows a turning ring. In 0.4.2 the
    player bar showed three dots.
  - The playing bars are crisp at every screen scale.
  - Settings, the playlist dialogs and the playlist picker dim the app
    behind them.
  - Follow on artist pages shows a person. In 0.4.2 it shared the heart
    with Like.
  - Collection's sort options are plain words with the chosen one bold and
    underlined, and a chosen tab is bold.
  - On a saved album, Saved is an outlined button.
  - Small headings are set in sentence case without spaced letters.
- Themes:
  - Sky's accent is #0074B5 (was #0A6FC4) and its red #C51B32 (was
    #C0392B).
  - Sand's ground is a warm paper (#F9F4E8) and Clay's a light blush
    (#F8EFEA).
  - Rust's and Clay's accents read as rust and clay, further from the red
    of errors.
  - On the dark themes, quiet text such as track numbers, lengths and hints
    is lighter, and so is accent text such as the playing track's title.
  - Sea and Pine have new greens for lossless.
  - The rainbow that "Let the colour in" shows while on looks like glass.
- Now playing:
  - Lyrics take the artwork's place and leave the rest of the page where
    it is. In 0.4.2 they moved the page and pushed Up next down.
  - Fullscreen, the artwork grows with the window. 0.4.2 held it to 420
    pixels.
  - A long title takes two lines before it is cut.
  - With no track it says "No track playing". 0.4.2 showed a dash.
  - Yellow covers tint the page more calmly on the dark themes.
- Wording: labels are in sentence case, and the English says track,
  collection, Log in and Show all throughout. Labels for your own things
  say My: My mixes, My playlists, My account. Favorite artists is spelt
  Favourite artists. "Playing from" names a search as one, as in "search
  “…”", and leads back to it.
- German says Sammlung for the collection everywhere, and several Settings
  lines were rewritten in natural German. Numbers follow the language picked
  in the app. In 0.4.2 they followed the system's.
- On Linux the session file follows $XDG_CONFIG_HOME where it is set. On
  macOS it moves to ~/Library/Application Support/TidalWave/Tidal Wave.
  The file in the old place is read once and removed. It is now written
  so that a crash cannot leave half of it.
- Faster on a large collection: typing in Collection's search field,
  opening a long playlist or the queue, switching between Search's tabs
  and scrolling long lists.
- Collection's search field ignores accents and spaces at either end, as
  the search field in the sidebar does.
- On Qt 6.8 and later the app runs the QML engine's garbage collector in
  whole passes, to stay clear of a fault in Qt's incremental collector. A
  value of QV4_GC_TIMELIMIT set by hand is left alone.
- The screenshots for software centres show real records whose covers are
  under free licences. CREDITS.md names them.

### Fixed

- Removing a track from a playlist works. 0.4.2 sent a request that Tidal
  always refused, and the track stayed. A playlist changed on another
  device in the meantime is read again, and nothing is removed.
- Changes made to your collection on another device reach a running app:
  liked tracks, albums and artists, playlists and saved mixes. 0.4.2 read
  the collection only at sign-in, so such a change showed after a restart.
  The app now checks when its window gets the focus again, at most once a
  minute, and every five minutes while the window is open. A window closed
  to the tray checks nothing. A check is one small request per list, and
  only a list that changed is loaded again.
- Liked tracks, albums and artists are read in one request per list, and
  none go missing. 0.4.2 read them in pages, and Tidal reorders items
  saved at the same moment from one page to the next, so some were skipped
  on every load. A skipped track was missing from Collection and showed an
  empty heart. The hearts now come from Tidal's list of liked ids, which
  also covers tracks Tidal no longer lists.
- Liked tracks are listed newest first. 0.4.2 loaded them oldest first and
  showed the first 100 at once, so with more than 100 liked tracks
  Collection showed the oldest ones until the last of them had arrived.
- While the collection loads, Collection, the sidebar and a playlist's
  header show it loading. 0.4.2 said "No saved tracks", "No saved albums",
  "Nothing saved yet" or "0 tracks" until the lists were in, and the tabs
  read "(0)".
- The sidebar's library and its search stopped reading liked tracks,
  albums and artists at the first page that came back short. Tidal leaves
  tracks that can no longer be played out of a page, so the sidebar often
  knew only the first few dozen liked tracks. It also stopped after 5000.
  When the sidebar knew only part of the list, it forgot when the tracks
  past that point were last played, and its Tracks list is sorted by that.
- Sign-in:
  - A busy or failing login host no longer signs you out. 0.4.2 ended the
    session on any error answer to a token renewal.
  - A saved session signs in once at start. 0.4.2 signed in twice and
    loaded the whole collection twice.
  - Signing out while the account's name was still on its way could write
    the session file again. It no longer does.
- When Tidal answers that the app asks too often, the app now waits as
  long as Tidal says before it asks that part of the service again. 0.4.2
  asked again at once, which kept the limit in force.
- Casting:
  - A Chromecast that stopped reading froze the app, and stopping a cast
    held it up for a moment.
  - The track served to the cast device could be fetched at any address
    by anything on the network. Each track is now served at an address
    made up at random, which only the device is given.
  - On a computer with docker, a VPN or a virtual machine network, the
    device could be handed an address it could not reach.
  - A device that also answered over IPv6 could not be connected to.
  - Starting a cast started the track from the beginning, and taking it
    back from the device started it over here. Both go on from where the
    track was.
  - A cast that failed said nothing. A message above the output button
    now says why: the device could not be reached, did not answer, could
    not play the track or lost the connection. "Connecting" no longer
    stays up for a device that cannot be reached.
  - A cast ended on the device, or taken over by another app, ends here as
    well, with a short notice.
  - The end of a track on the device could skip several tracks at once.
  - Picking another device while casting left the first cast half-ended.
    The cast now moves to the new device and goes on from where it was.
  - A track that Tidal has only in AAC can be cast, and casting follows the
    streaming quality setting.
- Escape closes the open dialog, menu or output picker and nothing else.
  In 0.4.2 it also left the page.
- Space after a click on a Collection tab typed into the search field
  instead of pausing.
- Going to Search selects the last query, so typing replaces it, and its
  results stay until the new query is answered.
- A failed search says that Tidal could not answer, with Try again. 0.4.2
  showed Qt's own error message.
- A Collection search that finds nothing says so. 0.4.2 showed the empty
  collection's text. The Mixes tab ignored the search field, and the sort
  words did nothing on the Playlists tab.
- Home's mixes row said nothing when the mixes could not be loaded. It now
  says so, with Try again. The playlists row no longer reshuffles as it
  loads.
- An artist page never showed Related artists. An artist's biography showed
  "<br/>" as text and ran across the whole page. It is now set in
  paragraphs, with links to albums and other artists, and cut at four
  lines with Read more. The artist's name over the photo has no dark
  outline.
- Lengths of an hour or more read as 1:12:05. 0.4.2 wrote 72:05.
- The tray menu stayed in English after a switch to German, and offered
  Show and Hide at once.
- Audio files that a crash left in the temp folder are removed at the next
  start. Covers are kept in a disk cache, so a list scrolled back up does
  not download them again, and a cover scrolled past stops downloading.
- A long error, or the German text, ran out of the login card. The card
  now grows with its text, and the device code can be selected.
- With hardware acceleration off, icons scrolled out of view in Settings
  could stay drawn above the panel.
- The player bar moved its controls when the first track started.
- A click on a button, a switch or a theme tile in the Settings panel, once
  the panel was scrolled, also reached the page beneath it. With the albums
  of Collection behind Settings, a click on Check now could open an album.
- Synced lyrics that you scrolled follow the song again when the scroll
  ends with the sung line exactly back in the middle of the panel, or
  before the first line back at the top. 0.4.2 kept them still until
  Resync, a click on a line or the next track.
- Synced lyrics lit their first line from the start of the track, through
  the whole intro. No line is lit now until the first one is sung.
- Lyrics that Tidal sent late for the track before no longer replace those
  of the track now playing.

### Removed

- The popularity percentage beside search results, which had no label.

### Known issues

- Gapless playback and crossfade need Qt 6.5, and a lossless track starts
  before its download ends only with Qt 6.6. The .deb on Debian 12 and
  Ubuntu 24.04 uses their Qt 6.4, so there tracks change with a short gap
  and a lossless track waits for its whole file, as in 0.4.2.
- Search results still list each quality of a record on its own. Only an
  explicit and a clean version are folded into one, by the new setting.
- The other known issues listed under 0.4.2 are unchanged.

## [0.4.2] - 2026-10-17

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
  artists looked at, the 1140 entries of their own releases became 604 cards.
- Cards of one title in one row of an artist page say what tells them apart:
  the year and the number of tracks, or the number of tracks and Dolby Atmos
  for a release Tidal has in Dolby Atmos only, and the length where these
  agree as well. Tidal keeps such records apart too, for instance a Dolby
  Atmos version with a track list of its own. 0.4.1 showed the year alone.
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
- After a seek, a pause or the play that followed it showed the track as
  loading: the play button turned into three dots and stayed so, while the
  track was paused and while it played. This happened with Qt 6.6.2 to
  6.11.1, which the .deb packages for Debian 13, Ubuntu 25.10 and 26.04 and
  the Windows zip of 0.4.1 use.

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

[0.5.0]: https://github.com/immineal/tidal-wave/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/immineal/tidal-wave/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/immineal/tidal-wave/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/immineal/tidal-wave/compare/v0.3.1...v0.4.0
