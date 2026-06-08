# Tidal Wave Desktop Client: Comprehensive Visual & UI Inspection Report

This report consolidates all visual design, layout, usability, and technical improvements identified during a complete visual inspection of the **Tidal Wave** desktop client. Testing was performed interactively on the virtual display (`:99`) using `xdotool` and screen capture tools integrated with the `AutoImageViewer` utility on the host display, alongside a review of the QML and C++ source code.

---

## 1. Interactive Testing Tool & Setup Details
* **Virtual Framebuffer**: The application runs headlessly on display `:99` (`Xvfb :99 -screen 0 1280x800x24`).
* **Visual Inspection Loop**: Screenshot captures are taken using ImageMagick (`DISPLAY=:99 import -window root /tmp/tidal_screenshot.png`), which are automatically detected by the custom watcher script `/tmp/view_tmp.py` (`AutoImageViewer`) and displayed fullscreen on the host display (`:0`).
* **Interactions**: Clicks, text entry, scrolling, and page navigation are simulated on display `:99` using `xdotool` keys and coordinates.

---

## 2. Page-by-Page Visual & Layout Inspection Notes

### A. Window Resizing (Tested at 1000x700 down from 1280x800)
* **Scrollbar overlap on track lists**: On the Mix page (and other track-list pages) at reduced width, the vertical scrollbar thumb is drawn directly on top of the duration text (e.g., "3:37", "4:07" are partially covered by the scrollbar track). Content needs right padding reserved for the scrollbar gutter.
* **Sidebar playlist list bleeding**: At reduced height, the last visible playlist row (e.g., "Bleienbusch Playlist") is sliced in half by the boundary with the "My Account" bar at the bottom of the sidebar. The playlist `ListView` does not anchor or clip cleanly against the fixed account footer.

### B. Navigation Sidebar & Account Menu
* **Sidebar Playlist Truncation**: Playlist names truncate hard with "…" (e.g., "Minecraft Music but perfectl…") and have no hover tooltip, making it impossible to read long names without opening them.
* **Account Menu Positioning**: Clicking the "⋮" opens a small menu containing only "Log out" (in red), but the popup overlaps directly on top of the "My Account" text, clipping it to "My Acc…". The menu should appear offset below or beside the button, and could include more options (like settings).
* **Missing Settings Page**: The sidebar contains no link or entry point to a settings page for user preferences.

### C. Player Bar (Bottom Controls)
* **Sliders Drag Bug (Volume + Seek Bar)**: Neither the Volume slider nor the SeekBar responds to dragging. Pressing down on the handle and moving the mouse leaves the handle frozen. However, clicking anywhere on the slider track immediately snaps the handle and applies the change. This indicates a shared root cause (e.g., lack of tracking `mouseX`/`mouseY` during drag in `SeekBar.qml` and `VolumeSlider.qml`).
* **Seek Bar Hover Tooltip**: There is no scrub-preview tooltip on hover showing the target time before committing to a click.
* **Volume Icon Style**: The mute/volume button renders as a colorful, rotated diagonal emoji glyph (🔊-style) rather than a flat vector icon. This stands out in a jarring way next to the flat monochrome icons.
* **Repeat Button States**: The "repeat all" state is visually identical to the "off" state (same grey icon, no color change or dot/badge). Only "repeat one" is distinguishable by its small "1" badge. Active states should turn cyan/accent-colored like Shuffle.
* **No Track Playing Placeholder**: When nothing is playing, the album art placeholder is a flat dark-grey square with no music note or icon, feeling unpolished.

### D. Global Icon Chromatic Aberration
* **Visual Fringing**: Vector icons (shuffle, prev, play, next, repeat, volume, and "⋮") show a distinct red/orange/blue/cyan ghosting halo along glyph edges, resembling RGB channel misregistration. This suggests sub-pixel rendering offsets, rendering scaling mismatches, or sub-pixel positioning issues in the layout.

### E. Search Page
* **Mouse-Wheel Scroll Block**: When viewing search results (Tracks, Albums, Artists), mouse-wheel scrolling anywhere on the results page does nothing. The scrollbar is visible and dragging it works, but wheel-scrolling is completely blocked.
* **Inconsistent Search Icons**: The sidebar search icon is a proper magnifying glass (circle + diagonal handle), but the Search page placeholder and empty-state icons are circles with straight vertical lines (resembling balloons/lollipops). The handle should be rotated ~45° for visual consistency.
* **Search Input Alignment**: The text input field vertical alignment is slightly off-center compared to the placeholder text.

### F. Collection Page
* **Tabs Click Hit-Box**: Tab buttons ("Tracks", "Albums", "Artists", "Playlists") only respond to clicks on the exact label text/pill. Clicks on the surrounding tab area do nothing, making the hit-box frustratingly small.
* **Playlist Cover Art Failures**: Every playlist card shows a flat, dark-grey empty square. No collage of track covers ever loads, making the page look unfinished.
* **Artist Card Shapes**: Circular artist avatars are mixed directly into a grid of square cover cards, breaking the visual consistency. Using square cards with circular profile boundaries inside them (or keeping cards uniform) would look cleaner.

### G. Playlist Page (e.g. "beats")
* **Flat Playlist Art**: Playlist art displays as a flat solid teal/cyan square without a placeholder icon or collage.
* **Track Row Hover Hit-Zone**: Hovering near the right edge of a track row (e.g., over duration/album) does not trigger the row hover state or reveal action buttons (`▶`, `⋯`). Hovering is only detected over the left/title area.
* **Right-Click Menu Block**: Right-clicking a track row does not open the context menu; only clicking the `⋯` button does. The `acceptedButtons: Qt.RightButton` is not working correctly on this page.
* **Menu Alignment**: The context menu items are inconsistently aligned. "Play now" and "Add to queue" have icons, but "Go to album" has no icon and appears horizontally centered, breaking the visual alignment.

