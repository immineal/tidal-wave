# Changelog

Notable changes to Tidal Wave, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Tidal Wave is an
application rather than a library, so the version numbers are release
milestones and not a semver promise about an API.

## [0.5.0] - 2026-11-18

The biggest release so far, so this section is sorted by topic. Where something
works differently now, the entry says what 0.4.2 did.

### Playback

- Gapless playback. The next track starts the moment the last one ends. If its
  file isn't ready in time, you get the short pause 0.4.2 always had. Needs Qt
  6.5 or newer.
- Normalise loudness, in Settings > Playback and on by default, plays each
  track at the loudness Tidal measured for it. An album played in order from
  its page keeps the balance between its tracks. No track is raised past its
  peak.
- Crossfade, in Settings > Playback and off by default, from 1 to 12 seconds.
  Tracks that follow each other on an album played in order still join without
  a gap, and a skip changes at once. Needs Qt 6.5 or newer.
- Autoplay similar tracks, in Settings > Playback and off by default. When the
  queue runs out, the last track's radio is added to it, minus tracks already
  there, and playback carries on. Nothing is added while repeat is on or while
  you cast.
- Lossless tracks start as soon as the first part has arrived, on Qt 6.6 or
  newer. 0.4.2 waited for the whole file.
- The quality badge shows the format of the stream, such as "24-bit / 96 kHz
  FLAC" or "AAC 320 kbps". Now playing puts the tier in front: "Max · 24-bit /
  96 kHz FLAC". 0.4.2 showed the tier alone.
- A new setting in Settings > Playback picks Explicit (the default) or Clean.
  Search, artist pages and Tidal's rows on Home show that version of a record
  when both exist. Records you saved show as they are. The other version is
  listed under Other versions on the album page.
- Next under repeat one moves on to the next track. 0.4.2 started the same one
  again.
- Shuffle on a page plays the track you picked first, then the rest of the
  album or playlist in random order. 0.4.2 left out the tracks above the one
  you picked.
- A click on the playing track pauses or resumes it. 0.4.2 started it over.
  The track stays marked while paused.
- The queue restored at start downloads nothing until you press Play, and
  nothing is fetched ahead while you are paused. 0.4.2 downloaded the restored
  track at every start.
- Pressing Next or Previous several times in a row loads only the track you
  stop on.
- The whole queue is kept between sessions. 0.4.2 kept 50 tracks before the
  current one and up to 650 after it.
- The volume slider follows how loud things sound, so its lower half is no
  longer close to silent. Your saved volume sounds the same as before.
- Stop from a desktop media widget stops the track, and Play then starts it
  from the beginning. 0.4.2 paused.
- Removing the playing track from the end of the queue stops playback. 0.4.2
  went back and played the track before it.
- While a track loads, the seek bar shows its length. 0.4.2 showed the previous
  track's.
- If the sound system stops taking the audio, playback picks up again after a
  few seconds. With Qt 6.5 or newer, 0.4.2 stayed frozen.
  After such a recovery, the next track change has a short gap.

### Lyrics

- If Tidal has no synced lyrics for a track, the app looks for them on LRCLIB.
  This is on by default. Turn on Lyrics from more sites and it also asks
  NetEase Cloud Music, KuGou and Genius. Both switches live in a new
  Experimental section of Settings.
  - The first site with synced lyrics is used. Tidal's plain lyrics stay on
    screen while the sites are asked.
  - The source is named under the lyrics, and a click opens it. Tracks that
    LRCLIB or NetEase know as instrumentals say Instrumental.
  - Each site gets at most one request a second. Lyrics that are found are
    kept on disk. A track with only plain lyrics, or none, is looked up again
    after 30 days.
  - The privacy notice in Settings and the README say what each site receives.
    Two of them are servers in China.
- Sync plain lyrics automatically, on by default, times plain lyrics against
  the track's audio on your computer. Nothing is sent anywhere. It runs in the
  background at low priority, and works ahead on the next track while the
  lyrics are open. Lines it isn't sure of get no timing, and the result is
  marked "Synced automatically, may be off". Real synced lyrics always come
  first.
