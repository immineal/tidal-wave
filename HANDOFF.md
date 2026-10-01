# Tidal Wave 0.4.0 handoff

Everything the user asked for across one long session, what is already done, and
what is left. Delete this file before merging `beta-0.4.0` into `main`.

**Branch:** `beta-0.4.0`, pushed, tracking `origin/beta-0.4.0`. Commit
regularly; merge to `main` only when the whole list is done and the user has
approved it. `main` is untouched.
**Environment:** KDE Plasma, **Wayland** (`XDG_SESSION_TYPE=wayland`), X11 also
supported. Two 1920x1200 monitors, so half-screen is **960x1200**, and that is
the width everything must look right at.

**Last verified against the code:** 2026-10-01, at `0f39a77`.

**Design review page (the user reviews design here, keep it current):**
https://claude.ai/artifact/AkdWsw9NekmW8py6eBZtU3
Source: `docs/design-review.html`. Edit it and republish to that same URL with the
Artifact tool (pass the URL as `url`, after reading it first).

**The spec:** `docs/SPEC-0.4.0.md` is the record of what was asked for. Its
requirements are deliberately frozen; each section there carries a Status line
that should agree with this file.

## Final state, end of the 2026-10-01 session

22 commits past the handoff, pushed to `origin/beta-0.4.0`. 13 test binaries,
all green. **Not merged to `main`: that still needs the user's approval.**

Landed after the docs pass above, so the section list does not mention them:
the Settings panel (theme, language, audio device, hardware acceleration,
update switch, privacy block), reduced motion across all 24 animation sites,
the startup fixes (single-instance socket, proxy, no-tray quit, audio-server
noise), the dead `Qt6::Sql` dependency removed, and `tests/visual/`.

### Bugs found by testing rather than by reading
- **Theme switching was entirely dead.** `ThemePalette` was default-
  constructible, so Qt never called `create()` and QML built its own instance
  with a null `Prefs`. All six palettes painted as Sea. See
  `tests/qml/tst_theme_live.qml`.
- **Every label on an accent fill was black.** A QML property named
  `on<Name>` beside a property `<name>` parses as a signal handler, so
  `Theme.onAccent` never bound. Tokens are `accentInk` / `redInk` / `artInk`
  now. Found by screenshots; 13 green test binaries did not catch it.
- **The `.deb` could not start at all**: `qml6-module-qtquick-shapes` was
  never in the depends, and QML modules are dlopen'd so shlibdeps cannot
  infer them.
- The Settings popup was 156px wide (`anchors.centerIn: Overlay.overlay`
  positions without reparenting). A 5000-track queue cost 326ms per advance.
  `undefined === undefined` lit every row as playing. The single-instance
  lock failed silently under a long `TMPDIR`.

### Still open, and why
- **The `.deb` has never been installed on a real Debian box.** This machine
  is openSUSE with no dpkg. The dependency list is derived from `ldd`, the
  QML imports and a mount-namespace reproduction. **Verify before release.**
- **The audio backend matrix (A4) is unexercised**: PipeWire, PulseAudio and
  ALSA, hot-plug and removal of the active device, all need real hardware.
- `tests/stress/` and `tests/visual/` are standalone CMake projects run by
  hand, deliberately not in ctest. Two stress cases are worth wiring in; the
  note is in `tests/stress/`.
- `NowPlayingPage` still reaches into `Window.window` for sleep-timer state,
  so the page is not independently testable.
- `CollectionPage`'s album and artist delegates have their own right-click
  menu that shadows the shared Pin menu.
- The hero eyebrow on Album, Playlist and Mix sits on `accentTint`; it was
  moved to `textSec`, but check it by eye on the light themes.

### Open questions for the user
- The two light themes have now been seen running (screenshots in
  `tests/visual/out/`), but nobody has used them for real work.
- ~~Theme names are translated: Midnight becomes Mitternacht, Forest becomes
  Wald.~~ **Answered.** They are product names now and show as written in every
  language, and the six were renamed to Sea, Pine, Rust, Sky, Sand and Clay.
  Deep is still gone, replaced by the pure-black switch; a settings file that
  names it, or any of the old six, migrates on load in `theme::migrated()`.


## Queued from QA, not yet started

Decided with the user, waiting on the in-flight icon sweep to land first.

1. **One output picker, replacing the cast button.** The player bar's cast
   button becomes an output button listing this computer's audio devices and
   any Chromecast targets in one menu. The icon is the speaker normally and
   the cast glyph while casting, so the bar shows at a glance that audio is
   leaving the machine. Same picker in Now Playing where there is room.
2. **Volume on hover.** At the widths where the bar sheds the slider you can
   only mute. Hovering the speaker should reveal the slider so it is still
   adjustable, the way most players handle it.
3. **The up-arrow moves to the left of the queue button**, grouping the two
   "open a view" controls and getting it away from Like, which acts on the
   track rather than opening anything.
4. **Drop the words "Now Playing" from the page header.** The chevron and the
   fullscreen button stay; the page is obviously the player, and the German
   reads badly.
5. **Redraw the cast glyph.** The two waves at the bottom left want to be
   bigger, with more space between them and the screen lines, scaled so they
   match the top line.
