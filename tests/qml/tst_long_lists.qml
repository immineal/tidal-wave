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
}