### H. Album details Page
* **Unicode Header Blanking**: The title for the album `∄` (ID `476102046`) is completely invisible in the page header. Because the system font lacks the math symbol `∄` (U+2204), it fails to draw. The subtitle is present as a blue link `Fuse The Divide`, leaving a blank gap above it.

### I. Now Playing Page
* **Down Arrow Dismissal**: The back/dismiss button uses a down arrow (`↓`), which is conventionally used for collapse/download. A left chevron/back arrow would be more standard.
* **Broken Navigation Links**: The artist name (e.g., "Daft Punk") is styled as an active blue link, but clicking it does nothing. The album name ("Discovery") is plain grey text and cannot be clicked to go to the Album page.
* **Redundant Mini-Player Bar**: The page duplicates the mini-player bar at the very bottom of the screen, cluttering the view with redundant controls.

### J. Home Page Navigation
* **Hardcoded "View All" Links**: Every "View all →" link on the Home page routes to the same generic destination (the Collection page with the "Tracks" tab active), instead of deep-linking into their respective categories (e.g., "Saved Albums" should go to Collection/Albums; "My Mixes" should go to Collection/Playlists or a mixes page).
* **Mix Cover Styling**: The "My Daily Discovery" mix card uses a flat purple design with diamond sparkles, contrasting inconsistently with the collage-based designs of "My Mix 1-5".

---

## 3. Comprehensive List of Identified Improvements & Code Fixes

| ID | Component / Page | Issue / Bug Description | Root Cause / Technical Analysis | Recommended Solution |
| :--- | :--- | :--- | :--- | :--- |
| **01** | `SeekBar.qml`, `VolumeSlider.qml` | Sliders do not respond to dragging | Custom slider controls capture `onPressed`/`onClicked` but lack drag handling logic (`mouseX`/`mouseY` tracking). | Wire a `DragHandler` or update value calculations on mouse movement coordinates inside the MouseArea. |
| **02** | `AlbumPage.qml`, Card views | Unicode title rendering bug (blank headers) | System font lacks support for mathematical/special symbols (like `∄`). | Bundle a custom font (e.g., *Inter*) with complete unicode ranges, or add a fallback title check in QML. |
| **03** | `main.qml` | Redundant player controls in Now Playing page | Persistent `PlayerBar` is drawn at the bottom even when the fullscreen player is open. | Set `visible: auth.state === 2 && root.currentPage !== "nowplaying"` on `PlayerBar`. |
| **04** | `PlayerBar.qml`, `MediaCard.qml` | Emojis used for control icons | Volume glyphs (`🔇`/`🔊`), artists (`👤`), and music notes (`♪`) are raw color emojis that ignore theme colors. | Replace emojis with clean, custom vector SVG paths (using `PathSvg` similar to `NavIcon.qml`). |
| **05** | `SearchPage.qml` | Mouse-wheel scroll blocked | `HorizontalSection` mouse hover filters or overlapping bounds block wheel events from propagating to the parent ScrollView. | Ensure wheel events propagate correctly by avoiding interception or implementing wheel forwarding in `WheelHandler`. |
| **06** | `SearchPage.qml` | Lollipop-shaped search icon | The search icon uses a vertical handle instead of a 45-degree handle, making it look like a balloon. | Replace SVG path for the search icon with a standard diagonal magnifying glass path. |
| **07** | `HomePage.qml` | "View All" links route incorrectly | Navigation actions on sections are hardcoded to `navigateTo("collection")` without arguments. | Pass target tab indexes to the collection page (e.g., `root.navigate("collection", { activeTab: 1 })`). |
| **08** | `CollectionPage.qml` | Small click targets on tabs | Tab buttons only register hits on the exact text label boundaries. | Extend the MouseArea/TapHandler boundaries to cover the entire rounded pill shape. |
| **09** | `PlaylistPage.qml` | Flat solid color playlist covers | Collage generation or cover URL fetching is failing for playlists. | Implement cover-collage generation (combining covers of the first 4 tracks) or provide a styled placeholder gradient with a vector icon. |
| **10** | `TrackRow.qml` | Hover hit-zone limited to left side | Row layout contains margins or components that intercept hover events on the right-hand side. | Set `hoverEnabled: true` on the entire parent Rectangle of `TrackRow.qml` and ensure child elements do not block it. |
| **11** | `TrackRow.qml` | Right-click does not open context menu | `TapHandler` for right-click is either not receiving events or not triggering `contextMenu.popup()`. | Verify and fix the right-click `TapHandler` or `MouseArea` button filters. |
| **12** | `TrackRow.qml` | Context menu layout misalignment | "Go to album" `MenuItem` lacks a leading icon, making it center-aligned. | Add a placeholder space or standard icon prefix to the `text` or `contentItem` layout of the menu items. |
| **13** | `SideBar.qml` | Account menu overlaps trigger | Popup menu is positioned relative to coordinates that cover the "My Account" text. | Offset the menu coordinates to pop up above/beside the account bar. |
| **14** | `NowPlayingPage.qml` | Artist/Album links do not navigate | Click handlers are missing from the MouseAreas on the Artist and Album text fields. | Wire `onClicked` to navigate to the respective `artistId` or `albumId`. |
| **15** | `SideBar.qml` | Sidebar playlist names truncate with no tooltip | Tooltip support is missing on hovered playlist list items. | Add a `ToolTip` component to show the full name when hovering over truncated text. |