6. **`Lossless (FLAC)` becomes `Lossless (16-bit)`**, which pairs with
   `Hi-Res (24-bit)`. Tidal's lossless tier is CD quality, 16-bit/44.1kHz, not
   the 12-bit that was guessed.
7. **One now-playing indicator**, in the queue and in the track rows, where
   album and playlist currently show a music note instead.
   **Decided: four or five bars, not three, and animated** like an equaliser.
   Two things follow from that:
   - It must **sit on a baseline**, where the track waveform is symmetric
     about a centre line. With 5 bars against 7 the animation carries most of
     the distinction, so under reduced motion that structural difference is
     the only thing left telling them apart. Park it at a recognisable static
     shape rather than letting it vanish, the way the spinners do.
   - Cost is not a concern despite the 5000-row stress case: exactly one row
     is ever playing, so there is only ever one animated indicator alive.
8. **Retire the beamed-note glyph entirely.** `VectorIcon`'s `music` is a
   pair of beamed eighth notes, which is Western staff notation rather than a
   universal symbol for audio, and the user does not want it anywhere. Ten
   call sites: `MediaCard`, `TrackRow`, `SideBar`, `CollectionPage` (three
   empty states), `SettingsPanel`, `LibraryFinder`'s Tracks chip, `MixPage`,
   and the case in `VectorIcon` itself.
   **One replacement does not serve all ten.** The note was standing in for
   four different meanings, which is part of why it read badly:
   - **"a track"**, only two sites: the sidebar's type badge
     (`SideBar.qml:630`) and the Tracks filter chip (`LibraryFinder.qml:181`).
     **Decided: a short waveform strip**, seven thin bars of varying height,
     **symmetric about a centre line**, like a rendered audio file.
   - **"nothing here yet"**, the three `CollectionPage` empty states, which
     currently all show a note under "No playlists yet", "No mixes" and "No
     saved albums". Each should show its own type glyph: `playlist`, `mix`,
     `album`. A note says nothing there.
   - **"no artwork"**, the `MediaCard` and `MixPage` placeholders. These
     already know the item's type, so they should fall back to that type's
     glyph.
   - **an avatar stand-in**, `SettingsPanel.qml:263`. Not music at all, and it
     disappears anyway once the footer rework drops the avatar and the
     Settings restructure moves that row.

### Home page, reported during manual QA, in flight

9. **The home rows never refreshed.** `HomePage` lives in a `Loader` that is
   never torn down and filled its rows once, in `Component.onCompleted`, so an
   album saved from its own page was missing from Saved Albums until the app
   was restarted. It now listens to the bridge's `favoriteAlbumsChanged` /
   `favoriteArtistsChanged` / `favoritePlaylistsChanged` and rebuilds the three
   favourite rows from the in-memory favourites copy the bridge already pages in
   at login, debounced through a 120ms timer because each kind emits twice while
   its pages land and saving one album emits twice more. Reading that copy rather
   than re-fetching is also what makes home and Collection agree: Collection has
   always read it. Done; `tests/qml/tst_home_rows.qml` covers it.
10. **One gap on home was double every other.** Two leftover 32px spacers sat
   where the dropped Recently Played row used to be, so Mixes to Saved Albums
   was 64 where Saved Albums to Your Playlists was 32. All gaps are 32 now.
   Every spacer on the page also declares `Layout.preferredHeight`, since a
   `ColumnLayout` reads that and not a plain `height`, and each gap above a row
   that can be empty is hidden with that row - otherwise a user with no
   playlists got that row's gap twice. Done.
11. **Playlists sort by recency of any interaction, not just plays.**
   `sortPlaylists` ordered by a locally stored last-played time, descending,
   stable, so a never-played playlist kept API order and a playlist the user had
   just created landed behind everything they had ever played. The key is now
   `max(localLastPlayed, addedAt)`: creating one and saving someone else's both
   count, so a new playlist sorts to the front and playing an old one brings it
   back. `addedAt` has to come from the favourites wrapper's `created` (when
   *this* user added it) rather than the playlist's own, which for a saved
   playlist is the original author's date. Done, and it turned up a second bug
   on the way: `TidalClient::parsePlaylists` unwrapped each favourites row and
   threw the row away, so the wrapper's date was never reachable at all.
   `tests/tst_playlist_order.cpp`, 12 cases.
12. **The library cover's hover and pin ring was invisible on any row that had
   artwork.** It was the cover Rectangle's own `border`, and a Rectangle paints
   its border under its own children while the `Image` fills the whole box, so
   the ring was painted and then covered over. It is now a child drawn after the
   art. `tst_sidebar.qml` asserts the paint order, not just the width, since a
   width assertion is exactly what failed to catch this.
13. **The black bar when the rail expands.** Reported as "it reserves its space
   and for a few milliseconds there's a black bar where it will expand to". The
   layout reserves the full expanded width the instant `compact` goes false,
   while the panel spent 170ms animating into that slot, and the difference
   painted the page ground. The slide is now held to the compact case: going
   wide snaps, so the panel arrives with its slot, and going narrow still
   animates because there the panel is *wider* than its slot and overflows over
   the page the way the hover overlay does. This was the prerequisite the user
   set for any further animation work.
14. **German catalogue topped up** after the icon pass re-keyed four strings.
   `Audio output` → Audioausgabe, `Lossless (16-bit)` → Lossless (16 Bit),
   `View all` → Alle anzeigen, `Resync` → Sync. German is at 293 of 293
   finished. The user decided to keep `Jetzt läuft` for Now Playing after all,
   so the five shipped entries that use it stand.

