# First run on macOS

For someone with a Mac and a day or two. Tidal Wave has only ever been built and
run on Linux, so most of what follows has never been executed once. Treat
everything here as a question, not a regression.

Start by cloning the branch — the repository is public, so nothing needs to be
sent to you:

    git clone --branch beta-0.4.0 https://github.com/immineal/tidal-wave.git
    cd tidal-wave

## What is already known to be absent

Six `if(UNIX AND NOT APPLE)` blocks in `CMakeLists.txt` skip things on macOS, so
some of this is by design rather than broken:

- **Chromecast is compiled out entirely.** `src/cast/*` and the Avahi dependency
  are Linux-only. The app is expected to run without it, and the output picker
  is written to hide its whole "Cast to" half when there is no cast backend. That
  the picker degrades correctly rather than showing an empty heading or a
  permanent "Searching…" is worth checking, because `cast: null` is unreachable
  on Linux and so is only ever exercised here.
- **No `.desktop` file, no icon install, no RPATH fixup, no packaging.** There is
  no macOS bundle target at all. `cmake --install` will not produce a `.app`.

## 1. Does it build

    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j

You need Qt 6. CI builds against 6.12 and that is the only version anyone has
used; `find_package(Qt6 6.4)` is the declared floor and was true again as of
this branch, but has never been *run*. Homebrew's `qt` is fine to try — report
which version you got, because that is part of the answer. If CMake cannot find
Qt, pass `-DCMAKE_PREFIX_PATH=$(brew --prefix qt)`.

Two places to watch:

- `silenceLogsAndAlsa()` in `src/ui/Application.cpp` dlopens ALSA, which does not
  exist here. It should fail softly and carry on. If it does not, that is a bug.
- `tests/` are behind an option: add `-DTIDALWAVE_BUILD_TESTS=ON` and run
  `ctest --test-dir build --output-on-failure`. 17 tests pass on Linux. Any that
  fail here are findings, and the GUI ones need no display trickery on macOS the
  way they do on Linux — but if you want them quiet, `QT_QPA_PLATFORM=offscreen`
  works.

## 2. The single-instance lock, which is the one I expect to break

`Application::singleInstanceSocketName()` builds a Unix domain socket path and a
`sockaddr_un` has 107 bytes for it. It tries `XDG_RUNTIME_DIR` (absent on macOS),
then `QDir::tempPath()`, then `/tmp`, taking the first that fits. **macOS's
per-user temp directory is long** — something like
`/var/folders/xy/9z.../T/` — so this is the first platform where the fitting
check actually has to do something.

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
back — which matters for the next item.

## 4. The close button, which is a convention clash

New in this branch: a `ui/quitOnClose` preference, in Settings → Window,
defaulting to off. Off means closing the window hides it and the tray icon brings
it back; with no tray available, closing always quits.

macOS convention is already that closing a window does not quit the app — it
stays in the Dock. So the default is probably right here by accident. What needs
an eye is whether there is genuinely a way back: `QSystemTrayIcon::
isSystemTrayAvailable()` returns true on macOS, so the app will take the "hide
it" branch, and if the menu bar item is blank or absent (item 3) then the window
is gone with no route back and the Dock icon may not restore it. Say exactly how
you got the window back, or that you could not.

## 5. Keyboard shortcuts say the wrong thing

Qt maps `Ctrl` to Command on macOS automatically, so the shortcuts themselves
should work. But Settings → Keyboard shortcuts **prints the strings**, and they
will read "Ctrl+Q" where a Mac user expects ⌘Q. Confirm that the shortcuts fire
with Command, and that the displayed text is wrong — both halves are the finding.

## 6. Reduced motion is not implemented here

`detectReducedMotion()` reads KDE's and GNOME's config files and has a comment
saying macOS's `NSWorkspace.accessibilityDisplayShouldReduceMotion` is not read
yet. So turning on System Settings → Accessibility → Display → Reduce motion
should have **no effect**, and `TIDALWAVE_REDUCED_MOTION=1` in the environment
should have the full effect. Confirming both is what turns a comment into a
measured gap. With the variable set, the sidebar collapse, the Now Playing
restack and the player bar regroup should all arrive in a single frame, and the
playing indicator should sit still at an uneven skyline rather than vanishing.

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
for the window going **unresponsive** rather than crashing — that was the
symptom. Plugging and unplugging headphones mid-session is the interesting case.

## 10. Do not log in

Stop at the login screen. Do not attempt to sign in to anyone's Tidal account.
Everything above can be checked signed out.

## What to send back

The commands you ran and their raw output, the Qt version, and screenshots for
items 3, 7 and 8. Exact wording of any error or QML warning: this suite runs at
zero QML warnings on Linux, so every warning here is a finding. Prose only where
something needs explaining.