- Plain lyrics that don't fit the panel get a scroll bar you can drag.
- Lyrics open in place of the artwork, and the rest of now playing stays put.
  In 0.4.2 they shifted the page and pushed Up next down.
- Once you have scrolled synced lyrics, they follow the song again when you
  bring the sung line back to the middle, or the top before the first line.
  0.4.2 waited for Resync, a click on a line or the next track.
- No line lights up before the first one is sung. 0.4.2 lit the first line
  through the whole intro.
- Lyrics that arrive late for the previous track no longer replace the current
  track's.

### Scrobbling

- A new Scrobbling section in Settings sends what you play to ListenBrainz,
  Last.fm or both. Both are off until you connect an account.
  - ListenBrainz needs the user token from your ListenBrainz settings page.
    Last.fm signs in through its website: Connect with Last.fm, then I've
    allowed access.
  - A track counts once half of it or 4 minutes has played, and only if it is
    longer than 30 seconds. Time skipped by seeking doesn't count. Casting
    counts like playing here.
  - Listens are kept on disk until the service accepts them, so quitting or
    losing the connection loses none. Disconnect keeps unsent listens for
    when you connect the same account again. Discard deletes them. Logging out
    of Tidal disconnects both services.
  - The privacy notice in Settings and the README say what each service
    receives.

### Playlists and your collection

- Ctrl+Z, or Undo on the notice above the player bar, takes back your last
  change, up to ten steps: likes, saved albums and mixes, followed artists,
  tracks added to or removed from a playlist, a reordered playlist and a
  cleared queue. The app checks each change with Tidal before calling it done.
  A change Tidal doesn't show is reported as not confirmed, without Undo.
  Deleting a playlist can't be undone.
- Delete a playlist you made with Delete playlist… in its sidebar menu or
  Delete in its Edit dialog. Both ask first.
- Reorder a playlist you made by dragging its tracks, while it is in its own
  order and unfiltered. The row stays put, a line shows where it will land and
  a chip with the title follows the pointer. Escape cancels.
- Drag a track from any list onto one of your playlists in the sidebar, or
  into the queue. Hold it over the queue button to open the queue and drop it
  between two rows, or let go on the button to add it at the end.
- Add a whole album, playlist or mix to a playlist from the menu in its header
  or on its card.
- The Add to playlist picker has a search field and ticks the playlists that
  already hold the track.
- Adding a track that a playlist already holds asks first ("Already in …").
  0.4.2 added a second copy without a word.
- New playlist opens the playlist it makes, from the sidebar, Collection or
  the picker.
- Remove from playlist works. 0.4.2 sent a request that Tidal always refused,
  and the track stayed. If the playlist was changed on another device in the
  meantime, it is loaded again and nothing is removed.
- Add to playlist, Edit and Remove from playlist appear only on playlists you
  made. 0.4.2 offered them on other people's playlists too, and Tidal refused
  the change.
- Download a whole album or playlist from its header. Tracks are saved one by
  one as FLAC into a folder named after it, at least 20 seconds apart to stay
  within Tidal's limits. The button turns into Cancel while it runs. Tracks
  already in the folder are skipped, so a cancelled download picks up where it
  stopped.
- Settings > Playback has a Download folder. After a download, the row's tick
  and Show in folder open your file manager at the file. A failed download
  says why in a tool tip. 0.4.2 only turned the button red.
- Find in this playlist… narrows a playlist to tracks whose title, artists or
  album match what you type.
- Liked tracks, playlists, mixes and track radios have column headings: #,
  Title, Album, Date added and Length. Click one to sort, again to reverse,
  and a third time for the list's own order. The headings stay in view as you
  scroll. Albums have the headings too, without sorting.
- Track rows show a heart on liked tracks and an outline heart under the
  pointer on the rest. Click it to like or unlike. Explicit tracks carry an
  "E", the version follows the title, as in "(Live)", and the album name
  opens the album.
- Copy link in the menus of albums, playlists, artists and mixes. Their pages
  have a More button that opens the same menu.
