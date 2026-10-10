# First run on macOS

For someone with a Mac and a day or two. Tidal Wave is built and used on Linux,
so most of what follows has never been executed once. Treat everything here as
a question rather than a regression.

The repository is public, so start by cloning the release:

    git clone --branch v0.4.0 https://github.com/immineal/tidal-wave.git
    cd tidal-wave

## What is already known to be absent

Six `if(UNIX AND NOT APPLE)` blocks in `CMakeLists.txt` skip things on macOS, so
some of this is by design:

- Chromecast is compiled out entirely. `src/cast/*` and the Avahi dependency are
  Linux-only. The app should run without it, and the output picker is written to
  hide its whole "Cast to" half when there is no cast backend. Check that it
  does, rather than showing an empty heading or a permanent "Searching…":
  `cast: null` is unreachable on Linux and so is only ever exercised here.
- No `.desktop` file, no icon install, no RPATH fixup, no CPack packaging. The
  target *is* `MACOSX_BUNDLE TRUE`, so the build produces a `.app`, but nothing
  signs it, notarises it or wraps it in a disk image, and its bundle metadata is
  wrong (the app menu says `tidal-wave`). `open` cannot be used for the
  two-launch test in item 2: it coalesces onto the running instance before the
  app ever sees it, so run the binary inside the bundle directly.

## 1. Does it build

    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j

You need Qt 6. CI builds against 6.12 and that is the only version anyone has
used; `find_package(Qt6 6.4)` is the declared floor and has never been *run*.
Homebrew's `qt` is fine to try, and report which version you got, because that
is part of the answer. If CMake cannot find Qt, pass
`-DCMAKE_PREFIX_PATH=$(brew --prefix qt)`.

The tests are behind an option: add `-DTIDALWAVE_BUILD_TESTS=ON` and run
`ctest --test-dir build --output-on-failure`. 17 tests pass on Linux and any
that fail here are findings. The GUI ones need no display trickery on macOS the
way they do on Linux, but `QT_QPA_PLATFORM=offscreen` works if you want them
quiet.

## 2. The single-instance lock, which is the one I expect to break

`Application::singleInstanceSocketName()` builds a Unix domain socket path and a
`sockaddr_un` has 107 bytes for it. It tries `XDG_RUNTIME_DIR` (absent on macOS),
then `QDir::tempPath()`, then `/tmp`, taking the first that fits. macOS's
per-user temp directory is long, something like `/var/folders/xy/9z.../T/`, so
this is the first platform where the fitting check has to do anything.

Check that a second launch does *not* open a second window but raises the first
one, and say which directory the socket ended up in. If two windows appear, the
lock failed and the fallback is not working.

## 3. The menu bar item, which I expect to be blank

On Linux the tray icon has to be a *named theme* icon (`QIcon::fromTheme`),
because Plasma's StatusNotifier sends a name rather than a pixmap, and handing it
a resource pixmap renders nothing. That fix is in `loadAppIcon()`. macOS has no
icon theme at all, so `QIcon::fromTheme("tidal-wave")` should find nothing and
fall through to the embedded pixmap.

Report whether the menu bar shows the Tidal Wave mark, something generic, or
nothing. Also whether its menu works and whether it can bring a closed window
back, which matters for the next item.

## 4. The close button, which is a convention clash

New in this branch: a `ui/quitOnClose` preference, in Settings → Window,
defaulting to off. Off means closing the window hides it and the tray icon
brings it back. With no tray available, closing always quits.

macOS convention is already that closing a window leaves the app in the Dock, so
the default is probably right here by accident. What needs an eye is whether
there is genuinely a way back. `QSystemTrayIcon::isSystemTrayAvailable()`
returns true on macOS, so the app takes the "hide it" branch, and if the menu
bar item is blank or absent (item 3) then the window is gone with no route back
and the Dock icon may not restore it. Say exactly how you got the window back,
or that you could not.

## 5. Keyboard shortcuts say the wrong thing

Qt maps `Ctrl` to Command on macOS automatically, so the shortcuts themselves
should work. Settings → Keyboard shortcuts prints the stored strings, though, so
they will read "Ctrl+J" where a Mac user expects ⌘J. Confirm that the shortcuts
fire with Command and that the displayed text is wrong. Both halves are the
finding.

## 6. Reduced motion is not implemented here

