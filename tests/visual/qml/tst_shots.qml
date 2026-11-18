// The screenshot scenes. Nothing here asserts on the app: the real components
// are instantiated against tests/TestStubs.h, one theme after another, and a
// PNG is written per combination. It is a TestCase because QtQuickTest sets up
// the engine with the app's context properties and can grab a live item.
// TestCase.mouseMove posts a Qt event to the scene's own window in this
// process, which is the only way to get a real hover state.

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

    // The window size the layout was designed against.
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
        player.setPlaybackSource("album", "42", "Salt Lines")
        player.setRecentlyPlayedForTest(S.tracks(4))

        bridge.setTrackFavoriteForTest(q[1].id, true)
        bridge.setUserPlaylistsForTest(S.playlists(4))

        cast.setDevicesForTest([{ id: "d1", name: "Living Room" }])

        auth.setStateForTest(2)              // LoggedIn; the sidebar needs it
        auth.setUsernameForTest("robin")

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

    // Give the scene graph time to finish: a frame to apply the bindings, a
    // real render, then slack for the Behaviors (the sidebar slide is 170ms)
    // and for any image still decoding.
    function settle(item, extra) {
        wait(1)
        waitForRendering(item, 4000)
        wait(extra === undefined ? 260 : extra)
    }

    function shot(item, name) {
        // Fails loudly when the output directory is missing.
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

    // The whole app: sidebar, a page, player bar. The album page has a hero, a
    // cover, a quality badge and a track list, so most tokens appear at once.
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
                        width: col.width; trackNum: 4
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
    // on a solid accent fill when selected.
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


    // Playlist and Mix are the two heroes whose gradient is accentTint, so the
    // floating back button sits on a pale ground there.
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

    // The remaining detail pages and the two pages with a tab strip, so the
    // shared scaffold and controls are seen everywhere they are used.
    Component {
        id: mixC
        ShotWindow {
            width: testCase.pageWidth; height: 620; visible: true
            property alias page: pg
            MixPage { id: pg; anchors.fill: parent }
        }
    }
    Component {
        id: artistC
        ShotWindow {
            width: testCase.pageWidth; height: 900; visible: true
            property alias page: pg
            ArtistPage { id: pg; anchors.fill: parent }
        }
    }
    Component {
        id: radioC
        ShotWindow {
            width: testCase.pageWidth; height: 620; visible: true
            property alias page: pg
            RadioPage { id: pg; anchors.fill: parent }
        }
    }
    Component {
        id: searchC
        ShotWindow {
            width: testCase.pageWidth; height: 700; visible: true
            property alias page: pg
            SearchPage { id: pg; anchors.fill: parent }
        }
    }
    Component {
        id: collectionTallC
        ShotWindow {
            width: testCase.pageWidth; height: 700; visible: true
            property alias page: pg
            CollectionPage { id: pg; anchors.fill: parent }
        }
    }

    Component {
        id: homeC
        ShotWindow {
            width: testCase.pageWidth; height: 900; visible: true
            property alias page: pg
            HomePage { id: pg; anchors.fill: parent }
        }
    }
    Component {
        id: homeTallC
        ShotWindow {
            width: testCase.pageWidth; height: 2700; visible: true
            property alias page: pg
            HomePage { id: pg; anchors.fill: parent }
        }
    }
    Component {
        id: loginC
        ShotWindow {
            width: testCase.pageWidth; height: 700; visible: true
            property alias page: pg
            LoginPage { id: pg; anchors.fill: parent }
        }
    }

    // ── the shots ────────────────────────────────────────────────────────

    // The whole app, every theme: a token only fails next to the others it
    // ships with.
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

    // A Dolby Atmos only album with the row of its other versions: the facts
    // line and the second line of each card are what this shot is for.
    function test_08_albumVersions_data() { return test_02_sidebar_data() }
    function test_08_albumVersions(row) {
        prefs.theme = row.theme
        function version(id, title, explicit_, quality, modes, tags) {
            return { id: id, title: title, artists: "Brackwater", year: "2007",
                     coverUrl: "cover/album1", quality: quality, explicit_: explicit_,
                     audioModes: modes, mediaTags: tags }
        }
        bridge.setOtherVersionsForTest([
            version(301, "Salt Lines", true, "LOSSLESS", ["STEREO"],
                    ["LOSSLESS", "HIRES_LOSSLESS"]),
            version(302, "Salt Lines", false, "LOSSLESS", ["STEREO"], ["LOSSLESS"]),
            version(303, "Salt Lines", false, "LOW", ["DOLBY_ATMOS"], ["DOLBY_ATMOS"]),
            version(304, "Salt Lines (Deluxe Edition)", true, "HIGH", ["STEREO"], [])
        ])
        var win = albumC.createObject(testCase)
        verify(win)
        win.page.albumId = 300
        var album = S.albumData()
        album.quality = "LOW"
        album.explicit_ = true
        album.audioModes = ["DOLBY_ATMOS"]
        album.mediaTags = ["DOLBY_ATMOS"]
        win.page.albumData = album
        win.page.tracks = S.tracks(5)
        settle(win.contentItem, 500)
        shot(win.page, "album_versions_" + row.theme)
        win.destroy()
        bridge.resetOtherVersionsForTest()
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

    // The rail, and the rail with the pointer on it. A 68px strip of surface
    // against a white page is easiest to lose on the light themes.
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
        win.page.savedTracks = S.tracks(6)
        win.page.savedAlbums = S.albums(8)
        win.page.savedArtists = S.artists(5)
        win.page.savedPlaylists = S.playlists(4)
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
        win.page.playlistEditable = true
        win.page.playlistTitle = "Late Night Drive"
        win.page.playlistDescription = "Thirty-odd tracks that go together."
        win.page.playlistDuration = 5400
        win.page.coverUrl = "cover/pl0"
        win.page.tracks = S.tracks(8)
        settle(win.contentItem, 500)
        shot(win.page, "playlist_" + row.theme)
        win.destroy()
    }

    function test_14_mix_data() { return test_02_sidebar_data() }
    function test_14_mix(row) {
        prefs.theme = row.theme
        bridge.setMixPageForTest({ title: "My Mix 1", subtitle: "Brackwater, Vellum Coast and more",
                                   coverUrl: "cover/mix0", mixType: "DISCOVERY_MIX" }, S.tracks(8))
        var win = mixC.createObject(testCase)
        verify(win)
        win.page.mixId = "mix-0"
        settle(win.contentItem, 500)
        shot(win.page, "mix_" + row.theme)
        win.destroy()
    }

    function test_15_artist_data() { return test_02_sidebar_data() }
    function test_15_artist(row) {
        prefs.theme = row.theme
        var albums = S.albums(5)
        for (var i = 0; i < albums.length; ++i) albums[i].section = (i < 3) ? "a" : "s"
        bridge.setArtistForTest({ id: 7, name: "Brackwater", coverUrl: "cover/artist0",
                                  coverUrl750: "cover/artist0",
                                  bio: "A four-piece from a coastal town, known for long instrumental codas." },
                                S.tracks(6), albums)
        bridge.setSimilarArtistsForTest(S.artists(4))
        var win = artistC.createObject(testCase)
        verify(win)
        win.page.artistId = 7
        settle(win.contentItem, 600)
        shot(win.page, "artist_" + row.theme)
        win.destroy()
        bridge.setSimilarArtistsForTest([])
    }

    function test_16_radio_data() { return test_02_sidebar_data() }
    function test_16_radio(row) {
        prefs.theme = row.theme
        bridge.setTrackRadioForTest(S.tracks(8))
        var win = radioC.createObject(testCase)
        verify(win)
        win.page.radioTitle = "Pilot Light"
        win.page.trackId = 100004
        settle(win.contentItem, 500)
        shot(win.page, "radio_" + row.theme)
        win.destroy()
    }

    function test_17_search_data() { return test_02_sidebar_data() }
    function test_17_search(row) {
        prefs.theme = row.theme
        bridge.setSearchResultsForTest(S.tracks(5), S.albums(4), S.artists(4), S.playlists(3))
        var win = searchC.createObject(testCase)
        verify(win)
        win.page.searchFor("salt lines")
        settle(win.contentItem, 600)
        shot(win.page, "search_" + row.theme)
        win.destroy()
    }

    function test_18_collectionTracks_data() { return test_02_sidebar_data() }
    function test_18_collectionTracks(row) {
        prefs.theme = row.theme
        var win = collectionTallC.createObject(testCase)
        verify(win)
        win.page.activeTab = 0
        win.page.savedTracks = S.tracks(6)
        win.page.savedAlbums = S.albums(8)
        win.page.savedArtists = S.artists(5)
        win.page.savedPlaylists = S.playlists(4)
        settle(win.contentItem, 500)
        shot(win.page, "collection_tracks_" + row.theme)
        win.destroy()
    }

    // A dialog over the page: the Cancel and confirm pair, and the edit form.
    function test_19_dialogs_data() { return test_02_sidebar_data() }
    function test_19_dialogs(row) {
        prefs.theme = row.theme
        var win = playlistC.createObject(testCase)
        verify(win)
        win.page.playlistUuid = "uuid-0"
        win.page.playlistTitle = "Late Night Drive"
        win.page.playlistEditable = true
        win.page.tracks = S.tracks(8)
        settle(win.contentItem, 400)
        win.page.editPopup.open()
        settle(win.contentItem, 500)
        shot(win.contentItem, "dialog_edit_" + row.theme)
        win.page.editPopup.close()
        settle(win.contentItem, 300)
        win.page.deleteDialog.askFor("uuid-0", "Late Night Drive")
        settle(win.contentItem, 500)
        shot(win.contentItem, "dialog_confirm_" + row.theme)
        win.destroy()
    }

    // The sleep timer menu, which carries the second toggle.
    function test_20_sleep_data() { return test_02_sidebar_data() }
    function test_20_sleep(row) {
        prefs.theme = row.theme
        var win = nowPlayingWideC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 500)
        // A Popup is not an Item, so it is found through `data`.
        function walk(o, depth) {
            if (!o || depth > 40) return null
            if (o.objectName === "nowPlayingSleepTimerPopup") return o
            var kids = o.data || []
            for (var i = 0; i < kids.length; ++i) {
                var hit = walk(kids[i], depth + 1)
                if (hit) return hit
            }
            return null
        }
        var popup = walk(win.page, 0)
        verify(popup, "the sleep timer popup was not found")
        popup.open()
        settle(win.contentItem, 500)
        shot(win.contentItem, "sleep_" + row.theme)
        win.destroy()
    }

    // Two card rows at the page width, the last card cut off at the edge.
    Component {
        id: rowsC
        ShotWindow {
            width: testCase.pageWidth; height: 560; visible: true
            property alias first: a
            property alias second: b
            Column {
                y: 16; width: parent.width; spacing: 24
                HorizontalSection { id: a; title: "Recently played"; mediaType: "album" }
                HorizontalSection { id: b; title: "My playlists"; mediaType: "playlist" }
            }
        }
    }
    function test_21_cardRows_data() { return test_02_sidebar_data() }
    function test_21_cardRows(row) {
        prefs.theme = row.theme
        var win = rowsC.createObject(testCase)
        verify(win)
        win.first.items = S.albums(6).concat(S.albums(6))
        win.second.items = S.playlists(4)
        settle(win.contentItem, 500)
        shot(win.contentItem, "cardrows_" + row.theme)
        // One card along, so both edge arrows show.
        win.first.scrollTo(win.first.minX + win.first.cardSize + win.first.listSpacing)
        settle(win.contentItem, 300)
        shot(win.contentItem, "cardrows_scrolled_" + row.theme)
        win.destroy()
    }

    // The queue with a manual section long enough to show the grips.
    Component {
        id: queueC
        ShotWindow {
            width: 420; height: 760; visible: true
            QueuePanel { anchors.fill: parent }
        }
    }
    function test_22_queue_data() { return test_02_sidebar_data() }
    function test_22_queue(row) {
        prefs.theme = row.theme
        player.setManualForTest(S.tracks(4))
        var win = queueC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 500)
        shot(win.contentItem, "queue_" + row.theme)
        win.destroy()
        player.setManualForTest([])
    }

    // Settings scrolled to the shortcut table.
    function test_23_settingsShortcuts_data() { return test_02_sidebar_data() }
    function test_23_settingsShortcuts(row) {
        prefs.theme = row.theme
        var win = settingsC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 200)
        win.sidebar.openSettings()
        settle(win.contentItem, 400)
        var panel = win.sidebar.settingsPanel
        var flick = findByName(panel.contentItem, "settingsScroll").contentItem
        var key = findByName(flick.contentItem, "settingsShortcutKey")
        verify(key, "the shortcut table was not found")
        var pos = key.mapToItem(flick.contentItem, 0, 0)
        flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, pos.y - 80))
        settle(win.contentItem, 400)
        shot(win.contentItem, "settings_shortcuts_" + row.theme)
        panel.close()
        win.destroy()
    }

    // Now Playing with the lyrics open, windowed and stacked.
    function test_24_nowPlayingLyrics_data() { return test_02_sidebar_data() }
    function test_24_nowPlayingLyrics(row) {
        prefs.theme = row.theme
        bridge.setLyricsForTest("The tide came in at four\nAnd took the pier lights out\n"
                                + "We stood where the rails had been\nCounting the boats by sound\n"
                                + "Nobody said a word\nThe radio said rain", false)
        var comps = [nowPlayingWideC, nowPlayingC]
        var names = ["nowplaying_lyrics_wide_", "nowplaying_lyrics_"]
        for (var i = 0; i < comps.length; ++i) {
            var win = comps[i].createObject(testCase)
            verify(win)
            settle(win.contentItem, 400)
            win.page.showLyrics = true
            settle(win.contentItem, 700)
            shot(win.page, names[i] + row.theme)
            win.destroy()
        }
    }

    // Fullscreen Now Playing on a 1920x1080 screen.
    Component {
        id: nowPlayingFullC
        ShotWindow {
            id: fw
            width: 1920; height: 1080; visible: true
            property bool fullScreen: true
            function toggleFullScreen() { fullScreen = !fullScreen }
            property alias page: pg
            NowPlayingPage { id: pg; anchors.fill: parent }
        }
    }
    function test_25_nowPlayingFullscreen_data() { return test_02_sidebar_data() }
    function test_25_nowPlayingFullscreen(row) {
        prefs.theme = row.theme
        var win = nowPlayingFullC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 600)
        shot(win.page, "nowplaying_fullscreen_" + row.theme)
        win.destroy()
    }

    // ── design pass 2 ────────────────────────────────────────────────────

    function allThemes_data() {
        var rows = []
        for (var i = 0; i < S.allThemes.length; ++i)
            rows.push({ tag: S.allThemes[i], theme: S.allThemes[i] })
        return rows
    }
    function pair_data() { return [{ tag: "sea", theme: "sea" }, { tag: "sky", theme: "sky" }] }

    function cardItems(list, type) {
        var out = []
        for (var i = 0; i < list.length; ++i)
            out.push({ id: list[i].id || list[i].uuid, title: list[i].title || list[i].name,
                       subtitle: list[i].artists || list[i].subtitle || "",
                       coverUrl: list[i].coverUrl, type: type })
        return out
    }
    function fillHome(page) {
        page.mixes = cardItems(S.mixes(5), "mix")
        page.recentAlbums = cardItems(S.albums(6), "album")
        page.playlists = cardItems(S.playlists(5), "playlist")
        page.artists = cardItems(S.artists(5), "artist")
    }

    // Home: the header over the rows, and a card under the pointer.
    function test_21_home_data() { return allThemes_data() }
    function test_21_home(row) {
        prefs.theme = row.theme
        player.setPlayingForTest(false)
        var win = homeC.createObject(testCase)
        verify(win)
        fillHome(win.page)
        settle(win.contentItem, 600)
        shot(win.page, "home_" + row.theme)

        var art = findByName(win.page, "cardArt")
        verify(art, "no card on Home")
        mouseMove(art, art.width / 2, art.height / 2)
        settle(win.contentItem, 400)
        shot(win.page, "home_hover_" + row.theme)
        win.destroy()
        player.setPlayingForTest(true)
    }

    // A row's menu, open, with the pointer on one of its entries.
    function test_22_menu_data() { return pair_data() }
    function test_22_menu(row) {
        prefs.theme = row.theme
        var win = trackRowsC.createObject(testCase)
        verify(win)
        win.width = 820; win.height = 700
        var r = win.hoverRow
        r.playlistUuid = "uuid-0"
        r.trackItemIndex = 2
        settle(win.contentItem, 300)
        mouseMove(r, r.width * 0.6, r.height / 2)
        r.openMenu()
        settle(win.contentItem, 400)
        var m = r.rowMenu
        verify(m, "the row menu did not open")
        var entry = m.itemAt(2)
        if (entry) mouseMove(entry, entry.width / 2, entry.height / 2)
        settle(win.contentItem, 300)
        shot(win.contentItem, "menu_" + row.theme)
        m.close()
        win.destroy()
    }

    // Each page while it is still loading.
    function test_23_loading_data() { return pair_data() }
    function test_23_loading(row) {
        prefs.theme = row.theme
        var w1 = albumC.createObject(testCase)
        verify(w1)
        w1.page.albumId = 42
        w1.page.loading = true
        settle(w1.contentItem, 500)
        shot(w1.page, "loading_album_" + row.theme)
        w1.destroy()

        var w2 = homeC.createObject(testCase)
        verify(w2)
        w2.page.mixes = []; w2.page.recentAlbums = []; w2.page.playlists = []; w2.page.artists = []
        w2.page.loading = true
        settle(w2.contentItem, 500)
        shot(w2.page, "loading_home_" + row.theme)
        w2.destroy()

        bridge.setKindLoadingForTest("albums", true)
        var w3 = collectionTallC.createObject(testCase)
        verify(w3)
        w3.page.activeTab = 1
        w3.page.savedAlbums = []
        settle(w3.contentItem, 500)
        shot(w3.page, "loading_collection_" + row.theme)
        w3.destroy()
        bridge.setKindLoadingForTest("albums", false)

        var w4 = playlistC.createObject(testCase)
        verify(w4)
        w4.page.playlistTitle = "Late Night Drive"
        w4.page.loading = true
        settle(w4.contentItem, 500)
        shot(w4.page, "loading_playlist_" + row.theme)
        w4.destroy()
    }

    // The two waiting states of the sign-in card.
    function test_24_login_data() { return pair_data() }
    function test_24_login(row) {
        prefs.theme = row.theme
        auth.setDeviceCodeForTest("WXYZ-1234", "https://link.tidal.com/WXYZ1234")
        auth.setStateForTest(1)
        var win = loginC.createObject(testCase)
        verify(win)
        settle(win.contentItem, 700)
        shot(win.page, "login_waiting_" + row.theme)
        win.destroy()
        auth.setStateForTest(2)
    }

    // A confirmation, and a removal from a playlist.
    function test_25_toast_data() { return allThemes_data() }
    function test_25_toast(row) {
        prefs.theme = row.theme
        var win = trackRowsC.createObject(testCase)
        verify(win)
        win.width = 820; win.height = 420
        settle(win.contentItem, 300)
        win.hoverRow.addToPlaylist("uuid-0", "Late Night Drive")
        settle(win.contentItem, 400)
        shot(win.contentItem, "toast_added_" + row.theme)
        win.destroy()

        var pw = playlistC.createObject(testCase)
        verify(pw)
        pw.page.playlistUuid = "uuid-0"
        pw.page.playlistEditable = true
        pw.page.playlistTitle = "Late Night Drive"
        pw.page.loading = false
        pw.page.tracks = S.tracks(8)
        settle(pw.contentItem, 400)
        var prow = findByName(pw.page, "playlistTrackRow")
        verify(prow)
        prow.removeFromPlaylistRequested(prow.trackItemIndex)
        settle(pw.contentItem, 500)
        shot(pw.contentItem, "toast_removed_" + row.theme)
        pw.destroy()
        Toasts.dismiss()
        Edits.clearHistory()
    }

    // The pointer on a short sidebar row, then on one whose name is cut off.
    function test_26_sidebarTip_data() { return pair_data() }
    function test_26_sidebarTip(row) {
        prefs.theme = row.theme
        var entries = S.libraryEntries()
        entries[3].title = "A Very Long Artist Name That Will Not Fit Here"
        library.setEntriesForTest(entries)
        var win = sidebarC.createObject(testCase)
        verify(win)
        win.height = 700
        settle(win.contentItem, 500)
        var rows = []
        function walk(it) {
            if (!it) return
            if (it.objectName === "libraryRowTitle") rows.push(it)
            for (var i = 0; i < it.children.length; ++i) walk(it.children[i])
        }
        walk(win.sidebar)
        verify(rows.length > 4, "no library rows")
        var shortRow = rows[2].parent
        mouseMove(shortRow, shortRow.width / 2, shortRow.height / 2)
        wait(Theme.tooltipDelay + 300)
        settle(win.contentItem, 200)
        shot(win.contentItem, "sidebar_tip_short_" + row.theme)
        var longRow = null
        for (var k = 0; k < rows.length; ++k)
            if (rows[k].text.indexOf("Very Long") >= 0) longRow = rows[k].parent
        verify(longRow)
        mouseMove(longRow, longRow.width / 2, longRow.height / 2)
        wait(Theme.tooltipDelay + 300)
        settle(win.contentItem, 200)
        shot(win.contentItem, "sidebar_tip_long_" + row.theme)
        win.destroy()
        library.setEntriesForTest(S.libraryEntries())
    }

    // A playlist with no cover of its own, whose first tracks share covers,
    // and rows, a player bar and a card with no cover at all.
    function test_27_covers_data() { return pair_data() }
    function test_27_covers(row) {
        prefs.theme = row.theme
        var t = S.tracks(8)
        var covers = ["cover/1", "cover/1", "cover/2", "cover/1", "cover/2", "cover/3", "cover/1", "cover/2"]
        for (var i = 0; i < t.length; ++i) { t[i].coverUrl = covers[i]; t[i].coverUrl80 = covers[i] }
        var win = playlistC.createObject(testCase)
        verify(win)
        win.page.playlistUuid = "uuid-0"
        win.page.playlistTitle = "Two Albums"
        win.page.coverUrl = ""
        win.page.loading = false
        win.page.tracks = t
        settle(win.contentItem, 500)
        shot(win.page, "mosaic_three_" + row.theme)
        covers = ["cover/1", "cover/1", "cover/2", "cover/1", "cover/2", "cover/1", "cover/1", "cover/2"]
        t = S.tracks(8)
        for (var j = 0; j < t.length; ++j) { t[j].coverUrl = covers[j]; t[j].coverUrl80 = covers[j] }
        win.page.tracks = t
        settle(win.contentItem, 500)
        shot(win.page, "mosaic_two_" + row.theme)
        win.destroy()

        var bare = S.tracks(6)
        for (var k = 0; k < bare.length; ++k) { bare[k].coverUrl = ""; bare[k].coverUrl80 = ""; bare[k].albumCover = "" }
        player.setQueueForTest(bare, 1)
        player.setCurrentTrackForTest(bare[1])
        var bw = playerBarC.createObject(testCase)
        verify(bw)
        settle(bw.contentItem, 400)
        shot(bw.bar, "nocover_playerbar_" + row.theme)
        bw.destroy()

        var rw = trackRowsC.createObject(testCase)
        verify(rw)
        var kids = rw.rows.children
        for (var n = 0; n < kids.length; ++n) kids[n].coverUrl = ""
        settle(rw.contentItem, 400)
        shot(rw.rows, "nocover_rows_" + row.theme)
        rw.destroy()
    }

    // ── Tidal's own Home ─────────────────────────────────────────────────
    // Home with the rows of Tidal's feed. Its titles come from Tidal; the
    // German ones here stand in for what de_DE sends.
    function feedPage(de) {
        function t(en, ger) { return de ? ger : en }
        function al(i, title, artist) {
            return { kind: "album", id: 900 + i, title: title, artists: artist, coverUrl: "cover/feed" + i }
        }
        function pl(i, title, n) {
            return { kind: "playlist", uuid: "feed-pl-" + i, title: title, numTracks: n,
                     coverUrl: "cover/feedpl" + i, type: "EDITORIAL" }
        }
        function ar(i, name) { return { kind: "artist", id: 950 + i, name: name, coverUrl: "cover/feedar" + i } }
        function mx(i, title) {
            return { kind: "mix", id: "feed-mix-" + i, title: title, subtitle: "Lumen Drift, Vellum Coast",
                     coverUrl: "cover/feedmx" + i, mixType: "HISTORY_MONTHLY_MIX" }
        }
        function own(id, r) { return { id: id, title: id, ownRow: r, mediaType: "recent", items: [] } }
        function row(id, title, type, items, context) {
            return { id: id, title: title, context: context || "", ownRow: "", mediaType: type, items: items }
        }
        return {
            tabs: [{ name: t("For you", "Für dich"), feed: "static" },
                   { name: t("Staff Picks", "Wir empfehlen"), feed: "editorial" }],
            modules: [
                own("DAILY_MIXES", "mixes"), own("CONTINUE_LISTEN_TO", "recent"),
                row("NEW_ALBUM_SUGGESTIONS", t("Suggested new albums for you", "Neue Alben-Vorschläge für dich"), "album",
                    [al(0, "Glass Harbour", "Kestrel Arcade"), al(1, "Paper Moons", "Odd Lantern Club"),
                     al(2, "Static Bloom", "Slate Meridian"), al(3, "Low Tide", "Vellum Coast"),
                     al(4, "Copperline", "Lumen Drift")]),
                row("BECAUSE_YOU_LISTENED_TO_ALBUM", t("Because you listened to", "Zuletzt angehört:"), "album",
                    [al(5, "Driftwood", "Odd Lantern Club"), al(6, "Night Ferry", "Kestrel Arcade"),
                     al(7, "Hollow Pines", "Brackwater")], "Salt Lines"),
                row("BASED_ON_YOUR_INTERESTS_1", t("Dream Pop & more", "Dream Pop & mehr"), "recent",
                    [ar(0, "Lumen Drift"), pl(0, "Dream Pop Essentials", 40), al(8, "Soft Focus", "Vellum Coast"),
                     ar(1, "Slate Meridian")]),
                own("YOUR_FAVORITE_ARTISTS", "artists"),
                row("SUGGESTED_ESSENTIAL_PLAYLISTS", t("Essentials to explore", "Essentials zum Entdecken"), "playlist",
                    [pl(1, "Brackwater: Essentials", 30), pl(2, "Kestrel Arcade: Essentials", 25),
                     pl(3, "Shoegaze Essentials", 50)]),
                own("MY_PLAYLISTS", "playlists"),
                row("POPULAR_PLAYLISTS", t("Popular playlists on Tidal", "Beliebte Playlists auf Tidal"), "playlist",
                    [pl(4, "Top Hits", 50), pl(5, "Rising", 40), pl(6, "Indie Now", 60), pl(7, "Chill", 80)]),
                row("HISTORY_MIXES", t("Your listening history", "Dein Hörverlauf"), "mix",
                    [mx(0, t("My October", "Mein Oktober")), mx(1, t("My September", "Mein September"))])
            ]
        }
    }
    function staffPage(de) {
        var p = feedPage(de)
        return { tabs: p.tabs, modules: [
            { id: "STAFF_ALBUMS", title: de ? "Alben ohne Skips" : "Albums with no skips", context: "",
              ownRow: "", mediaType: "album", items: p.modules[2].items },
            { id: "STAFF_PLAYLISTS", title: de ? "Playlists, die wir lieben" : "Playlists we love", context: "",
              ownRow: "", mediaType: "playlist", items: p.modules[6].items }] }
    }

    // small: a few saved things; empty: none; failed: the feed is down and
    // nothing is cached; staff: the staff picks tab.
    function test_28_home_feed_data() {
        var rows = []
        var themes = [{ n: "dark", t: "sea" }, { n: "light", t: "sky" }]
        for (var i = 0; i < themes.length; ++i) {
            rows.push({ tag: "small-en-" + themes[i].n, what: "small", de: false, theme: themes[i].t, name: themes[i].n })
            rows.push({ tag: "small-de-" + themes[i].n, what: "small", de: true, theme: themes[i].t, name: themes[i].n })
            rows.push({ tag: "empty-en-" + themes[i].n, what: "empty", de: false, theme: themes[i].t, name: themes[i].n })
            rows.push({ tag: "failed-en-" + themes[i].n, what: "failed", de: false, theme: themes[i].t, name: themes[i].n })
            rows.push({ tag: "staff-en-" + themes[i].n, what: "staff", de: false, theme: themes[i].t, name: themes[i].n })
            rows.push({ tag: "staff-de-" + themes[i].n, what: "staff", de: true, theme: themes[i].t, name: themes[i].n })
        }
        return rows
    }
    function test_28_home_feed(row) {
        prefs.theme = row.theme
        if (row.de) bridge.useCatalogueForTest("de")
        player.setPlayingForTest(false)
        library.setEntriesForTest([])
        bridge.setHomeFeedForTest("static", feedPage(row.de), row.what === "failed" ? "Host unreachable" : "")
        bridge.setHomeFeedForTest("editorial", staffPage(row.de))
        var win = homeTallC.createObject(testCase)
        verify(win)
        var p = win.page
        if (row.what === "small" || row.what === "failed" || row.what === "staff") {
            p.mixes = cardItems(S.mixes(2), "mix")
            p.recentAlbums = cardItems(S.albums(2), "album")
            p.playlists = cardItems(S.playlists(1), "playlist")
            p.artists = cardItems(S.artists(2), "artist")
        } else {
            p.mixes = []; p.recentAlbums = []; p.playlists = []; p.artists = []
        }
        if (row.what === "staff") findByName(p, "homeTabsRow").activated(1)
        settle(win.contentItem, 700)
        shot(p, "tw-home-" + row.what + (row.de ? "-de-" : "-") + row.name)
        win.destroy()
        if (row.de) bridge.useCatalogueForTest("")
        library.setEntriesForTest(S.libraryEntries())
        player.setPlayingForTest(true)
    }
}
