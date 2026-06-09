# Tidal Wave Desktop Client: Comprehensive Improvements & Feature Backlog

This document compiles all verified UI bugs, missing features, visual flaws, and user-requested improvements for the **Tidal Wave** desktop client.

---

## 1. User-Requested Fixes & Core Enhancements (Current Iteration)

### A. Back Arrow Overlap with Cover Art
* **Issue**: On the Album, Playlist, and Mix pages, the back button overlaps the left side of the cover art.
* **Cause**: The header's `RowLayout` starts at `x = 24` (due to `margins: 24`), while the back button is placed at `leftMargin: 8` and has a width of `36`, extending to `x = 44`.
* **Fix**: Change `anchors.leftMargin` on the header's `RowLayout` to `64` in `AlbumPage.qml`, `PlaylistPage.qml`, and `MixPage.qml` to shift the cover art and metadata to the right.

### B. "LOSSLESS" Quality Display Untruth
* **Issue**: The player bar and Now Playing page show "LOSSLESS" even when streaming in "High" (320kbps) or "Normal" (96kbps) quality.
* **Cause**: `TidalClient::fetchStreamManifest` retrieves the track's maximum available quality (`LOSSLESS` or `HI_RES_LOSSLESS`) from the manifest response, ignoring the requested lower quality.
* **Fix**: In `Player::audioQuality()`, compute the actual playing quality as the minimum of the user's preferred quality setting and the track's maximum quality.

### C. Streaming Quality Selector in Settings
* **Issue**: The selector is narrow (130px), truncates options (like "Lossless (FLAC)"), is hard to read, and uses default unstyled Qt Quick styling.
* **Fix**: Custom style the `ComboBox` in `SideBar.qml` with a width of `180px` and a theme-matching dark color palette, custom dropdown list, borders, and hover states.

### D. Artist Page: Popular Tracks and Discography Spacing
* **Issue**: The space between the popular tracks list and the albums/discography section on the Artist page is extremely slim.
* **Fix**: Add a spacer `Item { height: 24; visible: root.topTracks.length > 0 }` right after the popular tracks list in `ArtistPage.qml`.

### E. Now Playing: "Up Next" Mini-Queue Layout
* **Issue**: The "Up Next" preview in the Now Playing page is very crammed.
* **Cause**: Cover art thumbnails are tiny (32x32), and the list uses a very small spacing (`spacing: 6`).
* **Fix**: Increase outer spacing to `12`, increase item thumbnails to `44x44` (with radius `6`), increase text size (`14px` for title, `12px` for artists), and increase inner spacing to `4`.

### F. Single-Instance Management & Systray Re-Opening
* **Issue**: Multiple instances of the application can run concurrently, and closing the main window leaves the process running in the background with no tray menu to quit it or restore the GUI.
* **Fix**: 
  1. Implement single-instance lock via `QLocalServer`/`QLocalSocket` using `"TidalWaveSingleInstanceSocket"`. If another instance exists, write `"show"` to the socket, activate the existing window, and exit.
  2. Implement a system tray context menu with "Show", "Hide", and "Quit" options.
  3. Expose a `reallyQuit` flag from C++ to QML to bypass the window close interception when the user explicitly triggers "Quit".

### G. Play/Pause Circle Icons
* **Issue**: The play/pause vector icon inside the white circles is too small in the player bar and Now Playing page.
* **Fix**: Increase the `VectorIcon` width/height to `24x24` in `PlayerBar.qml` (was `20x20`) and `32x32` in `NowPlayingPage.qml` (was `22x22`).

### H. Playlist Edit Button Icon
* **Issue**: The Edit button on user-created playlists is missing its edit icon (renders empty).
* **Cause**: `PillButton.qml` maps `glyph: "✎"` to `VectorIcon`'s `"edit"` name, but no `"edit"` case is defined in `VectorIcon.qml`.
* **Fix**: Add the feather SVG path for `"edit"` inside `VectorIcon.qml` and map `"✎"` to `"edit"` in `PillButton.qml`.

---

## 2. Additional UI, Usability & Layout Backlog

### A. TrackRow Context Menu Click Interception
* **Location**: `qml/components/TrackRow.qml`
* **Issue**: Clicking on the context menu button (`⋯`) plays the track instead of opening the menu.
* **Cause**: The main `MouseArea` covering the row is defined after the `RowLayout`, placing it on top of the layout and blocking child click events.
* **Fix**: Move the main `MouseArea` (`id: hov`) so it is defined before the `RowLayout` in the QML file.

### B. Playlist Cover Art Collage Render Failure
* **Location**: `qml/pages/PlaylistPage.qml` and `qml/pages/CollectionPage.qml`
* **Issue**: User-created playlists display as blank teal squares because binding evaluations fail to re-trigger when tracks are asynchronously loaded.
* **Fix**: Bind the `Repeater`'s model dynamically using `root.tracks.slice(0, 4)` to force the creation of image delegates when the array changes.

### C. Page State Preservation on Navigation
* **Location**: `qml/main.qml` (Loader structure)
* **Issue**: Navigating away from any page and clicking back resets the page state entirely (clears search query, resets scroll position, resets active tab).
* **Fix**: Maintain page state cache or implement page loader caching instead of recreating page instances on every navigation change.

### D. Misaligned Search Icon Handle
* **Location**: `qml/components/VectorIcon.qml`
* **Issue**: The search icon in empty states has a handle that is visually disconnected from the circle.
* **Fix**: Replace the SVG path for search with the perfectly aligned one from `NavIcon.qml`.

### E. Scrollbar Layout Overlap on Track Lists
* **Location**: `qml/pages/MixPage.qml`, `qml/pages/PlaylistPage.qml`, `qml/pages/AlbumPage.qml`
* **Issue**: At small window widths, the scrollbar overlaps and obscures the track duration text.
* **Fix**: Reserve a right margin (`rightPadding: 16` or similar) inside the parent `ScrollView` or add right margins to the `TrackRow` layouts.

### F. Sidebar Playlist List Bleeding
* **Location**: `qml/components/SideBar.qml`
* **Issue**: Bottom items in the playlist sidebar list bleed into the "My Account" footer bar at reduced window heights.
* **Fix**: Ensure the `ListView` has `clip: true` and explicitly anchor its bottom to the top of the footer container.

### G. Emojis and Unicode Glyphs for Playback Controls
* **Location**: `qml/components/PlayerBar.qml` and `qml/pages/NowPlayingPage.qml`
* **Issue**: Playback buttons use raw Unicode characters (e.g. ⇌, ⏮, ⏭, ↺, ▶, ⏸) which can render as colored emojis depending on font configuration.
* **Fix**: Replace these characters with clean vector paths inside `VectorIcon.qml`.

### H. Context Menu Actions
* **Issue**: Right-click context menus are limited. Missing actions:
  - Like / Save track
  - Add track to playlist
  - Remove track from playlist (inside playlist view)
  - Remove track from queue
  - Share / Copy Tidal link
  - Start radio from track/artist

### I. Queue Panel Improvements
* **Issue**: Queue has no drag-to-reorder, no "Clear queue" button, and no context menu on queue items.

### J. Collection Page Improvements
* **Issue**: No sort or filter options, no item count in tab headers, and no remove-from-library actions.

### K. Now Playing Lyrics & Navigation
* **Issue**: No lyrics panel (or partial support), no queue preview, and the artist/album links lack hover underlines or cursors indicating they are clickable.

### L. Album Page Details
* **Issue**: No "Save to library" button in album header, total album duration not shown, and no "Duration" column header.
