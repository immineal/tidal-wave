// How a menu sits and behaves: padded, with rounded entries that stay inside
// its corners, grouped by separators with the destructive rows last, the row
// it belongs to still marked while it is open, and a right-click on another
// row moving it there.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "Menus"
    when: windowShown
    width: 1000
    height: 800
    visible: true

    Component { id: holderC; Item { } }
    Component { id: trackRowC; TrackRow { width: 700 } }
    Component { id: mediaCardC; MediaCard { cardSize: 160 } }

    function init() { app.setReducedMotionForTest(true) }
    function cleanup() { app.setReducedMotionForTest(false) }

    function settle(item) {
        wait(1)
        item.Window.window.update()
        waitForRendering(item, 2000)
        wait(1)
    }

    function makeTrack(id) {
        return { id: id, title: "Track " + id, artists: "Eine Band", albumId: 42,
                 artistId: 7, artistList: [{ id: 7, name: "Eine Band" }],
                 durationStr: "4:07", coverUrl: "" }
    }

    function makeRow(holder, y, id) {
        var row = createTemporaryObject(trackRowC, holder, {
            y: y, trackNum: 1, title: "Track " + id, artists: "Eine Band",
            durationStr: "4:07", trackData: makeTrack(id),
            playlistUuid: "uuid-1", trackItemIndex: 0
        })
        verify(row, "the row was not created")
        return row
    }

    function visibleItems(menu) {
        var out = []
        for (var i = 0; i < menu.count; i++) {
            var it = menu.itemAt(i)
            if (it && it.visible && it.height > 0) out.push(it)
        }
        return out
    }
    function isSeparator(it) { return it instanceof MenuSeparator }

    function checkPaddingAndEntries(menu, what) {
        verify(menu.topPadding >= Theme.space1 && menu.topPadding <= 6,
               what + ": the top padding is " + menu.topPadding)
        verify(menu.bottomPadding >= Theme.space1 && menu.bottomPadding <= 6,
               what + ": the bottom padding is " + menu.bottomPadding)
        verify(menu.leftPadding >= Theme.space1 && menu.leftPadding <= 6,
               what + ": the left padding is " + menu.leftPadding)
        var items = visibleItems(menu)
        var entries = 0
        for (var i = 0; i < items.length; i++) {
            if (isSeparator(items[i])) continue
            entries++
            var bg = items[i].background
            verify(bg && bg.radius > 0, what + ": entry " + i + " has a square highlight")
            var p = items[i].mapToItem(menu.contentItem, 0, 0)
            var right = p.x + items[i].width
            verify(p.x >= 0 && right <= menu.contentItem.width + 0.5,
                   what + ": entry " + i + " reaches past the padding")
        }
        verify(entries > 2, what + ": too few entries to say anything")
    }

    function test_the_track_menu_is_padded_and_its_entries_are_rounded() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 760 })
        var row = makeRow(holder, 0, 1)
        settle(holder)
        row.openMenu()
        var menu = row.rowMenu
        tryVerify(function () { return menu.opened }, 2000)
        checkPaddingAndEntries(menu, "track menu")
        menu.close()
    }

    function test_the_pin_menu_is_padded_and_its_entries_are_rounded() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var card = createTemporaryObject(mediaCardC, holder, {
            mediaType: "album", itemId: "42", title: "Glass Orchard", subtitle: "Kestrel Arcade"
        })
        settle(holder)
        card.ensureMenu().showPin(10, 10, "album", "42", "Glass Orchard", "Kestrel Arcade", "")
        tryVerify(function () { return card.pinMenu.opened }, 2000)
        checkPaddingAndEntries(card.pinMenu, "pin menu")
        card.pinMenu.close()
    }

    // Groups under rules, and the one row that costs something last, in a
    // group of its own.
    function test_the_track_menu_ends_with_the_removal_in_its_own_group() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 760 })
        var row = makeRow(holder, 0, 1)
        settle(holder)
        row.openMenu()
        var menu = row.rowMenu
        tryVerify(function () { return menu.opened }, 2000)
        var items = visibleItems(menu)
        var last = items[items.length - 1]
        compare(last.objectName, "removeFromPlaylistMenuItem",
                "the last row is not Remove from playlist")
        verify(isSeparator(items[items.length - 2]), "the removal shares a group with other rows")
        var seps = items.filter(isSeparator).length
        verify(seps >= 3, "the menu has " + seps + " separators")
        for (var i = 1; i < items.length; i++)
            verify(!(isSeparator(items[i]) && isSeparator(items[i - 1])), "two rules meet at " + i)
        verify(!isSeparator(items[0]), "the menu opens on a rule")
        menu.close()
    }

    // Without a playlist the menu still ends on a row, not on a rule.
    function test_without_a_removal_the_menu_ends_on_an_entry() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 760 })
        var row = makeRow(holder, 0, 1)
        row.playlistUuid = ""
        settle(holder)
        row.openMenu()
        var menu = row.rowMenu
        tryVerify(function () { return menu.opened }, 2000)
        var items = visibleItems(menu)
        verify(!isSeparator(items[items.length - 1]), "the menu ends on a rule")
        menu.close()
    }

    function rowFill(row) {
        for (var i = 0; i < row.children.length; i++)
            if (row.children[i].radius !== undefined) return row.children[i]
        return null
    }

    // The row the menu is about stays marked after the pointer leaves it for
    // the menu.
    function test_the_row_stays_marked_while_its_menu_is_open() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 760 })
        var row = makeRow(holder, 0, 1)
        settle(holder)
        mouseMove(row, 200, row.height / 2)
        mouseClick(row, 200, row.height / 2, Qt.RightButton)
        var menu = row.rowMenu
        verify(menu, "a right-click built no menu")
        tryVerify(function () { return menu.opened }, 2000, "a right-click opened no menu")
        var entry = visibleItems(menu)[1]
        var p = entry.mapToItem(holder, entry.width / 2, entry.height / 2)
        mouseMove(holder, p.x, p.y)
        settle(holder)
        var fill = rowFill(row)
        verify(fill, "the row's fill was not found")
        verify(fill.color.a > 0, "the row lost its mark when the pointer went to its menu")
        menu.close()
        settle(holder)
        mouseMove(holder, 880, 740)
        settle(holder)
        compare(fill.color.a, 0, "the row stays marked after its menu closed")
    }

    // A right-click on a second row moves the menu there in one click.
    function test_a_right_click_on_another_row_moves_the_menu() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 760 })
        var a = makeRow(holder, 0, 1)
        var b = makeRow(holder, 640, 2)
        settle(holder)
        mouseClick(a, 200, a.height / 2, Qt.RightButton)
        tryVerify(function () { return a.rowMenu && a.rowMenu.opened }, 2000)
        mouseClick(b, 200, b.height / 2, Qt.RightButton)
        tryVerify(function () { return b.rowMenu && b.rowMenu.opened }, 2000,
                  "the right-click on the second row only closed the first menu")
        tryVerify(function () { return !a.rowMenu.visible }, 2000, "the first menu stayed open")
        b.rowMenu.close()
    }
}
