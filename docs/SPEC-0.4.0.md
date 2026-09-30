# Tidal Wave 0.4.0 — consolidated spec

Everything the user asked for in this session, in one place. Branch `beta-0.4.0`,
merged to `main` only when complete and approved. Commit regularly.
Target environment: two 1920x1200 monitors, KDE Plasma, **Wayland** session
(`XDG_SESSION_TYPE=wayland`), X11 also supported. Half-screen = **960x1200**.

## Global rules (apply to every change)

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
  Smooth, quick, satisfying. There is **no manual toggle button** — drop the
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
- **S7** Search result expansion: searching an **artist** also shows that
  artist's saved albums and saved songs; searching a **song** also shows the
  saved album that contains it.
- **S8** **Type filter chips** between the search field and the list:
  songs / albums / artists / playlists / mixes. **Icon-only when narrow, icon
  plus text when the sidebar is wide enough.** They must sit visually with the
  search field as one unit, not as loose pills.
- **S9** In the rail only the **logo, the nav icons and the pinned covers**
  remain. The search field, the chips and the library list are hidden until the
  rail hover-expands (L4), which restores the ordinary full sidebar.
- **S10** Footer shows the **username**, not the email address.

## 3. Pinning

- **P1** Pin albums, playlists, artists and mixes.
- **P2** Right-click context menu (sidebar rows, cards, page headers) with
  Pin / Unpin.
- **P3** Pinned block sits **above** the library list.
- **P4** Drag to reorder within the pinned block.
- **P5** A pinned item appears **only** in the pinned block, never duplicated
  in the library list below.
- **P6** Persisted per user id.

## 4. Navigation

- **N1** Clicking the **track title in Now Playing** opens that track's album.
- **N2** Clicking an **artist name in the bottom player bar** opens that artist.
  Each artist of a multi-artist track is its **own hover target**, underlined on
  hover so it is visibly clickable. Clicking the cover or the gaps still opens
  Now Playing.

## 5. German translation

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

- **TH1** Six prebuilt themes: **three dark, two light**, plus one more.
  Chosen in Settings.
- **TH2** `Theme.qml` becomes a palette lookup driven by a persisted name, so
  every existing binding updates automatically. The accent is currently hardcoded
  blue (`#00B2F8`) in many places outside Theme.qml — all of those must move to
  tokens.
- **TH3** The light themes must be genuinely legible: every place that assumes
  a dark ground (white-on-surface text, overlay gradients, the `Qt.rgba(1,1,1,…)`
  hover fills, the player-bar quality badges) needs a token.

## 7. Audio output

- **A1** Follow the **system default output device live**. Today `Player.cpp:28`
  constructs `QAudioOutput` once and never rebinds, so a system output change
  only takes effect after an app restart.
- **A2** Preserve playback position and play/pause state across the switch.
- **A3** Settings gains an **Audio output** picker: "System default" plus the
  available devices.
- **A4** Must hold up across PipeWire, PulseAudio and ALSA, and across device
  hot-plug and removal of the active device.

## 8. Identity and chrome

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

- **R1** Version **0.4.0**, set from `PROJECT_VERSION` rather than hardcoded.
- **R2** Branch `beta-0.4.0`, regular commits, merge to `main` on approval.
- **R3** The already-committed offline-startup/auth fix and the Qt 6.12 CI
  change ship as part of this release.
