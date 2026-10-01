# Tidal Wave 0.4.0: consolidated spec

Everything the user asked for in this session, in one place. Branch `beta-0.4.0`,
merged to `main` only when complete and approved. Commit regularly.
Target environment: two 1920x1200 monitors, KDE Plasma, **Wayland** session
(`XDG_SESSION_TYPE=wayland`), X11 also supported. Half-screen = **960x1200**.

The requirements below are the record of what was asked for and are left as
written, including the ones the user later changed their mind about. Each
section carries a **Status** line saying what actually landed, checked against
the code on `beta-0.4.0` on 2026-10-01. `HANDOFF.md` is the working list; where
the two could drift, the Status lines here are the shorter summary of the same
findings.

## Global rules (apply to every change)

**Status: G1, G2, G4, G5, G6 held. G3 landed** as the radius scale in
`ThemePalette.cpp` (`chip` 999, `field` 14, `row` 7, `button` 8, `art` 5,
`card` 11, popups 14), surfaced in QML as `Theme.radius*`. G1's caps were
removed in `4d7600b`. G2 still needs a grep before any release: it is a rule
about displayed strings and nothing enforces it in a test.

- **G1** No fully capitalised user-facing strings anywhere. No `.toUpperCase()`
  on displayed text. Caps-maxxing is both an AI tell and bad UI.
- **G2** No em dashes (U+2014) in displayed strings. Where a dash separator is
  genuinely wanted, use an **en dash** (U+2013). Rewrite sentences that used an
  em dash as an aside.
- **G3** Corner radii: audit every radius in the app. The uniform `radius: 8`
  on everything is the "AI rounded-lg" default. Replace with a deliberate scale
  where the radius carries meaning (chips/pills fully round, fields softer than
  cards, etc.). The sidebar search field specifically needs more rounding.
- **G4** Unit tests are written **before** the implementation they cover.
- **G5** Everything must work on X11 and Wayland, and must still build on
  Windows and macOS (CI matrix). No Linux-only API without a guard.
- **G6** Chat replies to the user stay short. Questions come via user prompts,
  short, in as many rounds as needed.

## 1. Responsive layout

**Status: landed** in `8671b09`, with L2, L3, L4 landing in `e2e326d`.
`Main.qml` is at `minimumWidth: 640` / `minimumHeight: 600`. L10's clamp is in
the Settings `Popup` in `SideBar.qml`. Covered by `tests/qml/tst_layout_pages.qml`
and `tst_layout_player.qml`, which instantiate pages at 640 / 820 / 960 / 1280.

- **L1** Full layout correct at **960px** wide. Usable down to **640px**.
  `minimumWidth` drops from 900 to 640; `minimumHeight` stays 600 but the
  Settings popup must fit inside it.
- **L2** Sidebar collapses to a ~64px icon rail below ~820px window width.
- **L3** The sidebar border is a **drag handle**: `Qt.SplitHCursor` on hover,
  user-adjustable width, persisted. Width drives whether chips show icons only
  or icons plus text.
- **L4** Rail **hover-expands** back to the full sidebar while the pointer is
  over it, and slides back on leave, the way compact mode works in Zen Browser
  and Firefox. It is the **same sidebar**, not a separately designed panel: it
  **overlays** the content rather than pushing it, with a soft drop shadow.
  Smooth, quick, satisfying. There is **no manual toggle button**. Drop the
  `panel-left` icon; compact mode is entered purely by window width.
- **L5** `NowPlayingPage`: below ~1000px, stack cover above title and transport
  in one centred column. Currently overflows its transport row by 54px, which
  is broken even at today's 900px minimum (`NowPlayingPage.qml:824`).
- **L6** `CollectionPage`: move the search field to its **own row below the
  tabs**. Header currently needs ~1083px against a 740px pane.
- **L7** `TrackRow`: hide the 160px album column below ~640px of row width,
  hide popularity below ~560px, and always reserve the hover buttons' space so
  titles stop jittering on mouseover.
- **L8** `PlayerBar`: right group declares `minimumWidth: 160` but its content
  is 218px. Fix the declared minimum; drop volume slider and cast below ~720px.
- **L9** `QueuePanel`: give it a scrim and a `MouseArea` (clicks currently fall
  through to the page beneath), and `width: Math.min(340, parent.width * 0.85)`.
- **L10** Settings popup: clamp to `min(480, w-64) x min(640, h-64)`.
- **L11** Hero headers (Album/Playlist/Mix/Artist): pill `Row` becomes a `Flow`,
  fixed hero `height` becomes `implicitHeight`, add elide/wrap to artist and
  meta text. `PillButton`'s fixed `width: 120` becomes content-sized.