- Album cards link their artists, and their menu has Go to artist.
- Collection has Surprise me, which opens a random album, artist, playlist or
  mix from those shown, and Shuffle on the Tracks tab. Both respect the search
  field and the sort.
- Saved albums can be sorted by Artist or Year.
- A mouse drag on a track row picks up the track. Scroll lists with the wheel,
  the scroll bar or a finger.
- Likes, saved albums and artists, playlists and saved mixes changed on
  another device show up in a running app. It checks when the window gets the
  focus back, at most once a minute, and every five minutes while it is open,
  with one small request per list. 0.4.2 read your collection only at sign-in.
- Long lists of liked tracks, albums and artists no longer lose items. 0.4.2
  read them in pages, and Tidal's ordering made some fall between pages. Those
  tracks were missing from Collection and showed an empty heart.
- Liked tracks are listed newest first. 0.4.2 showed the oldest 100 until the
  whole list had arrived.
- The sidebar's library and its search know all your liked tracks. In 0.4.2
  they often stopped after the first few dozen, and never went past 5000.
- While your collection loads, it says so. 0.4.2 showed "No saved tracks" and
  "(0)" until the lists arrived.
- A Collection search that finds nothing says so. The Mixes tab follows the
  search field now, and the sort works on the Playlists tab.
- Collection's search field ignores accents and stray spaces, like the one in
  the sidebar.
- Space after a click on a Collection tab plays or pauses. In 0.4.2 it typed
  into the search field.
- When Tidal can't be reached, a strip above the page says so, with Try now,
  and the app keeps trying. Your collection shows as it was last saved on this
  computer. 0.4.2 started offline with an empty library.

### Home, search and pages

- Home shows the rows from Tidal's own apps around your own, in two tabs, For
  you and Staff picks. Row names come in the app's language.
- Recently played on Home lists the albums, playlists, mixes and artists you
  played lately on any device. What you play in this app is added here and
  never sent to Tidal.
- Under the greeting, Home shows the current track with a button to play it.
- Artist pages have Artist radio, where Tidal has one, and Shuffle.
- Search leads with Tidal's top result on the All tab. Recent searches appear
  under the field.
- Going to Search selects your last query, so typing replaces it. The old
  results stay until the new ones arrive.
- Track radio pages have a proper header with Play and Shuffle.
- Albums with more than one disc number each disc from 1, under its own
  heading. 0.4.2 numbered straight through.
- Back returns to the last five pages as you left them, scrolled and loaded.
  Collection remembers its place on each tab.
- Card rows scroll a card at a time with the arrows at their edges, a sideways
  drag, or a horizontal wheel or swipe. 0.4.2 had only Shift+wheel and the
  scroll bar.
- Pages that fail to load offer Try again, and say when Tidal can't be
  reached.
- A failed search says Tidal couldn't answer and offers Try again. 0.4.2 showed
  Qt's own error message.
- Home's mixes row says when it couldn't load, with Try again. The playlists
  row no longer reshuffles while it loads.
- Artist pages show Related artists. Biographies come in paragraphs with
  links, cut at four lines with Read more. 0.4.2 printed "<br/>" as text. The
  artist's name over the photo has lost its dark outline.
- Lengths of an hour or more read as 1:12:05. 0.4.2 wrote 72:05.

### The queue

- Every track still to come can be dragged, within its part of the queue or
  across into the other. 0.4.2 let you move only tracks you had queued by
  hand. The row stays put while you drag, a chip with the title follows the
  pointer, and Escape cancels.
- Every row has a menu with Play next, Add to playlist, Go to album, Go to
  artist and, for tracks still to come, Remove from queue. 0.4.2 offered only
  Remove from queue, and only on tracks queued by hand.
- The queue has a close button and takes the keyboard while it is open.
- Its first part is headed "Earlier in queue". 0.4.2 said "Played", even for
  tracks you skipped.

### Casting

- A Chromecast that stops responding no longer freezes the app, and stopping
  a cast is instant.
- Each track is served at a random address that only the cast device is
  given. In 0.4.2 anything on your network could fetch it.