## Animation, after measuring

The user wants the sidebar's transition quality elsewhere, but only where it
is genuinely cheap, and **only where something rearranges**, not during
continuous resizing. Candidates are the breakpoints that currently snap: Now
Playing stacking at 1000, TrackRow dropping columns at 640 and 560, the player
bar shedding controls at 720, Collection moving its search field.

**Fix first:** expanding the rail paints a black bar where the panel will
reach, for a few frames, before the content fills it. The rail is supposed to
overlay the page, so nothing should reserve that space at all.

**Measure before adding.** Only the nested-Wayland run gives honest frame
timing; offscreen and Xvfb numbers are throughput. Note `QQuickShape` ignores
an ancestor's `clip` in Qt 6.12, so any reveal-by-clipping animation will hit
the same wall the sidebar's finder did.


## Build and test

```bash
cmake -B build-t -S . -DCMAKE_BUILD_TYPE=Debug -DTIDALWAVE_BUILD_TESTS=ON \
      -DCMAKE_PREFIX_PATH=/home/linus/Qt/6.12.0/gcc_64
cmake --build build-t --parallel 8
QT_QPA_PLATFORM=offscreen /usr/bin/ctest --test-dir build-t --output-on-failure
```

- `CMAKE_PREFIX_PATH` is required: system Qt 6.11 ships `libQt6QuickTest.so` but
  no `Qt6QuickTest` CMake package. Use the 6.12.0 install, which is what CI uses.
- `/usr/bin/ctest` in full: `~/bin/ctest` is a broken Python shim.
- **Never** build into `./build` or `./build_custom`. Both are stale.
- **Never** `pkill` a `tidal-wave` process; the user's real instance is running.
  A second launch hits the `TidalWave-<uid>` lock, sends `show` and exits 0,
  which proves nothing. The lock is an absolute path: `$XDG_RUNTIME_DIR` first,
  then `$TMPDIR`, then `/tmp`, so isolate a test run with
  `XDG_RUNTIME_DIR=… TMPDIR=… HOME=… QT_QPA_PLATFORM=offscreen` - `TMPDIR` alone
  no longer moves it. `tests/lib/socket-name.sh` is the one place that derives
  the address, and the three `run.sh` harnesses source it.
- Tests glob `tests/tst_*.cpp`, one binary per file. Adding a test needs no
  CMake edit. QML tests live in `tests/qml/tst_*.qml`.
- `tests/TestStubs.h` fakes `auth`/`bridge`/`player`/`cast`/`app`/`downloader`
  so pages instantiate with no Tidal session. Known gap: `NowPlayingPage`
  reaches for sleep-timer state on `Window.window`, so it needs `Main` or a
  `Window` wrapper. Worth fixing by moving that state out of `Main.qml`.
- **`tests/stress/` is not part of `ctest` and not part of the main build.** It
  is a standalone CMake project that pulls the app in with `add_subdirectory`,
  built and driven by `tests/stress/run.sh`, which says so at the top of
  `tests/stress/CMakeLists.txt`. That is deliberate: the suite is long on
  purpose and must not slow the normal cycle down.
- `tests/firstrun/run.sh` is likewise a shell harness, not a ctest target.
  `tests/tst_firstrun.cpp` is in `ctest` and is a different, narrower thing.

## Ground rules the user set

1. **Write the unit tests first**, before the implementation they cover.
2. **No fully capitalised** user-facing strings, no `.toUpperCase()` on shown
   text. Caps-maxxing is both an AI tell and bad UI.
3. **No em dashes** in displayed strings. Use an **en dash** where a separator
   is genuinely wanted; rewrite asides instead.
4. **Corner radii**: the uniform `radius: 8` is the default AI look. Use a scale
   where the radius means something (the table is in the review page, and the
   scale now lives in `ThemePalette.cpp`).
5. **Ask via user prompts**, short questions, as many rounds as needed. Keep
   chat replies short, because the user does not read long ones.
6. Everything must work on **X11 and Wayland**, and still build on Windows and
   macOS (CI matrix).
7. **Use subagents** for work that can be isolated, to save context. Give each
   one a disjoint file set; never let two agents edit `CMakeLists.txt` at once.
8. **At most three concurrent subagents.** Six at once is what exhausted the
   budget earlier in this session. Dispatch three, wait, commit that batch, then
   dispatch the next three.

## Done

Scaffolding and infrastructure:

- `beta-0.4.0` branched and pushed; the user's prior offline-startup/auth fix
  (`47017b8`) and the Qt 6.12 CI change ship with this release.
- Test infrastructure: `tidalwave_qml` static library holds the QML module and
  all C++ except `main.cpp`, so tests link it. `TIDALWAVE_BUILD_TESTS=ON`
  builds `tests/`; CI runs `ctest` on Linux under offscreen.
- Version 0.4.0 in `CMakeLists.txt`, reaching QML through the
  `TIDALWAVE_VERSION` compile definition and `Prefs::appVersion()`. The
  Settings panel shows it (`SideBar.qml`, `objectName: "settingsVersion"`).
