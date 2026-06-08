# Tidal Wave Desktop Client: Comprehensive Visual & UI Inspection Report

This report summarizes the findings from a full visual and interactive inspection of the **Tidal Wave** desktop client. The inspection was carried out on the virtual display (`:99`) using `xdotool` for user interactions, capturing sequential screenshots to `/tmp`, and cross-referencing with the QML/C++ source code.

---

## 1. Verified & Current UI Bugs

### A. TrackRow Context Menu Click Interception (Usability & Layout Bug)
* **Location**: `qml/components/TrackRow.qml`
* **Symptom**: Hovering over a track row displays the context menu button (`⋯`), but clicking on it immediately plays the track instead of opening the context menu. 
* **Root Cause**: The main `MouseArea` (`id: hov`) covering the row is defined *after* the `RowLayout` in the QML file. Because of QML's draw-order hierarchy, this places the main `MouseArea` on top of the layout, blocking the inner `MouseArea` inside the `⋯` button from receiving click events.
* **Suggested Fix**: Move the main `MouseArea` (`id: hov`) so it is defined *before* the `RowLayout`. This puts it in the background of the row, allowing the child layout's buttons to properly receive mouse clicks first.

---

### B. Playlist Cover Art Collage Render Failure (Visual & Code Bug)
* **Location**: `qml/pages/PlaylistPage.qml` and `qml/pages/CollectionPage.qml`
* **Symptom**: User-created playlists display as blank solid-colored squares (teal/cyan) with no cover art or collage grid, even when they contain numerous tracks with valid cover URLs.
* **Root Cause**: The collage `Grid` is bound to `visible: root.coverUrl.length === 0 && root.tracks.length >= 4`. At the time of page instantiation, `root.tracks` is empty (`[]`), so the `Repeater` (which has a static `model: 4` and binds `source` via `root.tracks[index].coverUrl`) creates 4 images with empty sources. When tracks are asynchronously loaded and `tracks` is reassigned, QML's binding evaluator fails to re-trigger the bindings for individual array indices (e.g., `root.tracks[index]`), leaving the images blank.
* **Suggested Fix**: Bind the `Repeater`'s model dynamically to the sliced track list:
  ```qml
  Repeater {
      model: root.tracks.slice(0, 4)
      Image {
          width: 90; height: 90
          source: modelData.coverUrl ? "image://tidal/" + modelData.coverUrl : ""
          fillMode: Image.PreserveAspectCrop
      }
  }
  ```
  This forces the `Repeater` to re-create the delegates whenever the array changes, properly loading the cover images.

---

### C. Lack of Page State Preservation on Navigation (Usability Bug)
* **Location**: `qml/main.qml` (Loader structure)
* **Symptom**: Navigating away from any page (e.g., going from Search results to an Artist page) and clicking back immediately resets the page. The search query is cleared, search results are lost, scroll positions are reset, and the active tab goes back to default.
* **Root Cause**: The main page loader (`Loader { id: pageLoader }`) switches page source URLs dynamically:
  ```qml
  source: {
      if (auth.state !== 2) return "pages/LoginPage.qml"
      switch (root.currentPage) { ... }
  }
  ```
  This destroys the QML page instance and instantiates a brand new one every time the user navigates, discarding all local property states.
* **Suggested Fix**: Implement a stack-based navigation (`StackView`) or keep page instances alive in a cache/multi-loader setup rather than destroying them on every navigation change.

---

### D. Misaligned Search Icon Handle in VectorIcon (Visual Flaw)
* **Location**: `qml/components/VectorIcon.qml`
* **Symptom**: The search icon rendered in empty states (e.g., "Search Tidal") has a handle that is visually disconnected from the circle, looking like an unaligned vertical line (lollipop/balloon shape).
* **Root Cause**: The SVG path definition for `"search"` is:
  `M 16 10 A 4.5 4.5 0 1 1 11.5 5.5 A 4.5 4.5 0 0 1 16 10 Z M 15 13.5 L 20 18.5`
  The circle is centered around `(13.75, 7.75)`, but the diagonal handle line starts at `(15, 13.5)`. The starting point is far too low and misaligned with the center of the circle, creating a visual gap.
