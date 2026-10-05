# The app icon: every place it appears

The icon has been "fixed" four times and kept coming back, because changing
`assets/icon.svg` changes one of about ten surfaces and nothing tells you about
the other nine. This file is the map. It is written for the next person, who
should not have to work any of this out again.

Verified on 2026-10-01 against KDE Plasma 6.7.4, KWin 6.7.4, a Wayland session on
openSUSE, with the app built against Qt 6.12.0.

## Short version

```sh
tools/make-icon.py        # artwork changed? regenerate icon.svg and icon.png
cmake --build <builddir>  # rebuild, so the embedded resource is the new art
cmake --install <builddir> --prefix ~/.local
tools/refresh-icons.sh    # fix the user's icon theme and clear the caches
# then restart the app itself; nothing else needs restarting
```

If you only want to know why it still looks wrong, skip to
[If the icon looks stale](#if-the-icon-looks-stale).

## The two sources of truth

There are exactly two, and they must agree:

| Source | What it feeds |
| --- | --- |
| `assets/icon.svg` and `assets/icon.png` | everything outside the app window: window, taskbar, tray, switcher, launcher, package |
| `qml/components/AppMark.qml` | the two marks drawn inside the app window (the sidebar rail and the login page) |

They are the same drawing expressed twice, because one is a file the desktop
reads and the other is a `Shape` the app paints. `tools/make-icon.py` holds the
geometry constants and emits the SVG from them, so the SVG can never be
hand-edited into disagreeing with the QML. `assets/icon.png` is rasterised from
the SVG by that script and is never edited directly.

There is exactly one deliberate difference between them, `ICON_INSET` in
`tools/make-icon.py`. The exported file carries a margin of 6.25% per side, so
the mark covers 87.5% of its box and sits at the same visual weight as the icons
beside it in the panel; without it the mark measured 32x32 in a 32 pixel box
where Firefox was 28x29 and Dolphin 30x26. The in-app marks are not inset,
because they sit in the app's own layout, which already puts space around them.
The inset is applied as a transform wrapped around the emitted drawing, so the
three `<path d="...">` values stay identical to what `AppMark._band()` produces
and the two drawings can still be compared number for number.

The mark is pinned to the brand colours (`#0079A8` tile, `#FFFFFF` bands) in
both places. It deliberately does not follow `Theme.accent`. A mark that changed
colour with the in-app palette stopped reading as the same thing as the icon
sitting next to it in the taskbar, which is what "the app shows two different
logos" meant. `tests/qml/tst_appmark.qml` asserts the brand colours and asserts
that a theme switch leaves them alone, so a rebind to `Theme.accent` fails the
build.

## Every surface

| # | Surface | Where the pixels come from | Who writes it | Cache in front of it | How to refresh |
| --- | --- | --- | --- | --- | --- |
| 1 | Sidebar rail mark, login page mark | `qml/components/AppMark.qml`, painted live | the build | the compiled QML in the binary | rebuild, reinstall, restart the app |
| 2 | Qt resource `:/qt/qml/TidalWave/assets/icon.{png,svg}` | `assets/icon.*` | `qt_add_qml_module(... RESOURCES ...)` in `CMakeLists.txt` | the binary itself | rebuild |
| 3 | Window icon (`QApplication::setWindowIcon`) | `QIcon::fromTheme("tidal-wave")`, so surface 6 | `Application::run()` | Qt's icon loader, per process | restart the app |
| 4 | Taskbar entry, window switcher, task-manager tooltip | the `.desktop` entry's `Icon=` key, resolved in the icon theme | surface 6 and surface 7 | ksycoca, then plasmashell's own memory | `kbuildsycoca6 --noincremental` |
| 5 | System tray (StatusNotifierItem) | the icon *name* `tidal-wave`, resolved by the tray host | `Application::createTrayIcon()` passes a named `QIcon` | plasmashell's icon loader | picks the new file up by itself, see note B |
| 6 | `~/.local/share/icons/hicolor/scalable/apps/tidal-wave.svg` and `128x128/apps/tidal-wave.png` | `assets/icon.svg`, `assets/icon.png` | `cmake --install`, or `tools/refresh-icons.sh` | none, these are the files everything else reads | copy them, see note A |
| 7 | `~/.local/share/applications/io.github.immineal.TidalWave.desktop` | `packaging/io.github.immineal.TidalWave.desktop` | `cmake --install`, or `tools/refresh-icons.sh` | ksycoca, `mimeinfo.cache` | `kbuildsycoca6 --noincremental` and `update-desktop-database ~/.local/share/applications` |
| 8 | Application launcher (Kickoff), pinned panel launcher | surface 7, by name | you, when you pin it | ksycoca | `kbuildsycoca6 --noincremental` |
| 9 | Desktop-folder launcher (`~/Schreibtisch/tidal-wave.desktop` on this machine) | its own `Icon=tidal-wave`, resolved in the theme | created by hand by dragging the entry out | the folder-view applet in plasmashell | nothing, as long as its `Icon=` is a name and not a path. Its *filename* is whatever it was dragged out as and nothing updates it, so a copy made before the rename keeps working and keeps its old name |
| 10 | GTK applications and portals | surface 6 | as surface 6 | `icon-theme.cache` in the hicolor directory | `gtk-update-icon-cache -t -f ~/.local/share/icons/hicolor`, only if that file already exists |
| 11 | `.deb` package | `assets/icon.*` and `packaging/io.github.immineal.TidalWave.desktop` through the install rules | `cpack -G DEB` | the caches under `/usr`, rebuilt by `packaging/deb/postinst` | reinstall the package |
| 12 | `~/.icons/...` (legacy pre-XDG location) | nothing should be here | nothing, any more | none | `tools/refresh-icons.sh` deletes any copy it finds, see note C |

### Note A: one writer, and why this is the whole bug

`cmake --install` writes surface 6. It writes exactly two files: the scalable
SVG and the 128 PNG.

`loadAppIcon()` in `src/ui/Application.cpp` used to write surface 6 as well, on
**every single launch**, by rescaling its embedded PNG into eight sizes. Two
writers with different sources, and the one that ran more often won. That is how
the icon came back four times: the asset was fixed and installed, but the binary
in `~/.local/bin` was still the previous build, so the next launch of the app
stamped the old artwork straight back over the fresh install, every time, for
ever. Nobody saw it happen because it happened at startup.

It now installs a copy only when the icon theme has none
(`QIcon::hasThemeIcon()`), which in practice means running straight out of a
build tree. An installed icon is left alone. Keep it that way.

The old code also wrote a 256x256 upscaled from the 128, which is softer than
letting the desktop render the SVG at 256, and which the icon lookup prefers
over the SVG because the size matches exactly. The current pair of files has no
such trap: `hicolor/index.theme` gives `scalable/apps` `MinSize=1 MaxSize=256`,
so the SVG is an exact match at every size any surface here asks for.

### Note B: the tray needs a *named* icon, not a pixmap

This was learned the hard way and must not be undone. KDE's tray speaks
StatusNotifierItem. An icon handed over as a serialized pixmap (what you get
from `QIcon(":/....png")`) frequently renders blank on Plasma 6, while the same
`QIcon` is fine as a window icon. So `loadAppIcon()` returns
`QIcon::fromTheme("tidal-wave")` and the tray sends the host a name.

The useful side effect: because the host resolves the name itself, the tray
icon can update without the app doing anything. Measured on this machine, the
tray and the taskbar both switched to new artwork about three minutes after
`tools/refresh-icons.sh`, with no restart of anything.

Do not rely on it. A second change to the same files had not reached the panel
ten minutes later, and an artwork regression in between never reached it at all:
plasmashell had resolved the name once and went on serving that pixmap. So the
files and the caches being right is not the same as the panel being right, and
the only dependable way to make the panel re-read is to restart plasmashell.

The embedded resource stays on as `fromTheme`'s fallback argument, for a tray
that is not KDE's and for the case where theme lookup fails entirely.

### Note C: Wayland does not use `setWindowIcon` for the taskbar

On X11 the window icon travels with the window, in `_NET_WM_ICON`. On Wayland it
does not. There is a protocol for it, `xdg-toplevel-icon-v1`, and KWin 6.7.4
implements the server half, but Qt 6.12.0's Wayland client does not implement
the client half (checked: no `xdg_toplevel_icon` symbols in
`libQt6WaylandClient.so.6`). So `QApplication::setWindowIcon` reaches nothing
outside the process on Wayland.

What the taskbar, the window switcher and the task-manager tooltip actually use
is the `.desktop` file:

1. The app calls `QApplication::setDesktopFileName("io.github.immineal.TidalWave")`.
2. Qt's Wayland plugin passes that to `xdg_toplevel::set_app_id`.
3. KWin matches the app id against `io.github.immineal.TidalWave.desktop`.
4. That entry says `Icon=tidal-wave`.
5. The icon theme resolves `tidal-wave` to surface 6.

Every link in that chain is a name, and all five have to spell it the same way.
Note that only links 1-3 spell the app id. Links 4 and 5 spell the icon name,
`tidal-wave`, and the two names are not the same and are not meant to be: the
entry is named after the app id because Flatpak exports only `<app-id>.desktop`,
while `Icon=` has to name the files in the theme, which are still
`tidal-wave.svg` and `tidal-wave.png`. Break any link and the taskbar silently
falls back to a generic placeholder.

X11 does the same job through two properties instead, and neither is
`WM_CLASS`-only:

- `_KDE_NET_WM_DESKTOP_FILE` and `_GTK_APPLICATION_ID` carry
  `setDesktopFileName()` verbatim, so Plasma and GTK resolve the entry on X11
  exactly the way KWin does on Wayland.
- `StartupWMClass=tidal-wave` is the fallback for everything else, and it tracks
  the **binary** name, not the app id. Measured with `xprop` against a real
  window on a headless Xvfb, `WM_CLASS` is `"tidal-wave", "Tidal Wave"`: Qt's
  xcb plugin builds the instance half from the `argv[0]` basename (or
  `$RESOURCE_NAME`) and the class half from `applicationName()`, and never reads
  `desktopFileName()` for it. Moving `StartupWMClass` to the app id alongside
  the filename would therefore have broken X11 matching, which is why it did
  not move. `tests/firstrun/run.sh` re-measures both properties on every run.

## The caches, and the command for each

| Cache | What it holds | Clear it with |
| --- | --- | --- |
| ksycoca (`~/.cache/ksycoca6_*`) | the parsed `.desktop` entries that Plasma's launcher and task manager read | `kbuildsycoca6 --noincremental` |
| `~/.local/share/applications/mimeinfo.cache` | which entry handles what | `update-desktop-database ~/.local/share/applications` |
| `icon-theme.cache` inside an icon theme directory | a directory listing GTK trusts instead of reading the directory | `gtk-update-icon-cache -t -f <theme dir>` |
| `~/.cache/icon-cache.kcache` | KIconLoader's already-rendered pixmaps. Often absent on Plasma 6 | delete the file |
| plasmashell and kwin, in memory | whatever they resolved earlier in the session | they re-resolve a named icon on their own; a restart is a last resort |

Do not create an `icon-theme.cache` where there was none. Once the file exists,
GTK trusts it instead of reading the directory, so a file you add later stops
being found until you remember to rebuild it. The user's hicolor directory has
no such cache, and that is the better state.

## If the icon looks stale

Work down this list. Each step is cheap and the order matters.

1. **Is the artwork itself current?**
   ```sh
   tools/make-icon.py --check
   ```
   A non-zero exit means `assets/icon.svg` no longer matches the geometry in
   `tools/make-icon.py`. Run it without `--check` to regenerate both files.

2. **Is the installed binary the one you just built?** This is the one that
   caught everybody out. Compare them:
   ```sh
   cmp -s build/tidal-wave ~/.local/bin/tidal-wave && echo same || echo "stale binary installed"
   ```
   An old binary does not just draw the old in-app mark, it used to rewrite the
   whole icon theme on launch. Reinstall before anything else:
   ```sh
   cmake --install build --prefix ~/.local
   ```
   `cmake --install` cannot overwrite a running executable, so quit the app
   first if it complains about a busy file.

3. **Are the theme files right?**
   ```sh
   tools/refresh-icons.sh --dry-run    # look first
   tools/refresh-icons.sh              # then do it
   ```
   This deletes sizes left behind by the old runtime self-install, copies the
   current artwork into place, refreshes the desktop entry and clears the
   caches. It only ever writes under `$HOME` and it never restarts anything.

4. **Prove it with pixels.** A file whose name and date look right can still be
   the old art. Compare it against the reference:
   ```sh
   python3 - <<'EOF'
   from PIL import Image
   import numpy as np, os
   ref = Image.open("assets/icon.png").convert("RGBA")
   p = os.path.expanduser("~/.local/share/icons/hicolor/128x128/apps/tidal-wave.png")
   im = Image.open(p).convert("RGBA")
   d = np.abs(np.asarray(im).astype(int)
            - np.asarray(ref.resize(im.size, Image.LANCZOS)).astype(int))
   print("mean per-channel difference:", d.mean())
   EOF
   ```
   A mean of 0 to about 4 is a different resampler and is fine. A mean in the
   tens is different artwork.

5. **Still wrong in the panel only?** plasmashell resolved the icon once and is
   serving that pixmap from memory. Steps 1 to 4 cannot touch it. Restarting the
   shell is what clears it, and it is safe: your windows and your session are not
   affected, the panel just redraws.
   ```sh
   systemctl --user restart plasma-plasmashell.service
   ```

6. **Still wrong inside the app window?** That mark is drawn by the app, so it
   changes only when the app is rebuilt, reinstalled and restarted. No cache is
   involved and no amount of refreshing will touch it.

## When you change the artwork

1. Edit the geometry constants in `tools/make-icon.py` **and** the matching
   `readonly property` lines in `qml/components/AppMark.qml`. They are the same
   numbers in two languages.
2. Run `tools/make-icon.py`.
3. Check the two drawings still agree. `tools/make-icon.py --check` covers the
   SVG; for the QML side, the three `<path d="...">` values in `assets/icon.svg`
   must equal `AppMark._band()` for each of the three centres, rounded to two
   decimals.
4. Run the QML tests: `ctest --test-dir <builddir> -R tst_qml`.
5. Look at it at 16 pixels. That is the size with the least margin: three bands
   and the wave between them have to survive in a 16 pixel box, and a change
   that reads well at 128 can turn into three flat stripes down there.
6. Walk the short version at the top of this file.
