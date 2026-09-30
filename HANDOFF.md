# Tidal Wave 0.4.0 — handoff

Everything the user asked for across one long session, what is already done, and
what is left. Delete this file before merging `beta-0.4.0` into `main`.

**Branch:** `beta-0.4.0`. Commit regularly; merge to `main` only when the whole
list is done and the user has approved it.
**Environment:** KDE Plasma, **Wayland** (`XDG_SESSION_TYPE=wayland`), X11 also
supported. Two 1920x1200 monitors, so half-screen is **960x1200** — that is the
width everything must look right at.

**Design review page (the user reviews design here, keep it current):**
https://claude.ai/artifact/AkdWsw9NekmW8py6eBZtU3
Source: `docs/design-review.html`. Edit it and republish to that same URL with the
Artifact tool (pass the URL as `url`, after reading it first).

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
- **Never** build into `./build` or `./build_custom` — both stale.
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

## Ground rules the user set

1. **Write the unit tests first**, before the implementation they cover.
2. **No fully capitalised** user-facing strings, no `.toUpperCase()` on shown
   text. Caps-maxxing is both an AI tell and bad UI.
3. **No em dashes** in displayed strings. Use an **en dash** where a separator
   is genuinely wanted; rewrite asides instead.
4. **Corner radii**: the uniform `radius: 8` is the default AI look. Use a scale
   where the radius means something (proposed table is in the review page).
5. **Ask via user prompts**, short questions, as many rounds as needed. Keep
   chat replies short — the user does not read long ones.
6. Everything must work on **X11 and Wayland**, and still build on Windows and
   macOS (CI matrix).
7. **Use subagents** for work that can be isolated, to save context. Give each
   one a disjoint file set; never let two agents edit `CMakeLists.txt` at once
   (all current sources are already wired, so they should not need to).

## Done

- `beta-0.4.0` branched; the user's prior offline-startup/auth fix and the Qt
  6.12 CI change are committed on it.
- Test infrastructure: `tidalwave_qml` static library holds the QML module and
  all C++ except `main.cpp`, so tests can link it. `TIDALWAVE_BUILD_TESTS=ON`
  builds `tests/`; CI runs `ctest` on Linux under offscreen. Two placeholder
  tests pass.
- Version bumped to 0.4.0 in `CMakeLists.txt`; `Prefs::appVersion()` reads it.
- `src/ui/Prefs.{h,cpp}` **complete**: theme, language, sidebar width, audio
  device, all persisted, plus the layout constants (`railBreakpoint` 820,
  `railWidth` 68, `minSidebarWidth` 180, `maxSidebarWidth` 420,
  `chipLabelWidth` 268).
- Contract stubs, bodies still to write: `src/ui/I18n.{h,cpp}`,
  `src/ui/PinStore.{h,cpp}`, `src/api/LibraryIndex.{h,cpp}`.
- CMake: translation catalogues wired (`i18n/tidal-wave_{en,de}.ts`, guarded on
  LinguistTools), `TIDALWAVE_VERSION` compile definition, per-file test targets.
- New app mark: `assets/icon.svg` + `assets/icon.png`. Three identical parallel
  wave bands, filled not stroked so no round line ends show. `7W + 2A = 64`
  makes band thickness, gaps and margins equal; half period 32 keeps the slope
  gentle enough that the bands look evenly thick. **One mark at every size** —
  there is deliberately no separate tray asset.
- Icon set in `qml/components/VectorIcon.qml`: 15 new glyphs, and `VectorIcon`
  now supports a filled-accent and a stroked-overlay path so one glyph can mix
  fills and strokes. Fixed per the user's review: `queue` (was a hamburger, and
  must stay distinct from `playlist`), `mix` (broadcast hub), `cast` (bigger
  arcs, equal gaps, shortened screen edges), `artist` (now the better of the two
  near-identical person glyphs; `user` removed), `pin-filled` (needle survives the fill).

## To do

### A. Themes  (nothing started beyond `Prefs::theme`)
- Rewrite `qml/Theme.qml` as a palette lookup keyed on `prefs.theme`, so every
  existing binding updates on change. Add the radius scale as tokens.
- **Six themes: four dark, two light.** Draft palettes are in the review page.
  **The user asked that the two light themes be made clearly more different
  from each other** than that draft — they are too alike.
- Migrate every hardcoded colour in QML to a token. The accent `#00B2F8` and
  the `Qt.rgba(1,1,1,0.04)` hover fills appear in many files.
- The light themes are the real work: roughly forty places assume a dark ground
  (white-on-cover text, hero overlay gradients, player-bar quality badges).
- Theme picker in Settings.

### B. German translation
- `qsTr()` in QML, `tr()` in C++, `.ts` catalogues, `QTranslator`.
- Settings picker **System / English / Deutsch**, default system locale,
  applying **live** via `QQmlEngine::retranslate()` — implement `src/ui/I18n.cpp`.
