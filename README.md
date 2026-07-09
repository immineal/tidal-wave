Tidal Wave is not affiliated with TIDAL Music AS.

# Tidal Wave Desktop Client

Tidal Wave is a native, lightweight desktop client for the Tidal music streaming service. It is built using C++20, CMake, and Qt 6/QML, delivering a fast, system-integrated music listening experience.

## Interface Screenshot

![Tidal Wave Home Screen](assets/screenshot.png)

## Noteworthy Features

*   **Native Performance**: Built with C++20 and Qt 6, bypassing heavy web wrappers for a minimal CPU and memory footprint.
*   **Media Keys and MPRIS2**: Full Linux media player integration via D-Bus MPRIS2, supporting lockscreen controls, system volume widgets, and media keys.
*   **Secure Authentication**: Implements Tidal OAuth device login flow with secure local session caching using SQLite.
*   **Custom Audio Player**: Native streaming audio engine utilizing QMediaPlayer and QAudioOutput with selectable stream qualities.
*   **Chromecast Output** (Linux): Cast audio to Chromecast / Google Home devices — native mDNS discovery (Avahi) and CASTV2 control, with a built-in HTTP server that streams the current track (FLAC up to 96 kHz, or AAC) directly to the device. Downloads/downsamples on the fly so every quality tier casts.
*   **Persistent Navigation State**: Separate loaders retain individual page states when jumping between Home, Search, and My Collection views.
*   **Queue Panel**: Full queue management including track ordering, shuffle, and cycle repeat modes.
*   **System Tray Integration**: Background playback support with system tray control options to show, hide, and quit the application.
*   **Rich Detail Pages**: Dedicated views for albums, artists, playlists, and mixes. Biographies are parsed as rich text with clickable navigation links.
*   **Robust Sleep Timer**: Persistent background sleep timer in the Now Playing page with presets, a custom slider, a toggleable fade-out fader (with pop-prevention delay), and an end-of-track stopping mode.

## AI notice

I used Claude Code over the course of 3 days to generate most of the code for this project, since I recently won some Anthropic API credits and wanted to put them to use. I also don't currently have the time to do this any other way, even if I wanted to. It's a shame, since I'm generally really not a supporter of AI, but I wanted the performance increase and the money was already spent.

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| Space | Play / Pause |
| Ctrl + Right | Next track |
| Ctrl + Left | Previous track |
| Right | Seek forward 10 seconds |
| Left | Seek backward 10 seconds |
| Up | Volume up (5% increment) |
| Down | Volume down (5% increment) |
| Ctrl + M | Mute / Unmute |
| Ctrl + S | Toggle Shuffle |
| Ctrl + R | Cycle Repeat Mode (Off / All / One) |
| Ctrl + 1 | Go to Home |
| Ctrl + 2 | Go to Search |
| Ctrl + 3 | Go to Collection |
| Ctrl + N | Fullscreen Now Playing view |
| Ctrl + Q | Toggle Queue panel |
| Escape | Go back |
| Alt + Left | Go back |
| Ctrl + , | Open Settings |

## Installation

