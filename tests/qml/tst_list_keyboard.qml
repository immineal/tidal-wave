// A list of tracks is one tab stop: the arrows walk the rows, Enter plays,
// the Menu key opens the row's menu, and the artist names are no stops.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ListKeyboard"
    when: windowShown

    function tracks() {
        var out = []
        for (var i = 0; i < 6; ++i)
            out.push({ id: 9100 + i, title: "Titel " + i, artists: "Erika Mustermann",
                       artistId: 11, artistList: [{ id: 11, name: "Erika Mustermann" }],
                       albumTitle: "Nachtfahrt", albumId: 7788, duration: 200,
                       durationStr: "3:20" })
        return out
    }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        player.setCurrentTrackForTest({ id: 1, title: "x" })
    }

    Component {
        id: listHost
        Window {
            width: 900; height: 600
            property alias list: lv
            property alias before: beforeBox
            property alias after: afterBox
            property var plays: []
            Column {
                anchors.fill: parent
                Rectangle { id: beforeBox; width: 20; height: 20; activeFocusOnTab: true }
                ListView {
                    id: lv
                    width: 900; height: 520
                    model: testCase.tracks()
                    delegate: TrackRow {
                        required property var modelData
                        required property int index
                        width: lv.width
                        title: modelData.title; artists: modelData.artists
                        trackData: modelData
                        onPlayRequested: Window.window.plays = Window.window.plays.concat([index])
                    }
                }
                Rectangle { id: afterBox; width: 20; height: 20; activeFocusOnTab: true }
            }
        }
    }

    Component {
        id: groupHost
        Window {
            width: 900; height: 600
            property alias column: col
            property var plays: []
            QtObject { id: group; property int current: 0 }
            Column {
                id: col
                anchors.fill: parent
                Repeater {
                    model: testCase.tracks()
                    TrackRow {
                        required property var modelData
                        required property int index
                        width: 900
                        rowGroup: group
                        rowIndex: index
                        title: modelData.title; artists: modelData.artists
                        trackData: modelData
                        onPlayRequested: Window.window.plays = Window.window.plays.concat([index])
                    }
                }
            }
        }
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function show(component) {
        var host = createTemporaryObject(component, testCase)
        verify(host, "host window was not created")
        host.visible = true
        host.requestActivate()
        frame(host.contentItem)
        return host
    }

    function rowsIn(item, out) {
        out = out || []
        for (var i = 0; i < item.children.length; ++i) {
            var c = item.children[i]
            if (c.hasOwnProperty("trackData") && c.hasOwnProperty("playlistUuid")) out.push(c)
            else rowsIn(c, out)
        }
        return out
    }

    function tabStopsIn(item, out) {
        out = out || []
        for (var i = 0; i < item.children.length; ++i) {
            var c = item.children[i]
            if (c.visible && c.activeFocusOnTab) out.push(c)
            tabStopsIn(c, out)
        }
        return out
    }

    function test_list_view_is_one_tab_stop() {
        var host = show(listHost)
        var rows = rowsIn(host.list.contentItem)
        verify(rows.length >= 4, "the list built " + rows.length + " rows")
        compare(tabStopsIn(host.list.contentItem).length, 1,
                "every row or name in the list is its own tab stop")

        host.before.forceActiveFocus()
        keyClick(Qt.Key_Tab)
        compare(host.list.currentIndex, 0)
        verify(host.list.currentItem.activeFocus, "Tab does not land on the list's row")
        keyClick(Qt.Key_Tab)
        verify(host.after.activeFocus, "a second Tab does not leave the list")
        keyClick(Qt.Key_Backtab)
        verify(host.list.currentItem.activeFocus, "Shift+Tab does not come back to the row")
    }

    function test_arrows_walk_the_list_view() {
        var host = show(listHost)
        host.list.currentItem.forceActiveFocus()
        keyClick(Qt.Key_Down)
        compare(host.list.currentIndex, 1)
        verify(host.list.currentItem.activeFocus, "Down does not move the keyboard")
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Up)
        compare(host.list.currentIndex, 1)
        keyClick(Qt.Key_End)
        compare(host.list.currentIndex, 5)
        keyClick(Qt.Key_Home)
        compare(host.list.currentIndex, 0)
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Return)
        compare(host.plays, [1])
    }

    function test_menu_key_opens_the_row_menu() {
        var host = show(listHost)
        var row = host.list.currentItem
        row.forceActiveFocus()
        keyClick(Qt.Key_Menu)
        tryVerify(function () { return row.rowMenu && row.rowMenu.opened }, 1000,
                  "the Menu key opens no menu")
        // Next to the row, not wherever the pointer happens to be.
        var p = row.rowMenu.parent.mapToItem(row, row.rowMenu.x, row.rowMenu.y)
        verify(p.y >= 0 && p.y <= row.height + 4, "the menu opened away from the row: " + p.y)
        row.rowMenu.close()
        keyClick(Qt.Key_F10, Qt.ShiftModifier)
        tryVerify(function () { return row.rowMenu.opened }, 1000, "Shift+F10 opens no menu")
        row.rowMenu.close()
    }

    function test_rows_in_a_column_are_one_tab_stop() {
        var host = show(groupHost)
        var rows = rowsIn(host.column)
        compare(rows.length, 6)
        compare(tabStopsIn(host.column).length, 1,
                "every row or name in the column is its own tab stop")
        rows[0].forceActiveFocus()
        keyClick(Qt.Key_Down)
        verify(rows[1].activeFocus, "Down does not move to the next row")
        compare(tabStopsIn(host.column)[0], rows[1], "the tab stop did not follow")
        keyClick(Qt.Key_End)
        verify(rows[5].activeFocus)
        keyClick(Qt.Key_Up)
        verify(rows[4].activeFocus)
        keyClick(Qt.Key_Return)
        compare(host.plays, [4])
    }
}