- `src/ui/Prefs.{h,cpp}`: theme, language, sidebar width, audio device,
  software rendering, all persisted, plus the layout constants
  (`railBreakpoint` 820, `railWidth` 68, `minSidebarWidth` 190,
  `maxSidebarWidth` 420). `chipLabelWidth` is gone, dropped in `2dbd1c9` when
  the user settled on icon-only chips. `minSidebarWidth` went 180 to 190 in QA:
  five 30px chips plus their insets want 166px of finder, the finder is the
  sidebar less 24, and at 180 the chips shrank during the last few pixels of a
  drag. The shrink formula is gone and `LibraryFinder`'s `chipWidth` is a
  constant again.
- New app mark: `assets/icon.svg` + `assets/icon.png`, one mark at every size,
  no separate tray asset. Icon set in `qml/components/VectorIcon.qml`: 15 new
  glyphs, `VectorIcon` supports a filled-accent and a stroked-overlay path,
  `user` was folded into `artist`.
- `qttools` is in the CI Qt modules in both `.github/workflows/ci.yml` and
  `release.yml`, so `lrelease` exists there and CI builds the catalogues.

**A. Themes.** Landed. `aab01a8` added `src/ui/ThemePalette.{h,cpp}` with the
palette table and the radius scale, and made `qml/Theme.qml` a binding layer
over `ThemePalette.current`. `2100153` moved every hardcoded colour in `qml/`
onto a token. `58811d6` fixed a real bug where switching the theme repainted
nothing. Six palettes, **three dark** (Sea, Pine, Rust) and three light (Sky,
Sand, Clay); the green dark one replaced the drafted violet "Graphite" at the
user's request, and all six were later renamed off their launch names.
`tests/tst_theme.cpp` checks WCAG contrast for every token
against bg/surface/surfaceHigh; `tests/qml/tst_theme_live.qml` covers the live
swap. Two findings kept: white on the accent fails contrast on all three dark
themes, so `onAccent` is near-black there, and `hoverFill` had to become
per-palette because `Qt.rgba(1,1,1,0.04)` is invisible on light.
**Still owed: the theme picker in Settings.**

**B. German translation.** Landed. `1b09cde` and `4d7600b` did the C++ side and
installed the translator; `55fb39d` and `19819ca` made the component and page
strings translatable; `bd1f91b` added the catalogue; `6407582` fixed English
rendering "14 track(s)"; `2dbd1c9` covered the strings the sidebar rebuild
added. `i18n/tidal-wave_de.ts` is at **zero** `type="unfinished"` across 252
messages, checked with `grep -c 'type="unfinished"' i18n/tidal-wave_de.ts`.
`src/ui/I18n.cpp` resolves the system locale (de_AT and de_CH find German,
untranslated locales fall back to English, `LANGUAGE=de:en` is consulted) and
retranslates live. Concatenated strings were restructured into `%1` forms and
counts go through `qsTr("%n …", "", n)`. Numbers, durations and percentages use
`toLocaleString(Qt.locale(), …)`.
**Still owed: the language picker in Settings.** Today the only way to pick one
is the `ui/language` key in the settings file.

**C. Responsive layout.** Landed in `8671b09`. `qml/Main.qml` is now
`minimumWidth: 640`, `minimumHeight: 600`. Every finding from the audit was
addressed: the Now Playing transport stacks, `CollectionPage`'s search moved to
its own row, `TrackRow` drops columns and reserves the hover buttons' space,
`PlayerBar`'s right group is fixed, `QueuePanel` got a scrim and a width clamp,
the Settings popup clamps to `min(480, w-64) x min(640, h-64)`, the hero headers
flow, and the grids derive their cell size. `tests/qml/tst_layout_pages.qml` and
`tst_layout_player.qml` instantiate pages at 640 / 820 / 960 / 1280.

**D and E. Sidebar rebuild, sizing and the compact rail.** Landed in `25221c4`
(the data layer, `src/api/LibraryIndex.cpp`, including the missing-playlists bug:
playlists are now paged rather than capped at 30) and `e2e326d` (the rebuild).
`qml/components/SideBar.qml` holds the flat library list, the pinned block, the
drag handle on the border and the rail; `qml/components/LibraryFinder.qml` holds
the search field and the type filter chips. The rail collapses below
`Prefs::railBreakpoint`, hover-expands as the same sidebar overlaying the
content, and has no manual toggle. Chips are **icons only at every width** and
sit inside the field's rounded container, which is the user's later decision and
differs from SPEC S8 as written. The footer shows the username with no avatar
(`dacc5f5`). Tests: `tests/qml/tst_sidebar.qml`, `tests/tst_library.cpp`.

**S9 is amended: the rail shows the whole library, not just the pins.** The
user reported the compact sidebar showing no covers at all. The cause was not a
drawing bug: the rail's model was `pins.items`, so it was correctly drawing
nothing for anyone who had not pinned anything, which is where everyone starts.
What they want is the type icon plus the name in the wide sidebar (which is
already what it does) and the cover alone in the rail. The rail's `ListView`
now takes `root.railRows`, which is `library.entries`: the same list, the same
order (pinned, recently played, A to Z). A row with no artwork falls back to
its type glyph on a plain tile, every cover has a tooltip with the name, the
pinned run keeps the break the wide list draws and each pinned cover keeps an
accent ring once that break has scrolled away, and a right-click gets the
shared Pin menu rather than Unpin alone. The cover hover handler is passive, so
the panel still hover-expands (L4).

