// The queue panel from the keyboard, in the real window: it has a close
// button, Tab stays inside it while it is open, and Escape or the button
// closes it and gives the keyboard back to where it was.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "QueueKeyboard"
    when: windowShown

    Component { id: appWindowHost; Main {} }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
        player.clearManual()
        player.addToQueue([{ id: 9301, title: "Eins", artists: "Erika Mustermann", duration: 100 },
                           { id: 9302, title: "Zwei", artists: "Erika Mustermann", duration: 100 }])
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function showApp() {
        var win = createTemporaryObject(appWindowHost, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        win.requestActivate()
        frame(win.contentItem)
        return win
    }

    function typeName(obj) { return obj.toString().split("(")[0].split("_QML")[0] }
    function findByType(item, wanted) {
        for (var i = 0; i < item.children.length; i++) {
            var c = item.children[i]
            if (!c || typeof c.width !== "number") continue
            if (typeName(c) === wanted) return c
            var found = findByType(c, wanted)
            if (found) return found
        }
        return null
    }
    function findNamed(item, name) {
        if (!item) return null
        if (item.objectName === name && item.visible !== false) return item
        for (var i = 0; i < item.children.length; ++i) {
            var hit = findNamed(item.children[i], name)
            if (hit) return hit
        }
        return null
    }
    function inside(item, ancestor) {
        for (var p = item; p; p = p.parent) if (p === ancestor) return true
        return false
    }

    function test_queue_panel_from_the_keyboard() {
        var win = showApp()
        var bar = findByType(win.contentItem, "PlayerBar")
        var panel = findByType(win.contentItem, "QueuePanel")
        verify(bar && panel)
        var queueBtn = findNamed(bar, "playerBarQueueButton")
        queueBtn.forceActiveFocus()
        keyClick(Qt.Key_Return)
        verify(win.queueOpen, "Enter on the queue button does not open the queue")
        tryVerify(function () { return inside(win.activeFocusItem, panel) }, 1000,
                  "opening the queue leaves the keyboard outside it")

        var close = findNamed(panel, "queueClose")
        verify(close, "the queue panel has no close button")
        compare(a11y.role(close), Accessible.Button)
        verify(a11y.name(close).length > 0)

        // Tab goes round inside the panel, never out to the page behind it.
        for (var i = 0; i < 12; ++i) {
            keyClick(Qt.Key_Tab)
            verify(inside(win.activeFocusItem, panel),
                   "Tab " + (i + 1) + " left the open queue for " + win.activeFocusItem)
        }
        for (var j = 0; j < 12; ++j) {
            keyClick(Qt.Key_Backtab)
            verify(inside(win.activeFocusItem, panel), "Shift+Tab left the open queue")
        }

        keyClick(Qt.Key_Escape)
        verify(!win.queueOpen, "Escape does not close the queue")
        tryVerify(function () { return queueBtn.activeFocus }, 1000,
                  "closing the queue does not give the keyboard back")

        keyClick(Qt.Key_Return)
        verify(win.queueOpen)
        close.forceActiveFocus()
        keyClick(Qt.Key_Return)
        verify(!win.queueOpen, "the close button does not close the queue")
        tryVerify(function () { return queueBtn.activeFocus }, 1000)
    }
}
