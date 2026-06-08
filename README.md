# 🌊 Tidal Wave Desktop Client

[![C++ Standard](https://img.shields.io/badge/C%2B%2B-20-blue.svg?style=flat-square&logo=c%2B%2B)](https://en.cppreference.com/w/cpp/20)
[![Qt Version](https://img.shields.io/badge/Qt-6.4%2B-green.svg?style=flat-square&logo=qt)](https://www.qt.io/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
[![Development Stage](https://img.shields.io/badge/stage-alpha-red.svg?style=flat-square)](https://github.com/immineal/tidal-wave)

**Tidal Wave** is a premium, native, lightweight desktop client for the **Tidal** music streaming service, built from the ground up using C++20, CMake, and Qt 6/QML. It delivers a fast, fluid, and system-integrated music listening experience on Linux.

---

## 🎨 Visual Interface

### Home Page
![Home Page](assets/screenshot_home.png)

### Search & Album View
| Search Page | Album details |
| :---: | :---: |
| ![Search Page](assets/screenshot_search.png) | ![Album Page](assets/screenshot_album.png) |

### Collection & Playback
| Collection Page | Fullscreen Now Playing |
| :---: | :---: |
| ![Collection Page](assets/screenshot_collection.png) | ![Now Playing](assets/screenshot_nowplaying.png) |

---

## ⚡ Key Features

*   **Native & Lightweight**: Built with C++20 and Qt 6 QML, offering ultra-low CPU and memory footprints compared to Electron-based clients.
*   **Rich Modern UI**: Curated dark theme, smooth animations, glassmorphic elements, and cover-art-color matching gradients.
*   **Device Flow Authentication**: Secure sign-in using Tidal's official device flow OAuth authentication with local credential recovery.
*   **Linux MPRIS2 Support**: Full system media integration, enabling control via system audio widgets, desktop lock screens, and hardware media keys.
*   **Discord Rich Presence (RPC)**: Synchronizes real-time playing status, track metadata, album cover arts, and active seek position/duration progress.
*   **Offline Cache & Queue Management**: Full control over your play queue with queue panels and localized caching.
*   **Search & Biography Parsing**: Search tracks, albums, and artists, with biography sections that parse rich text and render clickable links.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Description |
| :--- | :--- |
| `Space` | Play / Pause |
| `Ctrl+Right` / `Ctrl+Left` | Next / Previous track |
| `Right` / `Left` | Seek forward / backward 10s |
| `Up` / `Down` | Volume up / down (5% increments) |
| `Ctrl+M` | Mute / Unmute audio |
| `Ctrl+S` | Toggle Shuffle |
| `Ctrl+R` | Cycle Repeat Mode (Off / All / One) |
| `Ctrl+1` / `2` / `3` | Navigate to Home / Search / Collection |
| `Ctrl+N` | Toggle Now Playing fullscreen view |
| `Ctrl+Q` | Toggle Play Queue panel |
| `Escape` / `Alt+Left` | Go back |
| `Ctrl+,` | Open Settings |

---

## 🛠️ Build & Installation

### Prerequisites
*   A compiler supporting C++20 (GCC 11+, Clang 13+, MSVC 2022+)
*   CMake 3.20+
*   **Qt 6 SDK (6.4+)** with the following modules:
    *   `Core`, `Gui`, `Widgets`, `Quick`, `Qml`, `Network`, `DBus`, `Multimedia`, `Sql`, `Svg`, `Concurrent`

```bash
# Debian / Ubuntu
sudo apt install build-essential cmake qt6-base-dev qt6-declarative-dev qt6-multimedia-dev qt6-svg-dev libqt6svg6-dev libsqlite3-dev
```

### Build Steps
```bash
# Configure the build in release mode
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release

# Compile with all available processor cores
cmake --build build --parallel $(nproc)

# Launch the application
./build/tidal-wave
```

---

## 📝 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