- The device gets an address it can reach on computers with Docker, a VPN or
  a virtual machine network. Devices that also answer over IPv6 connect.
- A cast starts where the track was, and taking it back carries on here from
  the same point. 0.4.2 started the track over both times.
- A failed cast says why above the output button. "Connecting" no longer hangs
  for a device that can't be reached.
- A cast ended on the device, or taken over by another app, ends here too,
  with a short notice.
- The end of a track on the device no longer skips several tracks.
- Picking another device while casting moves the cast there and carries on
  from the same point.
- Tracks that Tidal has only in AAC can be cast, and casting follows your
  streaming quality setting.

### Desktop

- The tray menu has Previous track, Play or Pause and Next track, and the tray
  icon's tool tip names the playing track. The menu follows a change of
  language, and no longer offers Show and Hide at the same time.
- `tidal-wave --play-pause`, `--next` and `--previous` control the running
  app. `--help` and `--version` print and exit.
- Tidal links open in the app: tidal://, tidal.com and listen.tidal.com, from
  the command line, your desktop's link handler, a drop on the window, a paste
  into Search or MPRIS. A track link opens its album.
- The desktop entry opens tidal:// links and has Play/Pause, Next Track and
  Previous Track in the launcher's menu.
- Desktop media widgets (MPRIS) can list the queue and jump to a track in it.
- On Windows and macOS the media keys work, and the system's now playing panel
  shows the track.
- An optional notification when a new track starts, in Settings > Window and
  off by default. It stays away while the window is in front.
- The window opens at the size and place you left it, maximised if it was, on
  the page it showed. 0.4.2 opened at 1280 by 800 on Home.
- Reduce motion in Settings > Appearance: As the system says, On or Off. The
  system setting is now read on Windows and macOS too.
- The mouse wheel over the volume changes it. A running sleep timer shows the
  time left in the player bar, and a click opens now playing.
- On Linux the session file follows `$XDG_CONFIG_HOME`. On macOS it moves to
  `~/Library/Application Support/TidalWave/Tidal Wave`, and the old file is
  read once and removed. A crash can no longer leave it half written.

### Keyboard and screen readers

- Screen readers can find, name and press buttons, sliders, tabs, switches,
  cards and rows.
- A track list, the sidebar's library, a row of cards and the queue are one
  tab stop each. Inside, use the arrow keys, Home and End. Enter plays, and
  the Menu key or Shift+F10 opens the row's menu. 0.4.2 made every row and
  every artist name a tab stop.
- The seek bar, the volume and the sleep timer work from the keyboard. So do
  controls that used to answer only the mouse: Collection's sort words,
  Playing from, the Lyrics and Credits chips, Show all, a card's play button
  and the rows of the playlist picker.
- Escape closes the open dialog, menu or output picker and does nothing else.
  0.4.2 also left the page.
- Escape in a search field clears it, and in an empty one hands the keyboard
  back.
- Small buttons, such as the clear and close crosses, respond to clicks over
  at least 32 by 32 pixels.
- New shortcuts: Ctrl+F and Ctrl+L go to search, Ctrl+N makes a new playlist,
  Ctrl+Z undoes, Ctrl+Q quits, and Alt+Shift+B likes or unlikes the playing
  track.
- Shortcuts that moved: seek with Shift+Left and Shift+Right, change the
  volume with Ctrl+Up and Ctrl+Down, open now playing with Ctrl+4. In 0.4.2
  the bare arrow keys seeked and changed the volume, and Ctrl+N opened now
  playing. Space presses the control the keyboard is on, and plays or pauses
  everywhere else.

### Look and wording

- Album, artist, playlist, mix and radio pages share one layout, with a header
  tinted from the cover.
- A card under the pointer dims its cover behind a white play symbol. Pages
  load behind a placeholder in their own shape, where 0.4.2 showed a spinner.
- Confirmations appear as one notice above the player bar. Tool tips and
  scroll bars take the theme's colours.
- Menus are grouped, with Remove from playlist last, and the row a menu
  belongs to stays marked.