Prebuilt downloads for every platform are on the **[latest release](https://github.com/immineal/tidal-wave/releases/latest)**.
Pick your system below. (`ffmpeg` is optional but needed for the download and Chromecast features.)

<details open>
<summary><b>🐧 Linux — Debian / Ubuntu / Mint (recommended)</b></summary>

Download **`tidal-wave-linux-x86_64.deb`**, then:

```bash
sudo apt install ./tidal-wave-linux-x86_64.deb
```

That's it — `apt` pulls in the Qt 6 runtime, QML modules, and everything else automatically
(no chasing missing packages). Launch it from your app menu or run `tidal-wave`.
</details>

<details>
<summary><b>🐧 Linux — other distros (Fedora, Arch, …)</b></summary>

Download **`tidal-wave-linux-x86_64.tar.gz`**, extract it, and run the binary:

```bash
tar -xzf tidal-wave-linux-x86_64.tar.gz
./tidal-wave
```

Install the runtime yourself via your package manager: the Qt 6 libraries (Core, Gui, Widgets,
Quick, Qml, Network, DBus, Multimedia, Sql, Svg) and their QML modules, plus `ffmpeg` and
`avahi` (for Chromecast). If it complains about a missing library, install the matching Qt 6
runtime package. Building from source (below) is often easier on these distros.
</details>

<details>
<summary><b>🍎 macOS (Apple Silicon & Intel)</b></summary>

Download **`tidal-wave-macos-x64.tar.gz`** and unpack it (double-click, or `tar -xzf …`).
The app is unsigned, so macOS quarantines it — clear that once:

```bash
xattr -dr com.apple.quarantine tidal-wave.app
```

Then double-click **`tidal-wave.app`**. (Alternatively: right-click the app → **Open** →
**Open** on the first launch.) For downloads, `brew install ffmpeg`.
</details>

<details>
<summary><b>🪟 Windows 10 / 11</b></summary>

Download **`tidal-wave-windows-x64.zip`**, extract the folder anywhere, and run **`tidal-wave.exe`**.
It's unsigned, so Windows SmartScreen will warn you the first time — click **More info → Run anyway**.
Everything (Qt runtime, QML) is bundled in the folder. For downloads, install
[ffmpeg](https://www.gyan.dev/ffmpeg/builds/) and add it to your `PATH`.
</details>

## Build from source (any OS)

You need a C++20 compiler (GCC 11+ / Clang 13+ / MSVC 2022+), **CMake 3.20+**, and **Qt 6.5+**.

**Install the toolchain:**

| OS | Command |
|----|---------|
| Debian/Ubuntu | `sudo apt install build-essential cmake qt6-base-dev qt6-declarative-dev qt6-multimedia-dev libqt6svg6-dev qml6-module-qtquick-controls libsqlite3-dev libasound2-dev libavahi-client-dev ffmpeg` |
| Fedora | `sudo dnf install gcc-c++ cmake qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtmultimedia-devel qt6-qtsvg-devel sqlite-devel alsa-lib-devel avahi-devel ffmpeg` |
| Arch | `sudo pacman -S base-devel cmake qt6-base qt6-declarative qt6-multimedia qt6-svg sqlite avahi ffmpeg` |
| macOS | `brew install cmake qt ffmpeg` |
| Windows | Install [Qt 6](https://www.qt.io/download-qt-installer) (MSVC 2022) + [CMake](https://cmake.org/download/) + Visual Studio 2022 Build Tools |

**Build & run:**

```bash
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release   # macOS: add -DCMAKE_PREFIX_PATH=$(brew --prefix qt)
cmake --build build --config Release --parallel
./build/tidal-wave                                # Windows: build\Release\tidal-wave.exe ; macOS: open build/tidal-wave.app
```

**Make a Debian package** (produces a `.deb` with all dependencies declared):

```bash
cd build && cpack -G DEB && sudo apt install ./tidal-wave-*-Linux.deb
```

> **Linker error about `lame_*` / `mp3lame`?** A few distros ship a *statically*
> linked FFmpeg inside Qt Multimedia, which leaks an undeclared `libmp3lame`
> dependency at final link time. If the build fails with undefined references to
> `lame_*`, install your distro's `libmp3lame`/`lame` dev package and configure with:
>
> ```bash
> cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXE_LINKER_FLAGS="-lmp3lame -lm"
> ```

> Chromecast output is Linux-only (it uses Avahi/mDNS); it's automatically excluded on macOS and Windows.

`ffmpeg` is a `Recommends` (only needed for the download feature); everything else is a
hard `Depends`, including the easy-to-miss `qml6-module-*` runtime modules.

## License

This project is licensed under the GNU GPL v3 License. See the LICENSE file for details.