It binds `library.entries` and not `root.rows` on purpose. The finder is hidden
in the rail, so a chip or a half-typed query left over from before the window
narrowed would quietly empty the rail with no visible control to explain it.

**S7, result expansion, was withdrawn in QA and the code is gone.** The user
saw the greyed, indented rows, asked what they were, and said to drop it: a
row only earns its place if the user typed that row's name. `search()` returns
direct title matches only; `expanded` / `expandedFrom` and the indent-and-grey
in the `LibraryRow` delegate are removed. The expansion was drawn and never
worded, so no entry in the German catalogue was orphaned by taking it out.

What replaced it is a real relevance order. Four terms, added up:

| term | values |
| --- | --- |
| where the query lands in the title | exact 400, prefix 300, word start 200, mid-word 100 |
| how much of the title it covers | up to 40, by `40 * query / title` |
| what kind of thing matched | artist 25, album 20, playlist 20, liked song 12, mix 10, a song known only from a saved album 0 |
| familiarity | pinned 30, played 15, neither 0 |

The three adjustments cannot reach 95, and the tiers are 100 apart, so a pin
reorders equals and never lifts a weak match over a strong one. Ties break on
most recently played, then A-Z, so the order never depends on fetch order. The
reasoning sits above `matchScore` in `src/api/LibraryIndex.cpp`.

**F. Pinning.** Landed in `0f39a77`. `src/ui/PinStore.cpp` persists per Tidal
user id; the pinned block sits above the library list with drag-to-reorder
(`SideBar.qml`, the `pinDrag*` properties); `qml/components/ContextMenu.qml`
carries the Pin menu, wired into `MediaCard` and the Album, Artist, Mix and
Playlist page headers. A pinned item appears only in the pinned block. Tests:
`tests/tst_pins.cpp`, `tests/qml/tst_pinning.qml`.
**One gap, listed under Still open: `CollectionPage`'s own right-click menus.**

**G. Navigation.** Landed in `e2e326d`. The Now Playing track title opens that
track's album; each artist in the player bar is its own hover target that opens
that artist (`PlayerBar.qml:64`). `tests/qml/tst_navigation.qml` covers it.

**H. Audio output.** Landed in `16c0e18`, with the `Player::setPrefs` wiring in
`Application::run()`. `Player` holds a `QMediaDevices`, re-resolves on
`audioOutputsChanged` and on `Prefs::audioDeviceChanged`, and rebinds through
`Player::rebindAudioOutput` while keeping position and play state. An empty
`prefs.audioDevice` means follow the system default. `tests/tst_audio.cpp`
covers it.
**Still owed: the audio output picker in Settings**, and a real-hardware pass
across PipeWire, PulseAudio and ALSA with hot-plug of the active device. Nothing
here has been exercised on real audio hardware.

**K. Update check and privacy notice.** Landed. The backend is
`src/ui/UpdateCheck.cpp` (`16c0e18`), the prompt is
`qml/components/UpdatePrompt.qml` (`0f39a77`), and the privacy notice is the
Privacy section at the bottom of `README.md`. It polls
`https://api.github.com/repos/immineal/tidal-wave/releases/latest` at most once
per 24 hours, caches to disk, and `Main.qml` calls
`updatePrompt.showIfAvailable()` once in `Component.onCompleted`, so the offer
lands at the next launch and never mid-session. The prompt lives on the window,
not on a page, so navigating cannot rebuild it. Buttons are Open release, Later
and Skip this version; **Escape behaves as Later, never Skip**, which was a
deliberate decision so a stray keypress cannot throw a release away
(`UpdatePrompt.qml:30`). The app never downloads or installs anything.

> **The QML name is `updateCheck`, not `update`.** Earlier drafts of this file
> said `update.enabled` and `update.checkNow()`. That name does not work, and it
> fails silently rather than loudly. `QQuickItem` and `QQuickWindow` both have
> an `update()` slot, and QML's unqualified lookup reaches the enclosing objects
> before it reaches the context properties, so under the `ApplicationWindow`,
> which is everywhere, a bare `update` resolves to that slot. No error is
> raised: `update.updateAvailable` simply reads `undefined`, so code written
> against the old name looks right and does nothing. `Application.cpp` registers
> the context property as `updateCheck`, and `Main.qml` and `UpdatePrompt.qml`
> already use that name.

The QML API is `updateCheck.updateAvailable` and `updateCheck.latestVersion`;
the three buttons are `app.openUrl(updateCheck.releaseUrl)`,
`updateCheck.remindLater()` and `updateCheck.skipThisVersion()`. The Settings
switch binds `updateCheck.enabled`, and a "check now" button calls
`updateCheck.checkNow()`, which skips the 24h throttle but still respects the
switch.
**Still owed, and in flight right now with another agent: the update switch in
the Settings panel, and the privacy block in Settings.** The notice is supposed
to live in two places and only the README half exists. Until the switch lands,
the only way to turn the check off is the `update/enabled` key, which is what
the README now says.

Both repo pointers are correct, checked: `kRepoSlug` is `"immineal/tidal-wave"`
at `src/ui/UpdateCheck.cpp:17`, and `CPACK_PACKAGE_HOMEPAGE_URL` is
`https://github.com/immineal/tidal-wave` in `CMakeLists.txt` (fixed in
`4fbebd2`).

