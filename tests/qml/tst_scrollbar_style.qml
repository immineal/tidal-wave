// A plain ScrollBar { } takes the app's theme, on every Qt. The stock bar
// coloured its handle from the platform palette, so it came out pale grey on
// a light theme and did not follow a theme picked in Settings.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ScrollBarStyle"
    when: windowShown

    Component {
        id: hostC
        Window {
            property alias list: list
            width: 360; height: 300
            color: Theme.bg
            ListView {
                id: list
                anchors.fill: parent
                model: 60
                clip: true
                delegate: Item { width: list.width; height: 28 }
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn }
            }
        }
    }

    property string startTheme: ""
    function initTestCase() { startTheme = prefs.theme }
    function cleanupTestCase() { prefs.theme = startTheme }

    function show() {
        var host = createTemporaryObject(hostC, testCase)
        verify(host, "host window was not created")
        host.visible = true
        host.update()
        verify(waitForRendering(host.contentItem), "the window drew no frame")
        return host
    }

    function test_the_handle_wears_the_theme_data() {
        return [ { tag: "dark", theme: "sea" }, { tag: "light", theme: "sky" } ]
    }

    function test_the_handle_wears_the_theme(row) {
        prefs.theme = row.theme
        var host = show()
        var bar = host.list.ScrollBar.vertical
        verify(bar.contentItem, "the bar has no handle")
        compare(String(bar.contentItem.color), String(Theme.textDim))
        compare(bar.contentItem.opacity, 1, "an always-on handle is see-through")
    }

    function test_the_handle_follows_a_theme_change() {
        prefs.theme = "sea"
        var host = show()
        var handle = host.list.ScrollBar.vertical.contentItem
        var before = String(handle.color)
        prefs.theme = "sky"
        verify(String(handle.color) !== before, "the handle kept the old theme's colour")
        compare(String(handle.color), String(Theme.textDim))
    }

    function test_a_pressed_handle_is_stronger() {
        prefs.theme = "sky"
        var host = show()
        var bar = host.list.ScrollBar.vertical
        var h = bar.contentItem
        var p = h.mapToItem(host.contentItem, h.width / 2, h.height / 2)
        mousePress(host.contentItem, p.x, p.y)
        tryVerify(function () { return bar.pressed }, 1000, "the handle did not take the press")
        compare(String(h.color), String(Theme.textSec))
        mouseRelease(host.contentItem, p.x, p.y)
    }
}