- **L12** `CollectionPage` grids: derive `cellWidth` and card size from the
  available width instead of a fixed 184px cell.
- **L13** `HorizontalSection`: derive card size so the row shows a deliberate
  partial-card peek instead of clipping at an arbitrary point.

## 2. Sidebar rebuild

**Status: landed** in `25221c4` (data layer, `src/api/LibraryIndex.cpp`) and
`e2e326d` (the rebuild itself). `qml/components/LibraryFinder.qml` is the
search field and chip strip. **S8 was changed by the user after this was
written:** the chips are icons only at every width, never labelled, and they
sit inside the field's rounded container rather than as pills under it. The
`Prefs::chipLabelWidth` constant that the labelled variant needed is gone.
S10 landed in `dacc5f5`.

**S7 is withdrawn.** It shipped and the user could not tell what it was. On
seeing the results they asked what the greyed, indented rows meant, which is
the whole feature failing on its own terms: an expansion only helps if it reads
as a consequence of a hit, and it read as noise. `LibraryIndex::search()` now
returns direct title matches only, and the `expanded` / `expandedFrom` flags
and the indent-and-grey in `SideBar.qml` are gone. **Do not re-add it.**

In its place, S5's "performant, simple" became a real relevance order rather
than a flat substring filter. The score is four terms added up: where the query
lands in the title (exact 400, prefix 300, word start 200, mid-word 100), plus
how much of the title the query covers (up to 40), plus what kind of thing
matched (artist 25, album and playlist 20, liked song 12, mix 10, a song known
only from a saved album's tracklist 0), plus familiarity (pinned 30, played 15,
neither 0). The three adjustments total less than the 100 between tiers, so
they reorder results among equals and can never lift a weaker match over a
better-placed one. Ties break on most recently played, then A-Z. The reasoning
is above `matchScore` in `LibraryIndex.cpp`; the cases are in
`tests/tst_library.cpp`.

**S9 is amended.** As written the rail carried "only the logo, the nav icons
and the pinned covers", and in QA the user saw an empty strip: the rail drew
`pins.items`, so with nothing pinned there was nothing to draw, which is where
most people start. Their words: in the wide sidebar you see the type icon and
the name, and in the rail you see just the cover. The rail now draws
`library.entries`, the same list the wide sidebar shows and in the same order
(pinned first, then recently played, then A to Z), as 40px covers with the type
glyph on a plain tile where a row has no artwork, a tooltip carrying the name,
and the pinned run marked off by the same break the wide list draws plus an
accent ring that survives scrolling. Right-click is the shared Pin menu now,
not Unpin alone. It reads `library.entries` rather than the filtered rows,
because the finder is not on screen in the rail and a filter left behind before
the window narrowed would empty it again with nothing to explain why.

**`Prefs::minSidebarWidth` is 190, not 180.** The five chips need 166px of
finder and the finder is the sidebar less 24, so at 180 the chips had to shrink
in the last few pixels of a drag. The user called that twitchy; the sidebar now
stops where the chips stop fitting and `LibraryFinder`'s chip width is a
constant again.

- **S1** One **flat library list** holding playlists, albums, artists and mixes,
  each row carrying a small type icon.
- **S2** Order: **pinned first, then recently played, then A–Z**.
- **S3** Fetch **all** playlists by paging. Today it asks for 30 and new
  playlists fall off the end, which is the reported bug.
- **S4** Recently-played is tracked **locally for all four types** (today only
  playlists get `markPlaylistPlayed`). Cross-device history is not available:
  `users/{id}/history` returns **404** and `users/{id}/activity` only reports
  favourites added, not plays. Phone plays cannot be pulled in.
- **S5** A **search field** above the library list, below the divider under
  Home/Search/Collection. Performant, simple, filters everything in the
  sidebar.
- **S6** Search also matches **songs**: liked songs are already fully cached so
  they are instant; tracklists of saved albums are indexed lazily in the
  background and cached to disk. **No artist top tracks.**
- **S7** ~~Search result expansion: searching an **artist** also shows that
  artist's saved albums and saved songs; searching a **song** also shows the
  saved album that contains it.~~ **Withdrawn by the user after seeing it.**
  See the Status block above.
- **S8** **Type filter chips** between the search field and the list:
  songs / albums / artists / playlists / mixes. **Icon-only when narrow, icon
  plus text when the sidebar is wide enough.** They must sit visually with the
  search field as one unit, not as loose pills.
- **S9** In the rail only the **logo, the nav icons and the pinned covers**
  remain. The search field, the chips and the library list are hidden until the
  rail hover-expands (L4), which restores the ordinary full sidebar.
  **Amended: the rail shows the whole library as covers, not the pins alone.**
  See the Status block above.