**L. Hardware acceleration toggle.** The engine half landed in `15ef6e6`.
`Prefs::softwareRendering` is persisted as `ui/softwareRendering` and read in
`Application::run()` at lines 197 to 206, ahead of the engine, because Qt picks
the scene-graph backend before the first window exists. It skips the 4x
multisampling in the same breath, and an explicit `QT_QUICK_BACKEND` or
`QSG_RHI_BACKEND` wins over it. `tests/tst_prefs.cpp` covers the fresh-install
defaults.
**Still owed: the Settings toggle itself**, with the wording that it needs a
restart.

**M. First-run simulation.** The harness landed: `tests/firstrun/run.sh` runs
eleven scenarios (offscreen, software, xcb under a private Xvfb, nested
`kwin_wayland`, offline under `unshare -rn`, no-tray, corrupt settings, missing
QML, the single-instance handoff, the desktop file, and a dependency check), and
`tests/tst_firstrun.cpp` is in `ctest`. Fixed from its findings: the missing
`qml6-module-qtquick-shapes` dependency, `qt6-wayland`, the two unlisted Qt libs,
the em dash in the window title, and the dangling `Prefs*` in
`ThemePalette::setPrefs`. **Five findings are still open; they are listed below.**

**I. Stress and environment tests.** A harness landed in `0f39a77` at
`tests/stress/`: `run.sh` plus six QtQuickTest scenarios covering continuous
resize while navigating, rapid page flipping with RSS sampling, 5000-track
lists, simulated API errors and malformed payloads, theme and language switching
under load, and frame timing, across offscreen, software, xcb and wayland, plus
an idle run of the real binary in two themes. It is not wired into `ctest` on
purpose. **It has not been run to a clean result and nothing it found has been
fixed, so this section is not done.** See below.

## Still open

### J. Release. Not started, and must not start without approval.
- Merge `beta-0.4.0` into `main` only when complete **and** approved. Do not tag
  and do not push a tag without asking.
- Delete this file in that merge.

### The Settings panel. Done.
Built out since this was written, and this section is kept only to record what
was owed. The panel now carries Account, Appearance (theme picker, the pure-black
switch, language), Window (whether closing quits), Playback (streaming quality,
audio output), Performance (hardware acceleration), Updates (the automatic check
and a "check now" button), Keyboard shortcuts and Privacy. Nothing on the list
below is still only reachable by editing the settings file.

### What it was missing, for the record
`qml/components/SideBar.qml`'s Settings `Popup` currently has three sections:
Account, Playback (streaming quality) and Keyboard shortcuts. Everything else
that 0.4.0 added is reachable only by editing the settings file. Owed, in one
place:
- theme picker (A), language picker (B), audio output picker (H),
- hardware acceleration toggle with its restart notice (L),
- the update check switch and a "check now" button (K),
- the privacy block (K).

The update switch and the privacy block are being built right now by another
agent. Check what is on disk before starting any of the others.

### Stress harness findings, not yet fixed
Source: `tests/stress/`, read in full.
- **The suite has not been run to a clean result.** Run
  `tests/stress/run.sh --list` first, then `STRESS_SCALE=0.25
  tests/stress/run.sh` for a quick pass before the full one. Treat every
  number it prints as unverified until you have watched it run. Its safety
  rules match `tests/firstrun/run.sh`: private `HOME`/`TMPDIR`/`XDG_*` through
  `env -i`, no process-name matching, no synthetic input, everything under
  `timeout`.
- **`tst_stress_motion.qml` probes the wrong object.** Near its end it tests
  `prefs.reduceMotion` and concludes "the app has no reduced-motion control".
  There is no `reduceMotion` on `Prefs`. The real property is
  `Application::reducedMotion`, exposed to QML as `app.reducedMotion`, which is
  what `SideBar.qml:63` reads. The probe therefore always reports the gap,
  whether or not one exists. Fix the probe before trusting that line.
- The scenario the harness cannot answer is frame pacing. It says so itself:
  offscreen does not present, Xvfb rasterises through llvmpipe, a nested
  compositor adds a copy. It only catches an animation producing no frames, one
  far behind its neighbours, and a collapse under a big scene. Anything beyond
  that needs a real display.

### First-run findings
Source: `tests/firstrun/run.sh`. Four of the five were fixed later in the
same session that found them and this section went stale; each is marked with
where the fix lives, so a future reader does not go looking for a bug that is
not there. The fifth, the `.deb`, is below.
- ~~**`QLocalServer::listen()` failure is swallowed.**~~ **Fixed.** The failure
  is reported now, and `Application::singleInstanceSocketName()` picks the first
  of `XDG_RUNTIME_DIR`, `QDir::tempPath()` and `/tmp` whose path actually fits
  inside `sockaddr_un`'s 107 bytes, with the uid in the leaf name so a
  multi-user box gets one lock per user rather than one in total.
- ~~**Proxy settings are ignored entirely.**~~ **Fixed.**
  `QNetworkProxyFactory::setUseSystemConfiguration(true)` in
  `Application.cpp`. Note the caveat in the comment there: the Chromecast
  backend does its own HTTP and never sees `QNetworkProxy`.
