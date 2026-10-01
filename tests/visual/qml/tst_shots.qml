// The screenshot scenes.
//
// This is not a test: nothing here asserts anything. It instantiates the real
// components against tests/TestStubs.h, in a window the right size, in one
// theme after another, and writes a PNG per combination so a human (or a model
// with eyes) can look at what 0.4.0 actually renders. The only reason it is a
// TestCase at all is that QtQuickTest already solves the two hard parts:
// standing a QML engine up with the app's context properties in it, and
// grabbing a live item to an image (grabImage, which is QQuickItem::grabToImage
// with the waiting done for you).
//
// There is no Tidal session on a developer box, so the library, the player bar
// and Now Playing cannot be reached by launching the app. They are reached
// here instead. The login page is the one thing a real unauthenticated launch
// does show, and run.sh shoots that from the real binary.
//
// No synthetic input reaches the X server: TestCase.mouseMove posts a Qt event
// straight to the scene's own window, in this process. That is the only way to
// get a genuine hover state out of a MouseArea or a HoverHandler, both of which
// expose it read-only.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtTest
import TidalWave

import "ShotLib.js" as S

TestCase {
    id: testCase
    name: "Shots"
    when: windowShown
    visible: true
    width: 400
    height: 300

    // Main.qml's default sidebar width, and the page width that leaves at a
    // 960px window: 960 - 220.
    readonly property int sidebarWidth: 220
    readonly property int pageWidth:    740

    // The user's half-screen size, which everything was designed against.
    readonly property int shellWidth:  960
    readonly property int shellHeight: 1200

    property var written: []

    // ── fixtures ─────────────────────────────────────────────────────────

    function init() {
        var q = S.tracks(6)
        player.setQueueForTest(q, 1)
        player.setCurrentTrackForTest(q[1])
        player.setAudioQualityForTest("HI_RES_LOSSLESS")
        player.setDurationForTest(318000)
        player.setPositionForTest(96000)
        player.setPlayingForTest(true)
        player.setVolume(0.72)
        player.setPlaybackSource("album", "42", "In Rainbows")
        player.setRecentlyPlayedForTest(S.tracks(4))

        bridge.setTrackFavoriteForTest(q[1].id, true)
        bridge.setUserPlaylistsForTest(S.playlists(4))

        cast.setDevicesForTest([{ id: "d1", name: "Living Room" }])

        auth.setStateForTest(2)              // LoggedIn; the sidebar needs it
        auth.setUsernameForTest("linus")

        library.setEntriesForTest(S.libraryEntries())
        library.setTracksForTest([])
        pins.setItemsForTest(S.pinItems())

        prefs.sidebarWidth = testCase.sidebarWidth
        prefs.language = "system"
    }

    function cleanupTestCase() {
        // Leave the harness's own settings file on the default, so a re-run
        // starts where the last one did.
        prefs.theme = "sea"
        console.log("shots written: " + testCase.written.length)
    }

    // ── helpers ──────────────────────────────────────────────────────────

    // Give the scene graph time to finish. Three steps rather than one sleep:
    // a frame to apply the bindings, a real render, then slack for the
    // Behaviors (the sidebar slide is 170ms) and for any image that is still
    // decoding.
    function settle(item, extra) {
        wait(1)
        waitForRendering(item, 4000)
        wait(extra === undefined ? 260 : extra)
    }

    function shot(item, name) {
        // Loud rather than a fallback: a missing output directory used to mean
        // forty PNGs quietly written to /tmp.
        verify(shotOutDir.length > 0, "TW_SHOT_OUT was not set")
        var img = grabImage(item)
        img.save(shotOutDir + "/" + name + ".png")
        testCase.written.push(name)
    }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    // ── scenes ───────────────────────────────────────────────────────────

    // The whole app at the size the user runs it: sidebar, a page, player bar.
    // Album rather than Home because it is the page with a hero, a cover, a
    // quality badge and a track list on it, so most of the tokens appear at
    // once.
    Component {
        id: shellC
        ShotWindow {
            id: win
            width: testCase.shellWidth
            height: testCase.shellHeight
            visible: true

            property alias sidebar: sb
            property alias page: pg
            property alias bar: pb

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0

                    SideBar {
                        id: sb
                        z: 2
                        hostWidth: win.width
                        Layout.preferredWidth: sb.reservedWidth
                        Layout.fillHeight: true
                        currentPage: "collection"
                    }
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        AlbumPage { id: pg; anchors.fill: parent }
                    }
                }

                PlayerBar { id: pb; Layout.fillWidth: true }
            }
        }
    }

    // The same shell, narrow enough that the sidebar is the 68px rail.
    Component {
        id: railC
        ShotWindow {
            id: win
            width: 640
            height: 900
            visible: true

            property alias sidebar: sb
            property alias page: pg

            ColumnLayout {
                anchors.fill: parent
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0
                    SideBar {
                        id: sb
                        z: 2
                        hostWidth: win.width
                        Layout.preferredWidth: sb.reservedWidth
                        Layout.fillHeight: true
                        currentPage: "home"
                    }
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        HomePage { id: pg; anchors.fill: parent }
                    }
                }
                PlayerBar { Layout.fillWidth: true }
            }
        }
    }

    // The sidebar on its own, full height, so the library rows and the pinned
    // block can be read at size.
    Component {
        id: sidebarC
        ShotWindow {
            id: win
            width: testCase.shellWidth
            height: testCase.shellHeight
            visible: true
            property alias sidebar: sb
            SideBar {
                id: sb
                hostWidth: win.width
                width: testCase.sidebarWidth
                height: win.height
                currentPage: "collection"
            }
        }
    }

    Component {
        id: playerBarC
        ShotWindow {
            id: win
            width: testCase.shellWidth
            height: 160
            visible: true
            property alias bar: pb
            PlayerBar {
                id: pb
                width: win.width
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // SettingsPanel is a Popup that lives inside SideBar and reparents itself
    // to the window overlay, so it is opened the way the app opens it rather
    // than instantiated bare.
    Component {
        id: settingsC
        ShotWindow {
            id: win
            width: testCase.shellWidth
            height: testCase.shellHeight
            visible: true
            property alias sidebar: sb
            SideBar {
                id: sb
                hostWidth: win.width
                width: testCase.sidebarWidth
                height: win.height
                currentPage: "home"
            }
        }
    }

    // A column of rows covering the four states one list shows at once:
    // ordinary, playing, hovered, and a search row with the popularity column.
    Component {
        id: trackRowsC
        ShotWindow {
            id: win
            width: 820
            height: 360
            visible: true
            property alias rows: col
            property alias hoverRow: r3
            Rectangle {
                anchors.fill: parent
                color: Theme.bg
                Column {
                    id: col
                    x: 16
                    y: 16
                    width: parent.width - 32
                    TrackRow {
                        width: col.width; trackNum: 1
                        title: S.track(0).title; artists: S.track(0).artists
                        albumTitle: S.track(0).albumTitle; durationStr: S.track(0).durationStr
                        coverUrl: S.track(0).coverUrl; trackData: S.track(0)
                    }
                    TrackRow {
                        width: col.width; trackNum: 2; isPlaying: true
                        title: S.track(1).title; artists: S.track(1).artists
                        albumTitle: S.track(1).albumTitle; durationStr: S.track(1).durationStr
                        coverUrl: S.track(1).coverUrl; trackData: S.track(1)
                    }
                    TrackRow {
                        id: r3
                        width: col.width; trackNum: 3
                        title: S.track(2).title; artists: S.track(2).artists
                        albumTitle: S.track(2).albumTitle; durationStr: S.track(2).durationStr
                        coverUrl: S.track(2).coverUrl; trackData: S.track(2)
                    }
                    TrackRow {
                        width: col.width; trackNum: 4; showPopularity: true
                        title: S.track(3).title; artists: S.track(3).artists
                        albumTitle: S.track(3).albumTitle; durationStr: S.track(3).durationStr
                        coverUrl: S.track(3).coverUrl; trackData: S.track(3)
                    }
                }
            }
        }
    }

    // One row, alone, grabbed twice at identical geometry: the only way to see
    // whether the title moves when the pointer arrives.
    Component {
        id: oneRowC
        ShotWindow {
            id: win
            width: 740
            height: 120
            visible: true
            property alias row: r
            Rectangle {
                anchors.fill: parent
                color: Theme.bg
                TrackRow {
                    id: r
                    x: 16
                    y: 34
                    width: parent.width - 32
                    trackNum: 7
                    title: S.track(0).title
                    artists: S.track(0).artists
                    albumTitle: S.track(0).albumTitle
                    durationStr: S.track(0).durationStr
                    coverUrl: S.track(0).coverUrl
                    trackData: S.track(0)
                }
            }
        }
    }


    // The two chip rows: the filter tabs and the sort toggle. Both put a label
    // on a solid accent fill when selected, which is the pairing the brief
    // asks after.
    Component {
        id: collectionC
        ShotWindow {
            id: win
            width: testCase.pageWidth
            height: 520
            visible: true
            property alias page: pg
            CollectionPage { id: pg; anchors.fill: parent }
        }
    }


    // Playlist and Mix are the two heroes whose gradient is accentTint rather
    // than the album page's black scrim, so the floating back button sits on a
    // pale ground there. That pairing is theme-dependent and the album page
    // cannot show it.
    Component {
        id: playlistC
        ShotWindow {
            id: win
            width: testCase.pageWidth
            height: 620
            visible: true
            property alias page: pg
            PlaylistPage { id: pg; anchors.fill: parent }
        }
    }

    Component {
        id: albumC
        ShotWindow {
            id: win
            width: testCase.pageWidth
            height: testCase.shellHeight
            visible: true
            property alias page: pg
            AlbumPage { id: pg; anchors.fill: parent }
        }
    }

    Component {
        id: nowPlayingC
        ShotWindow {
            id: win
            width: testCase.pageWidth
            height: testCase.shellHeight
            visible: true
            property alias page: pg
            NowPlayingPage { id: pg; anchors.fill: parent }
        }
    }

    // Above NowPlayingPage.stackBreakpoint (1000), where it goes two-column.
    Component {
        id: nowPlayingWideC
        ShotWindow {
            id: win
            width: 1280
            height: 860
            visible: true
            property alias page: pg
            NowPlayingPage { id: pg; anchors.fill: parent }
        }
    }

    // ── the shots ────────────────────────────────────────────────────────

    // The whole app, every theme. This is the one that has to be looked at
    // first, because a token only fails next to the others it ships with.
    function test_01_shell_data() {
        var rows = []
        for (var i = 0; i < S.allThemes.length; ++i)
            rows.push({ tag: S.allThemes[i], theme: S.allThemes[i] })
        return rows
    }
    function test_01_shell(row) {
        prefs.theme = row.theme
        var win = shellC.createObject(testCase)
        verify(win, "shell window was not created")
        win.page.albumId = 42
        win.page.albumData = S.albumData()
        win.page.tracks = S.tracks(10)
        settle(win.contentItem, 500)
        shot(win.contentItem, "shell_" + row.theme)
        win.destroy()
    }

    function test_02_sidebar_data() {
        var rows = []
        for (var i = 0; i < S.coreThemes.length; ++i)
            rows.push({ tag: S.coreThemes[i], theme: S.coreThemes[i] })
        return rows
    }
    function test_02_sidebar(row) {
        prefs.theme = row.theme
        var win = sidebarC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 500)
        shot(win.sidebar, "sidebar_" + row.theme)
        win.destroy()
    }

    function test_03_playerbar_data() { return test_02_sidebar_data() }
    function test_03_playerbar(row) {
        prefs.theme = row.theme
        var win = playerBarC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 400)
        shot(win.bar, "playerbar_" + row.theme)
        win.destroy()
    }

    function test_04_settings_data() { return test_02_sidebar_data() }
    function test_04_settings(row) {
        prefs.theme = row.theme
        var win = settingsC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 200)
        win.sidebar.openSettings()
        settle(win.contentItem, 500)
        shot(win.contentItem, "settings_" + row.theme)
        win.sidebar.settingsPanel.close()
        win.destroy()
    }

    // Scrolled far enough that the privacy block is on screen. The panel is
    // the one place in the app with a wall of body text in it, so it is where
    // a secondary-text token that is too pale shows up first.
    function test_05_settingsPrivacy_data() { return test_02_sidebar_data() }
    function test_05_settingsPrivacy(row) {
        prefs.theme = row.theme
        var win = settingsC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 200)
        win.sidebar.openSettings()
        settle(win.contentItem, 400)

        var panel = win.sidebar.settingsPanel
        var scroller = findByName(panel.contentItem, "settingsScroll")
        verify(scroller, "the settings ScrollView was not found")
        var flick = scroller.contentItem
        var privacy = findByName(flick.contentItem, "settingsPrivacyText")
        verify(privacy, "no privacy paragraph was found in the panel")

        // Put the first privacy paragraph a third of the way down the view, so
        // the heading above it and the paragraphs below are both in frame.
        var pos = privacy.mapToItem(flick.contentItem, 0, 0)
        flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height,
                                              pos.y - flick.height / 3))
        settle(win.contentItem, 400)
        shot(win.contentItem, "settings_privacy_" + row.theme)

        panel.close()
        win.destroy()
    }

    function test_06_trackRows_data() { return test_02_sidebar_data() }
    function test_06_trackRows(row) {
        prefs.theme = row.theme
        var win = trackRowsC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 400)
        // In-process, straight to this window: see the file header.
        mouseMove(win.hoverRow, win.hoverRow.width / 2, win.hoverRow.height / 2)
        settle(win.contentItem, 300)
        shot(win.rows, "trackrows_" + row.theme)
        win.destroy()
    }

    // The pair that answers "does the title shift on hover".
    function test_07_trackRowHover_data() { return test_02_sidebar_data() }
    function test_07_trackRowHover(row) {
        prefs.theme = row.theme

        var cold = oneRowC.createObject(testCase)
        verify(cold)
        settle(cold.contentItem, 300)
        shot(cold.row, "trackrow_plain_" + row.theme)
        var coldX = findByName(cold.row, "trackTitle").mapToItem(cold.row, 0, 0).x
        cold.destroy()

        var hot = oneRowC.createObject(testCase)
        verify(hot)
        settle(hot.contentItem, 300)
        mouseMove(hot.row, hot.row.width / 2, hot.row.height / 2)
        settle(hot.contentItem, 300)
        verify(hot.row.hovered, "the row never reported itself hovered")
        shot(hot.row, "trackrow_hover_" + row.theme)
        var hotX = findByName(hot.row, "trackTitle").mapToItem(hot.row, 0, 0).x
        hot.destroy()

        console.log("title x, " + row.theme + ": plain=" + coldX.toFixed(2)
                    + " hovered=" + hotX.toFixed(2))
    }

    function test_08_album_data() { return test_02_sidebar_data() }
    function test_08_album(row) {
        prefs.theme = row.theme
        var win = albumC.createObject(testCase)
        verify(win)
        win.page.albumId = 42
        win.page.albumData = S.albumData()
        win.page.tracks = S.tracks(12)
        settle(win.contentItem, 500)
        shot(win.page, "album_" + row.theme)
        win.destroy()
    }

    function test_09_nowPlaying_data() { return test_02_sidebar_data() }
    function test_09_nowPlaying(row) {
        prefs.theme = row.theme
        var win = nowPlayingC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 600)
        shot(win.page, "nowplaying_" + row.theme)
        win.destroy()
    }

    function test_10_nowPlayingWide_data() { return test_02_sidebar_data() }
    function test_10_nowPlayingWide(row) {
        prefs.theme = row.theme
        var win = nowPlayingWideC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 600)
        shot(win.page, "nowplaying_wide_" + row.theme)
        win.destroy()
    }

    // The rail, and the rail with the pointer on it. The light themes first,
    // because that is where a 68px strip of surface against a white page is
    // most likely to disappear.
    function test_11_rail_data() {
        return [{ tag: "sky",  theme: "sky" },
                { tag: "sand", theme: "sand" },
                { tag: "sea",  theme: "sea" }]
    }
    function test_11_rail(row) {
        prefs.theme = row.theme

        var cold = railC.createObject(testCase)
        verify(cold)
        settle(cold.contentItem, 500)
        verify(cold.sidebar.compact, "the sidebar did not go compact at 640")
        shot(cold.contentItem, "rail_" + row.theme)
        cold.destroy()

        var hot = railC.createObject(testCase)
        verify(hot)
        settle(hot.contentItem, 500)
        // Over the rail itself, which is what brings the overlay out.
        mouseMove(hot.sidebar, 30, 300)
        settle(hot.contentItem, 500)
        verify(hot.sidebar.hoverExpanded, "the rail never hover-expanded")
        shot(hot.contentItem, "rail_hover_" + row.theme)
        hot.destroy()
    }

    // The chips, every theme, because a selected chip is where accentInk lands.
    function test_12_chips_data() {
        var rows = []
        for (var i = 0; i < S.allThemes.length; ++i)
            rows.push({ tag: S.allThemes[i], theme: S.allThemes[i] })
        return rows
    }
    function test_12_chips(row) {
        prefs.theme = row.theme
        var win = collectionC.createObject(testCase)
        verify(win)
        win.page.activeTab = 1
        win.page.sortMode = 1
        win.page.filteredTracks = S.tracks(6)
        win.page.filteredAlbums = S.albums(8)
        win.page.filteredArtists = S.artists(5)
        win.page.filteredPlaylists = S.playlists(4)
        win.page.mixes = S.mixes(3)
        settle(win.contentItem, 500)
        shot(win.page, "chips_" + row.theme)
        win.destroy()
    }

    function test_13_playlist_data() { return test_02_sidebar_data() }
    function test_13_playlist(row) {
        prefs.theme = row.theme
        var win = playlistC.createObject(testCase)
        verify(win)
        win.page.playlistUuid = "uuid-0"
        win.page.playlistType = "USER"
        win.page.playlistTitle = "Late Night Drive"
        win.page.playlistDescription = "Thirty-odd tracks that go together."
        win.page.playlistDuration = 5400
        win.page.coverUrl = "cover/pl0"
        win.page.tracks = S.tracks(8)
        settle(win.contentItem, 500)
        shot(win.page, "playlist_" + row.theme)
        win.destroy()
    }
}