- ~175 distinct static strings. A full per-file inventory was produced in
  session; regenerate it with a search agent if needed.
- ~30 strings are built by concatenation and break under German word order —
  `"Playing from " + name` (`NowPlayingPage.qml:346`), `"Search saved " + type`
  (`CollectionPage.qml:147`), `"No results for \"" + q + "\""`
  (`SearchPage.qml:158`), the Album/Playlist summary lines
  (`AlbumPage.qml:147-158`, `PlaylistPage.qml:143-152`). Restructure into one
  `qsTr` with `%1`, do not merely wrap.
- Plurals via `qsTr("%n track(s)", "", n)`. Today `QueuePanel.qml:31`,
  `HomePage.qml:82` and `SearchPage.qml:202` can render "1 tracks".
- C++ strings: tray menu, the "Save track" dialog title,
  `Player::qualityLabel`, Downloader/Player/Cast errors.
- Add `qttools` to the CI Qt modules so `lrelease` exists there.

### C. Responsive layout  (nothing started)
Full audit was done in session; the findings:
- **`NowPlayingPage.qml:824`** — transport row needs 344px, gets 290 at 960.
  Overflows by 54px; **already broken at today's 900 minimum.** Decision:
  below ~1000px **stack the cover above the title and transport** in one
  centred column.
- **`CollectionPage.qml:77`** — header row needs ~1083px against a 740px pane.
  Decision: **move the search field to its own row below the tabs.**
- **`TrackRow.qml`** (six pages) — 260-472px of fixed columns. Decision: hide
  the 160px album column below ~640px of row width, hide popularity below
  ~560px, and **always reserve the hover buttons' space** so titles stop
  jittering on mouseover.
- **`PlayerBar.qml:167`** — right group declares `minimumWidth: 160`, content
  is 218px; the queue button clips off-window below ~731. Fix the minimum, drop
  the volume slider and cast below ~720.
- **`QueuePanel`** — needs a scrim and a `MouseArea` (clicks currently fall
  through to the page beneath) and `width: Math.min(340, parent.width * 0.85)`.
- **Settings popup** — 640px tall against a 600px `minimumHeight`; clamp to
  `min(480, w-64) x min(640, h-64)`.
- Hero headers (Album/Playlist/Mix/Artist): pill `Row` becomes a `Flow`, fixed
  hero `height` becomes `implicitHeight`, add elide/wrap to artist and meta
  text, drop `PillButton`'s fixed `width: 120`.
- `CollectionPage` grids: derive `cellWidth` and card size from the width.
- `HorizontalSection`: derive card size so the row peeks deliberately.
- `Main.qml`: `minimumWidth` 900 → 640.

### D. Sidebar rebuild  (nothing started)
- One **flat library list**: playlists, albums, artists and mixes together, each
  row with a small type icon.
- Order: **pinned, then recently played, then A-Z.**
- **Fetch all playlists by paging.** Today `SideBar.loadPlaylists` asks for 30,
  which is the reported "new playlists don't show up" bug.
- Track recently-played **locally for all four kinds** — today only playlists
  get `markPlaylistPlayed`. **Cross-device history is not available:**
  `users/{id}/history` returns 404 and `users/{id}/activity` only reports
  favourites added, not plays. Phone plays cannot be pulled in; this was checked
  against the live API and the user has been told.
- **Search field** above the library list, below the divider. Performant, simple.
- Search also matches **songs**: liked songs are already fully cached, so those
  are instant; saved albums' tracklists get indexed lazily in the background and
  cached to disk. **No artist top tracks.**
- Result expansion: an **artist** match also shows that artist's saved albums
  and saved songs; a **song** match also shows the saved album containing it.
- **Type filter chips** between the field and the list: songs / albums /
  artists / playlists / mixes. **Icons only, always** — the user saw the
  text-label variant and said the pills were too big. They must read as one unit
  with the search field, not as loose pills; the field wants generous rounding.
- Footer shows the **username, not the email address**, and **no avatar icon**.
  The `user` glyph sat there alone and read as a missing profile picture; drop
  it and give the username the space. The gear stays. The `user` glyph itself
  is gone from `VectorIcon.qml`: its drawing is now the `artist` glyph, since
  the two were near-identical at 18px and only one person icon is needed.
- Implement in `src/api/LibraryIndex.cpp`.

### E. Sidebar sizing and compact mode
- The sidebar border is a **drag handle**: `Qt.SplitHCursor` on hover,
  user-adjustable, persisted through `prefs.sidebarWidth`.
- Below `Prefs::railBreakpoint` (820px window width) it collapses to the
  `railWidth` (68px) rail showing **only the logo, the nav icons and the pinned
  covers**. Finder and library hide. At the bottom of the rail, **only the
  settings gear** — no user icon.
