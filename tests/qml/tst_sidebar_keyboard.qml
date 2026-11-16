// The sidebar from the keyboard: the library list and the finder's kind
// chips are one tab stop each and the arrows walk them; a chip that is on
// and a chip the keyboard is on look different.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "SidebarKeyboard"
    when: windowShown

    Component {
        id: hostC
        Window {
            width: 1100; height: 760
            property alias sidebar: sb
            RowLayout {
                anchors.fill: parent
                spacing: 0
                SideBar {
                    id: sb
                    hostWidth: 1100
                    Layout.preferredWidth: sb.reservedWidth
                    Layout.fillHeight: true
                }
                Item { Layout.fillWidth: true; Layout.fillHeight: true }
            }
        }
    }

    function init() {
        prefs.setSidebarWidthForTest(220)
        app.setReducedMotionForTest(true)
        auth.setUsernameForTest("robin")
        var e = []
        for (var i = 0; i < 8; ++i)
            e.push({ kind: "album", id: "a" + i, title: "Album " + i, subtitle: "Erika Mustermann",
                     imageUrl: "", pinned: false, trackCount: 9 })
        library.setEntriesForTest(e)
        library.setTracksForTest([])
        pins.setItemsForTest([])
    }
    function cleanup() { app.setReducedMotionForTest(false) }

    function show() {
        var host = createTemporaryObject(hostC, testCase)
        host.visible = true
        tryVerify(function () { return host.sidebar.panelWidth === host.sidebar.targetWidth }, 2000)
        wait(1)
        return host
    }

    function collect(item, name, out) {
        if (item.visible === false) return out
        if (item.objectName === name) out.push(item)
        for (var i = 0; i < item.children.length; ++i) collect(item.children[i], name, out)
        return out
    }
    function stops(items) { return items.filter(function (it) { return it.activeFocusOnTab }) }

    function test_library_is_one_tab_stop() {
        var host = show()
        var rows = []
        tryVerify(function () { rows = collect(host.sidebar, "libraryRow", []); return rows.length >= 8 }, 1000)
        compare(stops(rows).length, 1, "every library row is its own tab stop")
        var first = stops(rows)[0]
        first.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Down)
        verify(!first.activeFocus, "Down does not leave the first row")
        rows = collect(host.sidebar, "libraryRow", [])
        compare(stops(rows).length, 1, "walking the list left a second tab stop behind")
        verify(stops(rows)[0].activeFocus)
        keyClick(Qt.Key_Menu)
        var menu = null
        var all = host.sidebar.data
        for (var i = 0; i < all.length; ++i) if (all[i].objectName === "sidebarPinMenu") menu = all[i]
        verify(menu)
        tryVerify(function () { return menu.opened }, 1000, "the Menu key opens no row menu")
        menu.close()
    }

    function test_chips_are_a_toolbar() {
        var host = show()
        var chips = collect(host.sidebar, "finderChip", [])
        compare(chips.length, 5)
        compare(stops(chips).length, 1, "every kind chip is its own tab stop")
        chips[0].forceActiveFocus(Qt.TabFocusReason)
        // The tooltip waits out its delay before it shows.
        tryVerify(function () { return chips[0].ToolTip.visible }, 2000,
                  "a focused chip does not say what it is")
        keyClick(Qt.Key_Right)
        verify(chips[1].activeFocus, "Right does not move along the chips")
        compare(stops(chips).length, 1)
        keyClick(Qt.Key_End)
        verify(chips[4].activeFocus)
        keyClick(Qt.Key_Return)
        verify(chips[4].selected)
        keyClick(Qt.Key_Home)
        verify(chips[0].activeFocus)

        // On is a fill, focus a ring: chip 4 is on and not focused, chip 0
        // the other way round.
        var onFill = collect(chips[4], "finderChipFill", [])[0]
        var onRing = collect(chips[4], "finderChipRing", [])[0]
        var focFill = collect(chips[0], "finderChipFill", [])[0]
        var focRing = collect(chips[0], "finderChipRing", [])[0]
        verify(onFill && onRing && focFill && focRing, "the chip has no separate fill and ring")
        compare(onRing.border.width, 0)
        verify(focRing.border.width >= 2)
        verify(onFill.color.a > 0.9, "an on chip is not filled")
        compare(focFill.color.a, 0, "a focused chip that is off is filled like an on one")
    }
}