- **S10** Footer shows the **username**, not the email address.

## 3. Pinning

**Status: landed** in `0f39a77`. `src/ui/PinStore.cpp` persists per user id
(P6); the sidebar holds the pinned block, the drag reorder and the Pin menu.
Tests: `tests/tst_pins.cpp`, `tests/qml/tst_pinning.qml`. **One gap on P2:**
the album and artist delegates in `CollectionPage.qml` still have their own
right-click `Menu` (around lines 270 and 335) which shadows the new Pin menu on
those two grids.

- **P1** Pin albums, playlists, artists and mixes.
- **P2** Right-click context menu (sidebar rows, cards, page headers) with
  Pin / Unpin.
- **P3** Pinned block sits **above** the library list.
- **P4** Drag to reorder within the pinned block.
- **P5** A pinned item appears **only** in the pinned block, never duplicated
  in the library list below.
- **P6** Persisted per user id.

## 4. Navigation

**Status: landed** in `e2e326d`. N1 is in `NowPlayingPage.qml`; N2 is in
`PlayerBar.qml`, where each artist is its own hover target. Covered by
`tests/qml/tst_navigation.qml`.

- **N1** Clicking the **track title in Now Playing** opens that track's album.
- **N2** Clicking an **artist name in the bottom player bar** opens that artist.
  Each artist of a multi-artist track is its **own hover target**, underlined on
  hover so it is visibly clickable. Clicking the cover or the gaps still opens
  Now Playing.

## 5. German translation