`detectReducedMotion()` reads KDE's and GNOME's config files and has a comment
saying macOS's `NSWorkspace.accessibilityDisplayShouldReduceMotion` is not read
yet. So turning on System Settings → Accessibility → Display → Reduce motion
should have no effect, while `TIDALWAVE_REDUCED_MOTION=1` in the environment
should have the full effect. Confirming both turns a comment into a measured
gap. With the variable set, the sidebar collapse, the Now Playing restack and
the player bar regroup should all arrive in a single frame, and the playing
indicator should sit still at an uneven skyline rather than vanishing.

## 7. Retina, which Linux cannot test at all

Every glyph in this app is hand-drawn on a 24-unit grid and tuned at 1x. Two are
tuned tightly enough to be worth looking at on a 2x display:

- the `track` waveform, seven bars at a pitch of 3.2 units, which at 15-16px is
  meant to be a 1px bar with a 1px gap;
- the app mark in the sidebar and the window, drawn with `QtQuick.Shapes`.

Screenshot the sidebar, the player bar and the Settings panel at 2x and say what
looks wrong: half-pixel seams, bars merging, the mark's bands touching.

## 8. Text metrics and German

The app ships German, and a label that fits on Linux can overflow on macOS
because the fonts differ. Switch to German in Settings → Appearance → Language
and walk the whole UI: the Settings panel, every context menu, the player bar at
640px wide, the Collection filter pills. One overflow already shipped and was
fixed on Linux; this is a different font stack.

## 9. Audio

Device enumeration and switching go through `QAudioOutput`/`QMediaDevices`, which
is CoreAudio here. Earlier today this app deadlocked on Linux when a device
changed: the signal arrived while PipeWire held its thread loop lock and
rebinding took the same lock. The fix defers the rebind to the next event loop
turn, which is platform-neutral, but the bug was a timing accident and macOS has
different timing.

Without logging in you can still open Settings → Playback → Audio output, see
whether the device list matches the system's, and switch between devices. Watch
for the window going unresponsive rather than crashing; that was the symptom.
Plugging and unplugging headphones mid-session is the interesting case.

## 10. Do not log in, and most of this needs a workaround because of it

Stop at the login screen. Do not attempt to sign in to anyone's Tidal account.

An earlier draft of this file claimed the whole checklist works signed out.
A real run proved otherwise: every `Shortcut` in `Main.qml` is
`enabled: auth.state === 2`, `PlayerBar` is `visible: auth.state === 2`, and
`loginLoader` covers the content until then. So items 5b, 6, 7 beyond the login
screen, 8 and 9 are all unreachable by launching the app.

The login-free route is already in the repository. `tests/visual/` is a
standalone CMake project whose `tst_shots` runner instantiates SideBar,
PlayerBar, SettingsPanel, TrackRow, the album page and Now Playing against
`tests/TestStubs.h` and grabs each with `grabToImage`. `tests/visual/run.sh` is
Linux-only (Xvfb, ImageMagick `import`, `/proc/net/unix`), but the binary itself
runs under cocoa, so build that project and drive the binary directly. That
covers the shortcut strings, reduced motion, every Retina glyph and the German
walk.

One thing it cannot cover: `TestStubs.h` always installs a `StubCast`, so the
no-cast-backend path is unreachable even there, and that path is reachable
*only* on macOS. Answering it needs a small runner of your own, outside the
repository, that binds `cast` to null.

`HOME` does not isolate anything on macOS. `QSettings`
goes through CFPreferences and writes
`~/Library/Preferences/com.tidalwave.Tidal Wave.plist` whatever `HOME` says, so
a settings change in a test run lands in the real user's preferences. Back that
file up before you change any setting, and put it back afterwards. The same root
cause makes `QStandardPaths::AppDataLocation` ignore `HOME` and `XDG_DATA_HOME`,
which is why `tst_library` aborts in `initTestCase` here.

A first run on this machine also came up already signed in, from a
`credentials.json` left by an install months earlier, and refreshed the token.
If that happens, quit without touching anything and re-run with a scratch
`HOME`; do not log out, because that may revoke the token on the maintainer's other
devices.

## What to send back

The commands you ran and their raw output, the Qt version, and screenshots for
items 3, 7 and 8. Exact wording of any error or QML warning: this suite runs at
zero QML warnings on Linux, so every warning here is a finding. Prose only where
something needs explaining.