- The rail **hover-expands** into the ordinary full sidebar, the way compact
  mode works in Zen Browser and Firefox: the **same sidebar**, **overlaying**
  the content rather than pushing it, with a soft drop shadow. Slides back on
  leave.
- **No manual toggle button.** The `panel-left` glyph was dropped on purpose.
- Animations quick, smooth and satisfying, and verified in every graphics
  environment.

### F. Pinning  (`src/ui/PinStore.cpp` is a stub)
- Pin albums, playlists, artists and mixes.
- Right-click context menu on sidebar rows, cards and page headers.
- Pinned block above the library list; drag to reorder.
- A pinned item shows **only** in the pinned block, never duplicated below.
- Persisted per Tidal user id.

### G. Navigation
- Clicking the **track title in Now Playing** opens that track's album.
  `player.currentTrack` already carries `albumId`.
- Clicking an **artist name in the player bar** opens that artist. Each artist
  of a multi-artist track is its **own hover target**, underlined on hover.
  Cover and gaps still open Now Playing. `trackToMap` carries only the first
  `artistId`, so the map needs the full artist list.

### H. Audio output
- `Player.cpp:28` builds `QAudioOutput` once and never rebinds, which is why a
  system output change needs an app restart.
- Follow `QMediaDevices::defaultAudioOutput` live when `prefs.audioDevice` is
  empty, else use the chosen device. **Preserve position and play state** across
  the switch.
- Settings picker: "System default" plus the available devices.
- Hold up across PipeWire, PulseAudio and ALSA, and across hot-plug and removal
  of the active device.

### I. Stress and environment tests
- Continuous resize while navigating; rapid page flipping for leaks;
  5000-track lists; simulated API errors and timeouts; language switching under
  load; theme switching under load.
- Verify under X11, Wayland and `QT_QUICK_BACKEND=software`, plus offscreen in
  CI. Windows and macOS via the CI build matrix.
- Animations must stay smooth in all of the above.

### L. Hardware acceleration toggle
- A Settings switch that turns the GPU path off, for people who noticed the
  app using a slice of their GPU while idle.
- Qt decides the scene-graph backend **before the first window exists**, so
  this is read in `Application::run()` ahead of the engine and the toggle has
  to say it needs a restart. `QQuickWindow::setSceneGraphBackend("software")`,
  persisted as `Prefs::softwareRendering`.
- Turn off the 4x multisampling in the same breath when it is on; that is GPU
  work too.
- Must not strand anyone: if software rendering is what makes the app usable
  on their machine, the setting has to survive and apply on every launch.

### M. First-run simulation
- Actually run the app as a brand new install would see it and look for the
  stupid stuff: **empty `HOME`, no settings file, no saved session, no cache**.
- Cover the environments the app claims to support: X11, Wayland,
  `QT_QUICK_BACKEND=software`, offscreen, and a session where the tray is
  missing. Windows and macOS stay on the CI matrix.
- Check: does it start, does it land on the login page, does it survive with no
  network, are there console errors or QML warnings, does the window icon
  resolve, is the default sidebar width sane, does the default theme apply.
- Isolate every run with `TMPDIR=… HOME=… XDG_*=…`. **Never** `pkill
  tidal-wave` and never let a run touch the user's real instance or settings.

### J. Release
- Merge `beta-0.4.0` into `main` once complete **and approved**. Do not tag or
  push without asking.
- Delete this file in that merge.

### K. Update check and privacy notice
- Poll the GitHub releases API for a tag newer than `PROJECT_VERSION`.
  **Once per 24h**, cached to disk, so a launch does not always hit the network.
- **Prompt at the next launch**, never mid-session: no idle timer, no popup
  over playback. Decided with the user.
- Buttons: **Open release / Later / Skip this version.** Skip and Later both
  persist. The popup links out to the GitHub release page; the app never
  downloads or self-installs. Keeping that complexity out is the point.
- Privacy notice lives in **two places**, per the user: a block in the
  **Settings** panel and a section at the **bottom of `README.md`**. No
  separate PRIVACY.md. It covers every outbound request: the Tidal API, cover
  art fetches, Chromecast mDNS on the LAN, and the new GitHub version check.
- The check must be switchable off, and the notice has to say so.

## Answered since the handoff

- **Themes:** keep the six palettes from the review page, but **"Graphite" is
  replaced by a green dark theme** ("Forest"). The user called the violet
  sloppy. The light pair stays **Daylight** (crisp white, blue) and **Paper**
  (warm, green accent) - the user likes Paper as drawn.
- **Radius scale:** the review page table, with **popups/dialogs at 14**, not
  18. Everything else as drafted.
- **Update check:** once per 24h, prompt at next launch only (section K).
- **Privacy notice:** Settings panel plus the bottom of README.md (section K).