**Status: landed.** The C++ half in `1b09cde` and `4d7600b`, the QML strings in
`55fb39d` and `19819ca`, the catalogue in `bd1f91b`, the plurals fix in
`6407582`, and the strings the sidebar rebuild added in `2dbd1c9`.
`i18n/tidal-wave_de.ts` is at **zero** `type="unfinished"` across 252 messages.
T6 is honoured: durations, counts and percentages go through
`toLocaleString(Qt.locale(), ...)`. `qttools` is in the CI Qt modules in both
`.github/workflows/ci.yml` and `release.yml`, so `lrelease` runs there.
**Not done:** the language picker (T2's setting) is not in the Settings panel
yet, so the only way to choose a language is the `ui/language` key.

- **T1** Qt i18n: `qsTr()` in QML, `tr()` in C++, `.ts` catalogues, `QTranslator`.
- **T2** Setting with **System / English / Deutsch**, defaulting to the system
  locale, applying **live** via `QQmlEngine::retranslate()` with no restart.
- **T3** ~175 distinct static strings. Dynamic API data (track, artist, album,
  playlist, device names) is never translated.
- **T4** ~30 strings are built by concatenation and break under German word
  order (`"Playing from " + name`, `"Search saved " + type`, `"No results for
  \"" + q + "\""`, the Album/Playlist summary lines). These must be restructured
  into single `qsTr` calls with `%1` placeholders, not merely wrapped.
- **T5** Counts use `qsTr("%n track(s)", "", n)` plural forms. Today
  `QueuePanel.qml:31`, `HomePage.qml:82` and `SearchPage.qml:202` can render
  "1 tracks".
- **T6** Durations, percentages and numbers use locale-aware formatting.
- **T7** C++ strings needing translation: tray menu (Show/Hide/Quit), the
  "Save track" dialog title, `Player::qualityLabel`, and the Downloader, Player
  and Cast error strings.

## 6. Themes

**Status: landed** in `aab01a8` and `2100153`, with a real bug fixed in
`58811d6` where switching repainted nothing. **TH1 reads differently than it
shipped:** six themes, but **three dark** (Midnight, Forest, Ember) and three
light (Daylight, Paper, Dawn), paired by hue, with a pure-black switch standing
in for what was a separate Deep theme. Originally shipped as four dark and
two light (Daylight, Paper), and "Graphite" became the green "Forest" at the
user's request. `tests/tst_theme.cpp` checks WCAG contrast per token per
palette. **Not done:** the theme picker in Settings.

- **TH1** Six prebuilt themes: **three dark, two light**, plus one more.
  Chosen in Settings.
- **TH2** `Theme.qml` becomes a palette lookup driven by a persisted name, so
  every existing binding updates automatically. The accent is currently hardcoded
  blue (`#00B2F8`) in many places outside Theme.qml, and all of those must move
  to tokens.
- **TH3** The light themes must be genuinely legible: every place that assumes
  a dark ground (white-on-surface text, overlay gradients, the `Qt.rgba(1,1,1,…)`
  hover fills, the player-bar quality badges) needs a token.

## 7. Audio output

**Status: A1, A2 landed** in `16c0e18`. `Player` holds a `QMediaDevices`,
re-resolves the preference on `audioOutputsChanged`, and rebinds while keeping
position and play state (`Player::rebindAudioOutput`). Tested in
`tests/tst_audio.cpp`. **A3 not done:** no audio output picker in Settings yet.
**A4 unverified:** the backend matrix and hot-plug of the active device have not
been exercised on real hardware.

- **A1** Follow the **system default output device live**. Today `Player.cpp:28`
  constructs `QAudioOutput` once and never rebinds, so a system output change
  only takes effect after an app restart.
- **A2** Preserve playback position and play/pause state across the switch.
- **A3** Settings gains an **Audio output** picker: "System default" plus the
  available devices.
- **A4** Must hold up across PipeWire, PulseAudio and ALSA, and across device
  hot-plug and removal of the active device.

## 8. Identity and chrome

**Status: landed** in `e15d5c0` and `9a63b37`. **I1 was changed by the user:**
there is deliberately **no** `assets/icon-small.svg` and no separate tray asset,
one mark serves every size. I2's count is 15 new glyphs, not 14, and `user` was
dropped rather than kept beside `artist`. I3's `setDesktopFileName("tidal-wave")`
is in `Application.cpp`; the hicolor icons are installed from `CMakeLists.txt`.
I4 is done: the Settings panel reads `prefs.appVersion()`.

- **I1** New logo: three identical parallel wave **bands**, filled rather than
  stroked, running past the tile edge so no line ends are visible, with the blue
  gaps and the top and bottom margins all exactly the band thickness.
  `assets/icon.svg`. A two-band `assets/icon-small.svg` for <22px, where three
  bands turn to mush.
- **I2** Icon set: 14 new glyphs plus fixes to `queue` (was a hamburger),
  `artist` (was indistinguishable from `user`), `cast` (arcs too small and
  unevenly spaced), `mix` (now a broadcast hub), `pin-filled` (needle was lost
  in the fill).
- **I3** The icon must resolve correctly as window icon, taskbar icon and tray
  icon on **both X11 and Wayland**. On Wayland the taskbar icon comes from the
  `.desktop` file matched via `setDesktopFileName`, not from `setWindowIcon`.
- **I4** Settings shows the **real app version**, not the hardcoded
  `"v0.1-alpha"` at `SideBar.qml:330`.

## 9. Tests

**Status: X1, X2, X3 landed.** `TIDALWAVE_BUILD_TESTS=ON` builds `tests/`, one
binary per `tst_*.cpp`, QML cases under `tests/qml/`. X3 is
`tst_layout_pages.qml` and `tst_layout_player.qml`.
**X4, X5: a harness landed** in `0f39a77` at `tests/stress/` (resize, page
flipping, 5000-track lists, API errors, theme and language switching, plus an
idle-RSS run of the real binary) across offscreen, software, xcb and wayland.
It has not been run to a clean result and its findings are not fixed.
**X6 half done:** `Application::reducedMotion` exists and is detected at
startup, but only one animation in the whole of `qml/` gates on it. Qt 6.12
exposes no cross-platform reduced-motion hint, which
`tests/stress/qml/tst_stress_motion.qml` records rather than asserts.

- **X1** `tests/` target: Qt Test for C++ and QtQuickTest for QML, run in CI.
- **X2** Unit tests written before implementation (G4).
- **X3** Layout tests instantiate pages at 640 / 820 / 960 / 1280 and assert no
  child overflows its parent and no text is clipped.
- **X4** Stress: continuous resize while navigating, rapid page flipping for
  leaks, 5000-track lists, simulated API errors and timeouts, language switching
  under load, theme switching under load.
- **X5** Graphics environments: verify under X11, Wayland, and
  `QT_QUICK_BACKEND=software`, plus `offscreen` in CI. Windows and macOS are
  covered by the CI build matrix.
- **X6** Animations must stay smooth in all of the above and must respect a
  reduced-motion preference where the platform exposes one.

## 10. Release

**Status: R1, R3 done. R2 open.** `PROJECT_VERSION` is 0.4.0 and
`Prefs::appVersion()` reads it through the `TIDALWAVE_VERSION` compile
definition. The branch is pushed; **`main` is untouched and the merge needs the
user's approval.** Nothing is tagged.

- **R1** Version **0.4.0**, set from `PROJECT_VERSION` rather than hardcoded.
- **R2** Branch `beta-0.4.0`, regular commits, merge to `main` on approval.
- **R3** The already-committed offline-startup/auth fix and the Qt 6.12 CI
  change ship as part of this release.
