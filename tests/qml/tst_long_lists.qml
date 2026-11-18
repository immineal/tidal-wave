// Long lists stay easy to move through: every long list's scroll handle keeps
// a length the pointer can find, and a wheel notch moves a long list by the
// system's lines per notch, as Settings does. Every title is invented.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "LongLists"
    when: windowShown
    visible: true
    width: 1300
    height: 800

    Component { id: holderC;     Item { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: albumC;      AlbumPage      { anchors.fill: parent } }
    Component { id: playlistC;   PlaylistPage   { anchors.fill: parent } }
    Component { id: mixC;        MixPage        { anchors.fill: parent } }
    Component { id: radioC;      RadioPage      { anchors.fill: parent } }
    Component {
        id: sideHostC
        Window {
            width: 960; height: 700
            property alias sidebar: sb
            RowLayout {
                anchors.fill: parent
                SideBar {
                    id: sb
                    hostWidth: 960
                    Layout.preferredWidth: sb.reservedWidth
                    Layout.fillHeight: true
                }
                Item { Layout.fillWidth: true; Layout.fillHeight: true }
            }
        }
    }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
    }
    function cleanup() {
        bridge.setFavoriteTracksListForTest([])
    }

    function manyTracks(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 5000 + i, title: "Lied " + i, artists: "Jemand", albumTitle: "Platte",
                       albumId: 9, duration: 180, coverUrl80: "" })
        return out
    }

    function page(component) {
        var holder = createTemporaryObject(holderC, testCase, { width: 1280, height: 760 })
        var p = createTemporaryObject(component, holder, {})
        verify(p, "the page was not created")
        waitForRendering(p)
        return p
    }

    function test_every_long_list_keeps_a_handle_to_grab_data() {
        return [
            { tag: "album",    c: albumC,    name: "albumScrollBar" },
            { tag: "playlist", c: playlistC, name: "playlistScrollBar" },
            { tag: "mix",      c: mixC,      name: "mixScrollBar" },
            { tag: "radio",    c: radioC,    name: "radioScrollBar" }
        ]
    }

    function test_every_long_list_keeps_a_handle_to_grab(data) {
        var p = page(data.c)
        var bar = findChild(p, data.name)
        verify(bar, "no scroll bar named " + data.name)
        verify(bar.availableHeight > 0)
        fuzzyCompare(bar.minimumSize, Theme.scrollHandleMin / bar.availableHeight, 0.0001,
                     "the " + data.tag + " handle can shrink to a dot")
    }

    function test_the_sidebar_library_keeps_a_handle_to_grab() {
        var host = createTemporaryObject(sideHostC, testCase)
        host.visible = true
        waitForRendering(host.contentItem)
        var bar = findChild(host.sidebar, "sidebarLibraryScrollBar")
        verify(bar, "the sidebar library has no named scroll bar")
        verify(bar.minimumSize > 0, "the sidebar handle can shrink to a dot")
    }

    function test_a_wheel_notch_moves_by_the_system_lines() {
        bridge.setFavoriteTracksListForTest(manyTracks(400))
        var p = page(collectionC)
        p.activeTab = 0
        var list = findChild(p, "collectionTracksList")
        tryVerify(function () { return list.height > 0 && list.contentHeight > list.height * 4 })
        var notch = Qt.styleHints.wheelScrollLines * Theme.wheelLine
        var before = list.contentY
        mouseWheel(list, list.width / 2, list.height / 2, 0, -120)
        fuzzyCompare(list.contentY - before, notch, 1, "one notch did not move one notch")
        // Ten notches fast are ten notches, not a flick's guess.
        for (var i = 0; i < 10; ++i) mouseWheel(list, list.width / 2, list.height / 2, 0, -120)
        fuzzyCompare(list.contentY - before, notch * 11, 1, "fast notches did not add up")
        mouseWheel(list, list.width / 2, list.height / 2, 0, 120)
        fuzzyCompare(list.contentY - before, notch * 10, 1, "a notch up did not come back")
    }

    // A long album grid moves the same way.
    function test_a_wheel_notch_moves_a_grid_by_the_system_lines() {
        var albums = []
        for (var i = 0; i < 200; ++i) albums.push({ id: 700 + i, title: "Platte " + i, artists: "Jemand", coverUrl: "" })
        bridge.setFavoriteAlbumsForTest(albums)
        var p = page(collectionC)
        p.activeTab = 1
        var grid = findChild(p, "collectionAlbumsGrid")
        // The tab switch lays the grid out on the next polish.
        tryVerify(function () { return grid.height > 0 && grid.contentHeight > grid.height * 2 })
        var notch = Qt.styleHints.wheelScrollLines * Theme.wheelLine
        var before = grid.contentY
        mouseWheel(grid, grid.width / 2, grid.height / 2, 0, -120)
        fuzzyCompare(grid.contentY - before, notch, 1, "one notch did not move one notch")
        bridge.setFavoriteAlbumsForTest([])
    }

    function test_a_playlist_wheel_notch_moves_by_the_system_lines() {
        bridge.setPlaylistTracksForTest(manyTracks(200))
        var p = page(playlistC)
        p.playlistUuid = "11111111-2222-3333-4444-555555555555"
        var list = null
        tryVerify(function () {
            list = findChild(p, "playlistTracksList")
            return list && list.height > 0 && list.contentHeight > list.height * 3
        }, 3000, "the playlist never filled")
        var notch = Qt.styleHints.wheelScrollLines * Theme.wheelLine
        var before = list.contentY
        mouseWheel(list, list.width / 2, list.height / 2, 0, -120)
        fuzzyCompare(list.contentY - before, notch, 1, "one notch did not move one notch")
        bridge.setPlaylistTracksForTest([])
    }

    // Every list WheelStep scrolls, filled past four screens.
    function fillAndOpen(which) {
        var p = null, name = ""
        if (which === "tracks" || which === "albums" || which === "artists"
                || which === "playlists" || which === "mixes") {
            var rows = []
            for (var i = 0; i < 300; ++i)
                rows.push({ id: 700 + i, uuid: "pl-" + i, title: "Platte " + i, name: "Jemand " + i,
                            artists: "Jemand", subtitle: "", coverUrl: "", picture: "",
                            numTracks: 10, mixType: "DISCOVERY_MIX" })
            bridge.setFavoriteTracksListForTest(manyTracks(400))
            bridge.setFavoriteAlbumsForTest(rows)
            bridge.setFavoriteArtistsForTest(rows)
            bridge.setUserPlaylistsForTest(rows)
            bridge.setHomeMixesForTest(rows.map(function (r) { return { id: "mx-" + r.id, title: r.title,
                                                                         subtitle: "", coverUrl: "",
                                                                         mixType: "DISCOVERY_MIX" } }))
            p = page(collectionC)
            var tab = ["tracks", "albums", "artists", "playlists", "mixes"].indexOf(which)
            p.activeTab = tab
            name = ["collectionTracksList", "collectionAlbumsGrid", "collectionArtistsGrid",
                    "collectionPlaylistsGrid", "collectionMixesGrid"][tab]
        } else if (which === "album") {
            bridge.setAlbumForTest({ id: 4711, title: "Eine lange Platte", artists: "Eine Band",
                                     artistId: 3, numTracks: 120, coverUrl: "" }, manyTracks(120))
            p = page(albumC)
            p.albumId = 4711
            name = "albumTracksList"
        } else if (which === "playlist") {
            bridge.setPlaylistTracksForTest(manyTracks(200))
            p = page(playlistC)
            p.playlistUuid = "11111111-2222-3333-4444-555555555555"
            name = "playlistTracksList"
        } else if (which === "mix") {
            bridge.setMixPageForTest({ id: "mx-1", title: "Eine Mischung", subtitle: "",
                                       coverUrl: "", mixType: "DISCOVERY_MIX" }, manyTracks(200))
            p = page(mixC)
            p.mixId = "mx-1"
        } else {
            bridge.setTrackRadioForTest(manyTracks(200))
            p = page(radioC)
            p.trackId = 900000022
            name = "radioTracksList"
        }
        var view = null
        tryVerify(function () {
            if (name) {
                view = findChild(p, name)
            } else {
                // The mix list has no name of its own; its scroll bar does.
                var bar = findChild(p, "mixScrollBar")
                view = bar ? bar.parent : null
            }
            return view && view.visible && view.height > 0 && view.contentHeight > view.height * 4
        }, 4000, which + " never filled")
        waitForRendering(p)
        return view
    }

    function test_the_scroll_bar_fades_after_a_wheel_notch_data() {
        return [{ tag: "Liked tracks" , which: "tracks" }, { tag: "album grid", which: "albums" },
                { tag: "artist grid", which: "artists" }, { tag: "playlist grid", which: "playlists" },
                { tag: "mix grid", which: "mixes" }, { tag: "album", which: "album" },
                { tag: "playlist", which: "playlist" }, { tag: "mix", which: "mix" },
                { tag: "track radio", which: "radio" }]
    }

    // As after a drag or a flick: the bar shows while the list moves and
    // fades once it stops. A notch sets contentY, so the view never moves.
    function test_the_scroll_bar_fades_after_a_wheel_notch(data) {
        var view = fillAndOpen(data.which)
        var bar = view.ScrollBar.vertical
        verify(bar, data.tag + ": no scroll bar")
        verify(bar.size < 1, data.tag + ": the list is not long enough to scroll")
        var before = view.contentY
        mouseWheel(view, view.width / 2, view.height / 2, 0, -120)
        verify(view.contentY > before, data.tag + ": the notch did not move the list")
        tryVerify(function () { return !bar.active && bar.contentItem.opacity === 0 }, 3000,
                  data.tag + ": the scroll bar stayed on after a wheel notch")
        // A later notch shows it again, and it fades again.
        mouseWheel(view, view.width / 2, view.height / 2, 0, -120)
        verify(bar.contentItem.opacity > 0, data.tag + ": a notch did not show the scroll bar")
        tryVerify(function () { return !bar.active && bar.contentItem.opacity === 0 }, 3000,
                  data.tag + ": the scroll bar stayed on after the second notch")
        bridge.setFavoriteAlbumsForTest([])
        bridge.setFavoriteArtistsForTest([])
        bridge.setUserPlaylistsForTest([])
        bridge.setPlaylistTracksForTest([])
    }
}