* **Suggested Fix**: Replace the path with the one from `NavIcon.qml` which is perfectly aligned:
  `M 14 9 A 5 5 0 1 0 4 9 A 5 5 0 1 0 14 9 M 13.2 13.2 L 17.5 17.5` (scaled appropriately).

---

### E. Scrollbar Layout Overlaps on Track Lists (Visual & Layout Bug)
* **Location**: `qml/pages/MixPage.qml`, `qml/pages/PlaylistPage.qml`, `qml/pages/AlbumPage.qml`
* **Symptom**: When the window is resized to smaller widths, the vertical scrollbar is drawn directly on top of the duration column ("3:37", "4:07") in the track lists, making the text unreadable.
* **Root Cause**: The track rows (`TrackRow.qml`) fill the parent width but do not reserve right padding or margin for the vertical scrollbar track.
* **Suggested Fix**: Reserve a right margin (e.g., `rightPadding: 16`) inside the parent `ScrollView` or add right margin to the `TrackRow` layouts so they do not collide with the scrollbar gutter.

---

### F. Sidebar Playlist List Bleeding at Reduced Heights (Layout Bug)
* **Location**: `qml/components/SideBar.qml`
* **Symptom**: When the window height is reduced, the bottom-most items in the playlist list bleed directly into the "My Account" footer bar and get sliced in half.
* **Root Cause**: The `ListView` for playlists has `Layout.fillHeight: true` but is not anchored or clipped cleanly against a dedicated boundary, causing it to overlap with the footer bar.
* **Suggested Fix**: Ensure the `ListView` has `clip: true` set and explicitly anchor its bottom margin to the top of the "My Account" footer container.

---

### G. Unicode Math Symbols Header Blanking (Visual Bug)
* **Location**: `qml/pages/AlbumPage.qml`
* **Symptom**: Album titles that contain mathematical or special Unicode characters (such as `∄`) may fail to render or leave blank spaces in the page headers if the system font lacks the corresponding glyph ranges.
* **Suggested Fix**: Bundle a modern fallback sans-serif font (like *Inter* or *Outfit*) that supports extended math and symbols Unicode ranges, rather than relying solely on default system sans-serif fonts.

---

### H. Emojis and Unicode Glyphs for Playback Controls (Visual Aesthetic Flaw)
* **Location**: `qml/components/PlayerBar.qml` and `qml/pages/NowPlayingPage.qml`
* **Symptom**: Playback buttons (Shuffle, Previous, Play/Pause, Next, Repeat) use raw Unicode glyph text characters (e.g., ⇌, ⏮, ⏭, ↺, ▶, ⏸). Depending on the operating system's font fallback configuration, these can render as colorful emojis (e.g., ⏭-style) instead of flat monochrome vector icons, looking highly unpolished.
* **Suggested Fix**: Replace these character symbols with clean SVG paths inside `VectorIcon.qml` to enforce a unified, monochrome, premium visual aesthetic.

---

## 2. Page-by-Page Visual Polish & Aesthetic Improvements

### A. Home Page
* **Loading Overlay**: When first loading, the circular spinner overlay is placed directly in the center of the screen, blockading all interactions. A skeleton loading state for cards would feel much more premium.
* **Typography**: The text "Good afternoon" uses standard bold fonts. Using a premium font family and slightly tracking the letter spacing would feel more high-end.

### B. Now Playing Page
* **Background Gradient**: The background gradient is currently a very subtle cyan overlay:
  `GradientStop { position: 0; color: Qt.rgba(0,0.698,0.973,0.07) }`
  Enhancing this to a rich, dynamic gradient based on the vibrant colors of the album art (using image color analysis) would elevate the Now Playing experience to a premium level.
* **Control Buttons Hover Scales**: The play/pause button has a hover scale effect, but other buttons do not. Subtle hover feedback (like background glow or slight scaling) should be applied to all playback controls.

### C. Album Page
* **Header Backdrop Opacity**: The background image under the album details has an opacity of `0.18`. It is very dim and hard to see. A slightly higher opacity combined with a blur effect (`FastBlur` or `MultiEffect`) would look much more modern.

### D. Settings Popup
* **ComboBox Styling**: The drop-down selection for streaming quality uses standard Qt Quick styling. Custom styling with rounded corners, a border matching the theme (`Theme.border`), and an accent highlighted selection would match the application's dark theme much better.
