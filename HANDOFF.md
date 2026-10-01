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
  with a null `Prefs`. All six palettes painted as Midnight. See
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
- Theme names are translated: Midnight becomes Mitternacht, Forest becomes
  Wald. Deep is gone, replaced by the pure-black switch. Say the word and all
  stay in English.


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
  A second launch hits the `TidalWaveSingleInstanceSocket` lock, sends `show` and
  exits 0, which proves nothing. Isolate a test run with
  `TMPDIR=… HOME=… QT_QPA_PLATFORM=offscreen`.
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
nothing. Six palettes, **three dark** (Midnight, Forest, Ember) and three
light (Daylight, Paper); "Forest" replaced the drafted violet "Graphite" at the
user's request. `tests/tst_theme.cpp` checks WCAG contrast for every token
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

### The Settings panel is most of what is left
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

### First-run findings, not yet fixed
Source: `tests/firstrun/run.sh`, all five re-checked against the code today.
- **`QLocalServer::listen()` failure is swallowed.** `src/ui/Application.cpp:231`
  is `if (server->listen(socketName)) { … }` with no `else`. The lock is
  `$TMPDIR/TidalWaveSingleInstanceSocket`; a `TMPDIR` long enough to breach the
  107-byte `sockaddr_un` limit makes `listen()` fail silently, and then *every*
  launch starts a full second instance. Same on a multi-user box, because the
  name has no uid in it. Log it at minimum; better, put the uid in the name.
- **Proxy settings are ignored entirely.** There is still no
  `QNetworkProxyFactory` anywhere in `src/`, so anyone behind a corporate proxy
  gets silence with no explanation.
- **No tray plus close equals a vanished app.** `Application.cpp:215` sets
  `setQuitOnLastWindowClosed(false)` and `Main.qml:25` hides the window on
  close unless `app.reallyQuit`. The tray is only created when
  `QSystemTrayIcon::isSystemTrayAvailable()` (`Application.cpp:291`), so with no
  tray there is no way back. Quit on close when the tray is unavailable.
- **PipeWire and PulseAudio connect errors print on every run** with no audio
  server. `silenceLogsAndAlsa()` (`Application.cpp:72`) covers the Qt logging
  categories and ALSA's own stderr, and misses these because they are neither.
- **A real `.deb` install has never been tested.** This box is openSUSE, no
  dpkg. The dependency findings came from `ldd`, the QML imports and a
  mount-namespace reproduction. Verify the package on an actual Debian box
  before release.

### Reduced motion is detected but almost nothing honours it
`Application::reducedMotion` exists and is detected once at startup
(`Application.cpp:147`, `detectReducedMotion()`), and it reaches QML as
`app.reducedMotion`. **Exactly one animation gates on it:** the sidebar's width
`Behavior`, through `SideBar.qml:63` and `:68`. Counting `Behavior`,
`NumberAnimation`, `PropertyAnimation`, `ColorAnimation`, `SequentialAnimation`
and `RotationAnimation`, there are about 25 animation sites across ten files
(`LoginPage` 8, `NowPlayingPage` 4, `SeekBar` 3, `MediaCard` 3, `SideBar` 2, and
one each in `PageHeader`, `BackButton`, `QueuePanel`, `MixPage`,
`PlaylistPage`). SPEC X6's second half is therefore unimplemented. The cheap fix
is a single `Theme`-level duration token that collapses to 0, so a `Behavior`
does not have to know about `app`.

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

### Dead SQL dependency
Nothing in `src/` uses SQL. `grep -rni sql src/` returns nothing. Yet
`CMakeLists.txt` still has `Sql` in `find_package(Qt6 … COMPONENTS)` and
`Qt6::Sql` in `target_link_libraries`, and the `.deb` still declares
`libqt6sql6` and `libqt6sql6-sqlite` in `CPACK_DEBIAN_PACKAGE_DEPENDS`. The
README used to claim the session was cached in SQLite, which was never true: it
is `~/.config/tidal-wave/credentials.json`, plain JSON, written owner-only by
`Auth::saveCredentials`. The README is fixed and the sqlite dev packages are out
of its toolchain table. Dropping the link and the two Depends is a `CMakeLists.txt`
change and belongs to whoever owns that file.

## Decisions the user already made

Do not reopen these.

- **Themes:** six palettes, but **"Graphite" was replaced by a green dark theme
  ("Forest")**. The user called the violet sloppy. The light pair stays
  **Daylight** (crisp white, blue) and **Paper** (warm, green accent), and the
  user likes Paper as drawn. Now three dark and three light, paired by hue,
  with a pure-black switch in place of a separate Deep theme. Not the three
  and two the spec says.
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

## Next up, in order

1. Build the Settings panel out. It is the single biggest gap between what the
   code can do and what a user can reach. Coordinate with the agent already
   working on the update switch and the privacy block.
2. Run `tests/stress/run.sh` properly and fix what it finds, starting with the
   `prefs.reduceMotion` probe.
3. Fix the five first-run findings above.
4. Gate the animations on `app.reducedMotion`, ideally through one duration
   token rather than 25 edits.
5. Move the sleep-timer state out of `Main.qml`, then add a `NowPlayingPage`
   test that does not need a window.
6. Fix `CollectionPage`'s two shadowing menus.
7. Keep `docs/design-review.html` current and republish it to the artifact URL.
8. Verify the `.deb` on a real Debian box.
9. Only then section J, and only with the user's approval.
