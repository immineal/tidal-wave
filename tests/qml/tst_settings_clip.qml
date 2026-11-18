// Nothing in the scrolled Settings content may be drawn outside its viewport.
// Under the software backend a Shape scrolled wholly out of view drew unclipped,
// and the pixels it left were never repainted. The real window, so the panel
// sits over the scrim and the pages exactly as the app shows it.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "SettingsClip"
    when: windowShown

    Component {
        id: appWindowHost
        Main {}
    }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
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

    function findByType(item, wanted) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || typeof c.width !== "number") continue
            if (c.toString().split("(")[0].split("_QML")[0] === wanted) return c
            var found = findByType(c, wanted)
            if (found) return found
        }
        return null
    }

    // Every pixel of the window outside the viewport, on a 2px grid, so a
    // stray glyph of 12px cannot fall between two samples.
    function outside(img, vp) {
        var out = []
        for (var y = 0; y < img.height; y += 2)
            for (var x = 0; x < img.width; x += 2)
                if (x < vp.x || x >= vp.x + vp.width || y < vp.y || y >= vp.y + vp.height)
                    out.push(img.pixel(x, y))
        return out
    }

    function test_scrolling_draws_nothing_outside_the_viewport_data() {
        return [{ tag: "dark", theme: "sea" }, { tag: "light", theme: "sky" }]
    }

    function test_scrolling_draws_nothing_outside_the_viewport(row) {
        prefs.theme = row.theme
        var win = createTemporaryObject(appWindowHost, testCase)
        verify(win, "the application window was not created")
        win.width = 960
        win.height = 900
        win.visible = true
        frame(win.contentItem)

        var sidebar = findByType(win.contentItem, "SideBar")
        verify(sidebar, "the application window has no sidebar")
        var panel = sidebar.settingsPanel
        sidebar.openSettings()
        tryVerify(function () { return panel.visible && panel.opacity === 1 }, 2000,
                  "the Settings panel did not open")
        var scroll = findByName(panel.contentItem, "settingsScroll")
        verify(scroll, "the settings panel has no scroll view")
        var flick = scroll.contentItem
        frame(win.contentItem)

        var p = scroll.mapToItem(win.contentItem, 0, 0)
        var vp = { x: Math.floor(p.x), y: Math.floor(p.y),
                   width: Math.ceil(scroll.width) + 1, height: Math.ceil(scroll.height) + 1 }
        var before = outside(grabImage(win.contentItem), vp)

        // Down in steps, to the end, and back to the top: rows leave the
        // viewport at both edges on the way.
        var end = Math.max(0, flick.contentHeight - flick.height)
        verify(end > 1000, "the Settings content is too short to test scrolling")
        var stops = [0.1, 0.3, 0.55, 0.8, 1, 0.6, 0.2, 0]
        for (var s = 0; s < stops.length; ++s) {
            flick.contentY = Math.round(stops[s] * end)
            frame(win.contentItem)
            var now = outside(grabImage(win.contentItem), vp)
            compare(now.length, before.length)
            var diff = 0
            for (var i = 0; i < now.length; ++i)
                if (String(now[i]) !== String(before[i])) diff++
            compare(diff, 0, "at contentY " + flick.contentY.toFixed(0) + " of " + end.toFixed(0)
                    + ", " + diff + " samples outside the viewport changed with the scroll"
                    + " (backend " + scroll.GraphicsInfo.api + ")")
        }
        panel.close()
    }
}