- ~~**No tray plus close equals a vanished app.**~~ **Fixed.**
  `Application::shouldQuitOnWindowClose()` makes close a quit when no tray is
  available, and it is consulted from both `reallyQuit()` and the
  `lastWindowClosed` handler. The user has since asked for the *other* half of
  this to be a choice - close meaning quit even where a tray exists - which is
  being built now as a `Prefs` toggle in a new Settings "Window" section,
  defaulting to the current minimise-to-tray behaviour.
- ~~**PipeWire and PulseAudio connect errors print on every run**~~ **Fixed.**
  `Application::isAudioServerStartupNoise()` matches the stable half of both
  lines, and `audioServerAbsent()` gates the suppression so that it only applies
  where there is no audio server at all: someone running PipeWire who still
  cannot reach it has a real fault, and that one line is their only clue.
- **The `.deb` was tested on a real Debian box, and it is worse than predicted.**
  Debian 12 bookworm, RT kernel, no Qt6 installed. The package **installed
  cleanly** - 41 dependencies, no complaint - and then the binary died at load:
  `libQt6Core.so.6: version 'Qt_6.12' not found`, plus
  `libstdc++.so.6: version 'CXXABI_1.3.15' not found`.
  The version pin the README promised never existed.
  `CPACK_DEBIAN_PACKAGE_DEPENDS` was hand-written and unversioned, and
  `SHLIBDEPS ON` could not refine it: dpkg-shlibdeps attaches a floor by asking
  dpkg which package owns each linked library, and Qt here resolves to
  `~/Qt/6.12.0/gcc_64/lib`, which no apt package owns. With no owning package it
  silently contributes nothing, so the pin was absent on every build anyone
  makes here. **Fixed**: the depends list is now generated with a floor taken
  from `Qt6_VERSION`, plus a `libstdc++6` floor from the compiler major, and the
  README no longer claims a clean refusal it was not delivering.
  **Still open from that run**, and it is a release decision rather than a bug:
  the libstdc++ floor is an upper bound on what the binary needs, so a package
  built on this rolling distribution asks for a libstdc++ almost nobody has. A
  real release has to be built against the oldest toolchain we mean to support,
  in a container. Until that exists the `.deb` is only installable on a
  distribution as new as this build machine.
  Also outstanding: whether the declared `find_package(Qt6 6.4)` floor is real.
  The box is set up to try a source build against bookworm's 6.4.2, which is the
  only thing that can answer it.
- **`cpack` on PATH is a broken shim**, exactly like `ctest`: `~/bin/cpack` dies
  with `ModuleNotFoundError: No module named 'cmake'`. Use `/usr/bin/cpack`.

### Reduced motion. Done.
`Application::reducedMotion` is detected once at startup
(`detectReducedMotion()`), reaches QML as `app.reducedMotion`, and
`Theme.reduceMotion` is where the QML side asks. The cheap fix this section
proposed is the one that was built: a single `Theme.dur(ms)` token that collapses
to 0, so no `Behavior` has to know about `app`. **42 animation sites go through
it and there is not one raw duration left** - `grep -rn "duration: [0-9]" qml/`
returns a single hit, and it is `SeekBar`'s track-length property rather than an
animation. The animated now-playing indicator is the one that needed more than a
zero duration: collapsing its durations would have made it vanish, so under
reduced motion its sequence runs through in a frame and parks on each bar's
resting height instead.

### `NowPlayingPage` is not independently testable
It reaches into `Window.window` for all its sleep-timer state
(`NowPlayingPage.qml:67` to `:81`: `sleepTimerActive`, `sleepStopAtEndOfTrack`,
`sleepTimeLeft`, `sleepIsFading`, `sleepFadeOut`, plus `startSleepTimer`,
`cancelSleepTimer` and `formatSleepTime`). The state itself lives in `Main.qml`.
So the page cannot be instantiated in a test without `Main` or a `Window`
wrapper that fakes all eight members. Moving that state out of `Main.qml`, into
a small QML singleton or onto a C++ object, fixes the page and the test stub at
once. Other pages use `Window.window` only for `navigate()` and `goBack()`,
which the stub already handles.

### `CollectionPage`'s own context menus shadow the Pin menu
`qml/pages/CollectionPage.qml` gives its album delegate (around line 270) and
its artist delegate (around line 335) a local `Menu` on `Qt.RightButton`, each
with two `MenuItem`s of its own. Those predate section F and they win over the
shared Pin menu from `ContextMenu.qml`, so right-clicking an album or an artist
in My Collection offers no Pin. Either fold Pin into those two menus or replace
them with the shared one. The grids in the rest of the app are fine.

### Dead SQL dependency. Done.
`Qt6::Sql` is out of `find_package` and `target_link_libraries`, and
`libqt6sql6`/`libqt6sql6-sqlite` are out of the Debian depends. Only the comment
above that depends list still mentions SQL, and it is there to say why it is
absent. The README's old claim that the session was cached in SQLite was never
true: it is `~/.config/tidal-wave/credentials.json`, plain JSON, written
owner-only by `Auth::saveCredentials`.

## Decisions the user already made

Do not reopen these.

- **Themes:** six palettes, but **"Graphite" was replaced by a green dark theme
  ("Pine")**. The user called the violet sloppy. The light pair stays **Sky**
  (crisp white, blue) and **Sand** (warm, green accent), and the user likes
  Sand as drawn. Now three dark and three light, paired by hue, with a
  pure-black switch in place of a separate Deep theme. Not the three and two
  the spec says.