- A missing cover shows a symbol. Playlist mosaics use four different covers,
  or one when there are fewer.
- While a track loads, the play button shows a spinning ring. 0.4.2 showed
  three dots in the player bar.
- The playing bars stay sharp at every screen scale, and the player bar's
  controls no longer jump when the first track starts.
- Settings, the playlist dialogs and the playlist picker dim the app behind
  them.
- Follow on artist pages has a person icon. 0.4.2 used the heart from Like.
- Collection's sort options are plain words, the chosen one bold and
  underlined, and the chosen tab is bold. A saved album's Saved button is
  outlined.
- Settings is rows under small headings, with Account at the top, a new Window
  section and the version under About at the end. The long privacy notes fold
  behind Details. Settings opens at the top each time and scrolls by your
  desktop's lines per wheel notch.
- Log out sits next to your account name at the top of Settings and asks
  first. It stops playback, empties the queue and disconnects scrobbling. In
  0.4.2 it was at the bottom of the panel, and the music kept playing.
- A click in a scrolled Settings panel no longer reaches the page beneath it,
  and with hardware acceleration off, icons scrolled out of Settings no longer
  stay drawn over the panel.
- In now playing, fullscreen artwork grows with the window (0.4.2 stopped at
  420 pixels), a long title gets two lines, and with nothing loaded it says "No
  track playing". Yellow covers tint the page more gently on the dark themes.
- Themes: Sky has a new blue (#0074B5) and red (#C51B32). Sand's background is
  a warm paper and Clay's a light blush. Rust's and Clay's accents sit further
  from the red used for errors. Sea and Pine have new greens for lossless. On
  the dark themes, quiet text such as track numbers and lengths is lighter and
  easier to read, and so is accent text. The rainbow behind "Let the colour
  in" now looks like glass.
- Labels are in sentence case. The English says track, collection, Log in and
  Show all throughout, says My for your own things (My mixes, My playlists, My
  account) and spells Favourite with a u. German says Sammlung everywhere, and
  several Settings lines read more naturally.
- Numbers follow the language picked in the app. 0.4.2 followed the system's.
- Playing from names a search, as in search "…", and takes you back to it.
- The login card grows to fit a long error or the German text, and the device
  code can be selected.
- The software centre screenshots show real records whose covers are under
  free licences. CREDITS.md lists them.

### Speed and reliability

- Much faster with a large collection: typing in Collection's search field,
  opening a long playlist or the queue, switching Search's tabs and scrolling
  long lists. Covers are cached on disk, and a cover you scroll past stops
  downloading.
- A busy or failing Tidal login server no longer signs you out. 0.4.2 ended
  the session on any error while renewing it.
- A saved session signs in once at start. 0.4.2 signed in twice and loaded
  your whole collection twice.
- Signing out while the account name was still loading could write the
  session file again. It no longer does.
- When Tidal says the app is asking too often, it waits as long as Tidal asks.
  0.4.2 asked again at once, which kept the limit in place.
- Audio files left in the temp folder by a crash are removed at the next
  start.
- On Qt 6.8 and newer the app runs Qt's garbage collector in whole passes, to
  avoid a crash in its incremental mode. A `QV4_GC_TIMELIMIT` you set yourself
  is left alone.
- The .deb is built against Qt 6.4 and now follows the Qt it runs on. On
  Debian 13 and Ubuntu 26.04 it has gapless playback, crossfade, the quick
  start of lossless tracks and the newer Qt's fixes, which it skipped before
  as if it ran on Qt 6.4.

### Removed

- The unlabelled popularity percentage next to search results.

### Known issues

- Gapless playback and crossfade need Qt 6.5, and the quick start of lossless
  tracks needs Qt 6.6. The .deb on Debian 12 and Ubuntu 24.04 uses their Qt
  6.4, so there tracks change with a short pause and lossless tracks wait for
  the whole file, as in 0.4.2. The AppImage includes a newer Qt.
- Search still lists each quality of a record separately. Only the explicit
  and clean versions are combined, by the new setting.
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
