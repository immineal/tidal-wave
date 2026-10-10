# Contributing

Tidal Wave is an unofficial Qt 6 / QML client for Tidal, C++20 and CMake, with
one maintainer and very few users. Replies can take a while.

You need a paid Tidal subscription to get past the login screen, so there is no
way to exercise most of the code without an account.

## Building

C++20 compiler, CMake 3.20+, Qt 6. The README lists the distro package sets.
`libavahi-client-dev` is needed for Chromecast, `ffmpeg` on `PATH` for
downloads and cast transcoding.

```bash
cmake -B build -S . -DCMAKE_BUILD_TYPE=Debug
cmake --build build --parallel
```

Qt from the Qt installer is not on CMake's search path, so point at the kit you
have: `-DCMAKE_PREFIX_PATH="$HOME/Qt/6.12.0/gcc_64"`. On macOS,
`-DCMAKE_PREFIX_PATH=$(brew --prefix qt)`.

## Tests

```bash
cmake -B build-tests -S . -DCMAKE_BUILD_TYPE=Debug -DTIDALWAVE_BUILD_TESTS=ON
cmake --build build-tests --parallel
QT_QPA_PLATFORM=offscreen ctest --test-dir build-tests --output-on-failure
```

Keep `QT_QPA_PLATFORM=offscreen`. `tests/CMakeLists.txt` already sets it per
test, so plain `ctest` is covered, but a binary you run by hand without it will
throw test windows onto your desktop.

A full run takes about fifteen minutes, of which `tst_qml` is 809 seconds on
its own. That is measured. It prints nothing while it works and it has not
hung. Narrow it with `-R tst_dash` while you iterate.

A new `tests/tst_*.cpp` needs no CMake edit; they are globbed with
`CONFIGURE_DEPENDS`, one binary per file. `tests/firstrun/`, `tests/stress/`
and `tests/visual/` have their own `run.sh` and are not part of `ctest`.

## Qt 6.4 is the floor and breaking it is silent

`CMakeLists.txt` asks for Qt 6.4. Development and the CI matrix are on 6.12, so
the floor is held by one job: a `debian:bookworm` container running the suite
against apt's Qt 6.4.2, which is what the release `.deb` targets.

QML is loaded at runtime. A *declarative* assignment to a property the running
Qt does not have takes down the whole type rather than that one property. The
engine says "Cannot assign to non-existent property", the file fails to load,
and whatever embedded it draws nothing. You get no build warning, because
nothing on that path is compiled. A declarative `popupType` (6.8) sat in
`tests/qml/tst_menus_and_glyphs.qml` until a Debian box ran the suite on real
6.4.2.

So: no `import QtCore` or `Settings` (6.5), no `Shape.CurveRenderer` (6.6), no
`popupType` (6.8). If you need something newer, assign it imperatively in
`Component.onCompleted` behind a version check, where a failure costs you the
property and leaves the page standing.

The 6.4 QML parser also refuses a set of old reserved words as names, where
6.12 takes them: `long`, `int`, `short`, `byte`, `char`, `float`, `double`,
`boolean`, `final`, `native`, `goto`, `abstract`, `volatile`, `transient`,
`synchronized`, `throws`, `public`, `private`, `protected`, `package`,
`interface` and `implements`. A `var long` is "Expected token `identifier'"
there and the whole file fails to load. In a test file that is one `compile()`
failure in place of every case in it.

On 6.4 a Layout nested in another Layout can keep a stale arrangement. When its
members change in the same step that resizes it, the next frame finds it at an
unchanged size and does not arrange it again, and a member that has just become
visible is painted at 0,0. A plain `Item` between the two makes the inner one a
top-level layout, which always arranges itself.

A `Shape` that leaves a scene and comes back crashes 6.4's software renderer,
and every icon in a menu does that when the menu reopens. The software renderer
is what the "Software rendering" setting selects and what the offscreen tests
run on. Build the `Shape` in a `Loader` that is active while the item has a
window, the way `VectorIcon.qml` and `AppMark.qml` do.

## Two other quiet failures

A new file under `qml/` must be listed in `QML_FILES` in `CMakeLists.txt`.
Otherwise it never reaches the module's resources and the import resolves to
nothing at runtime, with a green build.

A C++ method QML calls must be `Q_INVOKABLE`, or the call returns `undefined`
and nothing is logged. `PinStore::indexOf` was a plain public method once,
`SideBar.qml` called it, and pin dragging silently did nothing through three
rounds of fixes. The suite stayed green because `tests/TestStubs.h` had
declared its own `indexOf` as `Q_INVOKABLE`.
`tests/tst_qml_cpp_calls.cpp` now checks every `obj.method(` call in `qml/`
against the real meta-objects.

## CI

`.github/workflows/ci.yml` builds on Linux, Windows and macOS against Qt 6.12,
runs the suite on Linux and again on Debian 12 / Qt 6.4.2, validates the
AppStream and `.desktop` files, and greps the tracked tree for anything shaped
like a mail address against an allowlist in the job itself. Do not put your
address in a comment or a fixture.

## Commits and pull requests

Branch off `main` and target `main`. Release work happens on a `beta-x.y.z`
branch. Subjects use a type prefix (`fix:`, `feat:`, `docs:`, `test:`,
`chore:`, `build:`, `perf:`, `i18n:`, `ci:`) and then a lowercase sentence
about what changed from the outside, so `fix: a playlist's track count stops
lying` rather than `fix: PlaylistPage count binding`.

Say in the pull request which platform you tested on. Nobody expects all three.

A test that goes red against the old code is worth more than the description of
the fix. Several bugs here survived a green suite because the fixture could not
express the failure.

## Translations

`qsTr()` in QML, `tr()` in C++, catalogues in `i18n/`. German is complete.
The completeness guard in `tests/tst_shortcuts.cpp` only scans QML for `qsTr(`,
so a C++ `tr()` with no German entry is invisible to it and will ship
untranslated behind a green suite. Add the German by hand.

## Platforms

Linux is the target: openSUSE, KDE Plasma, Wayland, with X11 exercised too.
Chromecast is Linux-only since it needs Avahi. macOS is secondary, built by CI
and shipped, with `docs/MACOS-FIRST-RUN.md` written because nothing had ever
run there. Windows is built by CI and tested least. Platform-specific code
needs a guard; `if(UNIX AND NOT APPLE)` around `src/cast/` is the pattern.

## Licence

GPL-3.0-or-later. Contributions are accepted on the same terms, no CLA.