- **Theme names:** **Sea, Pine, Rust** dark and **Sky, Sand, Clay** light,
  **not translated**. They replaced Midnight, Forest, Ember, Daylight, Paper
  and Dawn: the picker is already a grid with a Dark column and a Light column,
  so a name that also says "midnight" says the same thing twice, and a set of
  times of day read as filler. Each name is one ordinary thing of roughly that
  colour. Being product names, they are the same six words in German.
- **Radius scale:** the review page table, with **popups and dialogs at 14**,
  not 18. Everything else as drafted.
- **Filter chips:** **icons only, always.** The user saw the labelled variant
  and said the pills were too big. They must read as one unit with the search
  field, which is why they sit inside its container. This overrides SPEC S8.
  They are a fixed 30px wide and never resize; `Prefs::minSidebarWidth` is 190
  because that is the narrowest sidebar all five fit in.
- **The rail shows the whole library as covers**, not only the pinned ones.
  A rail that is blank until you pin something is dead UI for most people.
  Wide sidebar: type icon plus name. Rail: cover only. This overrides SPEC S9.
- **No search result expansion.** SPEC S7 shipped and the user did not
  recognise the rows it added. Searching an artist does not list their albums
  and songs, and searching a song does not list its album. Results are direct
  title matches, ranked. This overrides SPEC S7.
- **No manual sidebar toggle button.** The `panel-left` glyph was dropped on
  purpose; compact mode is entered by window width alone.
- **One app mark at every size.** No `icon-small.svg`, no separate tray asset.
  This overrides SPEC I1.
- **No `user` glyph.** Its drawing became the `artist` glyph, since the two were
  near-identical at 18px. The sidebar footer shows the username with no avatar.
- **Update check:** once per 24h, prompt at next launch only, Escape means
  Later.
- **Privacy notice:** the Settings panel plus the bottom of `README.md`. No
  separate PRIVACY.md.
- **Cross-device play history is not available.** `users/{id}/history` returns
  404 and `users/{id}/activity` only reports favourites added, not plays. Phone
  plays cannot be pulled in. This was checked against the live API and the user
  has been told. Recently-played is tracked locally for all four kinds.

### Unreproduced: the window would not grow again

Reported once during QA - "I might have just found a weird rare bug where I
can't make the window bigger again right now" - and not seen since. Recorded
rather than dropped, with what has been ruled out:

- `Main.qml` sets `minimumWidth: 640` and `minimumHeight: 600` and **no maximum
  of any kind**, so nothing in the app caps the window's size. A capped maximum
  is the usual cause of a window that will not grow, and it is not this.
- An item wider than the window raises a layout's implicit size, which stops a
  window *shrinking*, not growing - the opposite symptom.
- The sidebar's reserved slot used to jump ahead of its panel during a
  breakpoint crossing, which is fixed, but that produced a bar of bare page
  rather than a size constraint.

So the likely explanation is the compositor rather than the app: a KWin
tiling/maximise state, or a client-side-decoration resize edge lost after a
state change. If it happens again, the things worth capturing in the moment are
`qdbus org.kde.KWin /KWin queryWindowInfo` for the window, whether it is in a
tile or maximised state, and whether a fresh instance resizes normally while the
stuck one does not.

## Next up, in order

Everything above this line that is not marked done is in this list; everything
marked done was verified, not assumed.

1. **Move the sleep-timer state out of `Main.qml`**, then add a `NowPlayingPage`
   test that does not need a window. This is the last thing standing between
   that page and the same test treatment every other page gets.
2. **Run `tests/stress/run.sh` to a clean result on every backend.** The
   offscreen scenario now passes at `STRESS_SCALE=0.25`; `software`, `xcb`,
   `wayland` and `idle-rss` have still never been run. Expect more harness
   false positives of the kind the Flickable `contentItem` turned out to be -
   fix the audit rather than the app when the thing it reports is invisible to
   the user, and say so in the comment.
3. **Build the release `.deb` in a container**, against the oldest toolchain we
   mean to support. The depends floors are honest now, which is what made the
   problem visible: built here they read `libqt6core6 (>= 6.12)` and
   `libstdc++6 (>= 16)`, so the package refuses cleanly and installs almost
   nowhere. This is the one thing blocking a release that anyone can install.
4. **Decide the declared Qt floor.** `find_package(Qt6 6.4)` is now true again
   for the app - the one 6.5-only call, `loadFromModule`, is guarded in both
   `Application.cpp` and `tst_firstrun.cpp` - but nobody has yet *run* a 6.4
   build. The Debian box can, and that answer decides whether 6.4 stays a
   supported floor or becomes 6.12 to match the binary.
5. **First run and audio on the RT kernel.** Blocked until 3 or 4 gives that box
   a runnable binary. The audio one is the most valuable: the PipeWire deadlock
   fixed earlier this session was a timing bug, and an RT scheduler changes the
   timing.
6. **Keep `docs/design-review.html` current and republish it** to the artifact
   URL. It is current as of the theme rename and the glyph pass.
7. **Only then section J, and only with the user's approval.** Merging
   `beta-0.4.0` to `main` has never been authorised.
