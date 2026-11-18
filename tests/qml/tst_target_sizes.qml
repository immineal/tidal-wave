// Small controls take a press over at least 32 by 32 pixels, whatever size
// the glyph is drawn at.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "TargetSizes"
    when: windowShown

    readonly property int minTarget: 32

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        bridge.resetForTest()
    }

    Component { id: hostC; Window { width: 1100; height: 800 } }
    Component { id: searchBarC;  SearchBar { width: 400 } }
    Component { id: finderC;     LibraryFinder { width: 166 } }
    Component { id: queueC;      QueuePanel { anchors.fill: parent } }
    Component { id: settingsC;   SettingsPanel { } }
    Component { id: newPlC;      NewPlaylistDialog { } }
    Component { id: rowC;        TrackRow { width: 800 } }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function show() {
        var host = createTemporaryObject(hostC, testCase)
        host.visible = true
        frame(host.contentItem)
        return host
    }

    function place(host, c, props) {
        var item = createTemporaryObject(c, host.contentItem, props || {})
        verify(item)
        frame(host.contentItem)
        return item
    }

    function allNamed(item, name, out) {
        out = out || []
        if (!item) return out
        if (item.objectName === name && item.visible !== false) out.push(item)
        for (var i = 0; i < item.children.length; ++i) allNamed(item.children[i], name, out)
        return out
    }
    function named(item, name) { return allNamed(item, name)[0] || null }

    function checkSize(item, what) {
        verify(item, what + " not found")
        verify(item.width >= minTarget && item.height >= minTarget,
               what + " takes presses over only " + item.width + "x" + item.height)
    }

    function test_search_clear() {
        var host = show()
        var bar = place(host, searchBarC)
        bar.text = "abc"
        frame(bar)
        checkSize(named(bar, "searchClear"), "the search field's clear button")
    }

    function test_finder() {
        var host = show()
        var finder = place(host, finderC)
        finder.query = "abc"
        frame(finder)
        checkSize(named(finder, "finderClear"), "the finder's clear button")
        var chips = allNamed(finder, "finderChip")
        compare(chips.length, 5)
        for (var i = 0; i < chips.length; ++i) checkSize(chips[i], "finder chip " + i)
        // Still all five in the narrowest sidebar's finder.
        var last = chips[4].mapToItem(finder, chips[4].width, 0)
        verify(last.x <= finder.width, "the last chip hangs out of the finder")
    }

    function test_queue_clear() {
        var host = show()
        player.clearManual()
        player.addToQueue([{ id: 9401, title: "Eins", artists: "Erika Mustermann", duration: 100 }])
        var panel = place(host, queueC)
        checkSize(named(panel, "queueClear"), "the queue's Clear")
        checkSize(named(panel, "queueClose"), "the queue's close button")
    }

    function test_dialog_close_buttons() {
        var host = show()
        var settings = createTemporaryObject(settingsC, host.contentItem)
        settings.open()
        tryVerify(function () { return settings.opened }, 1000)
        checkSize(named(settings.contentItem.parent, "settingsClose"), "Settings' close button")
        settings.close()

        var dlg = createTemporaryObject(newPlC, host.contentItem)
        dlg.open()
        tryVerify(function () { return dlg.opened }, 1000)
        checkSize(named(dlg.contentItem.parent, "newPlaylistClose"), "the new playlist dialog's close button")
        dlg.close()

        var row = place(host, rowC, { title: "Titel", artists: "Erika Mustermann",
                                      trackData: { id: 9402, title: "Titel" } })
        row.openPicker()
        tryVerify(function () { return row.playlistPicker.opened }, 1000)
        checkSize(named(row.playlistPicker.contentItem, "pickerCloseButton"), "the picker's close button")
        row.playlistPicker.close()
    }

    // Settings' close is reachable from the keyboard as well.
    function test_settings_close_is_a_button() {
        var host = show()
        var settings = createTemporaryObject(settingsC, host.contentItem)
        settings.open()
        tryVerify(function () { return settings.opened }, 1000)
        var close = named(settings.contentItem.parent, "settingsClose")
        verify(close.activeFocusOnTab, "Settings' close button is not a tab stop")
        compare(a11y.role(close), Accessible.Button)
        verify(a11y.press(close))
        tryVerify(function () { return !settings.opened }, 1000)
    }
}
