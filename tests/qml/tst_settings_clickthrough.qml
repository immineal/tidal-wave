// A click on the Settings panel must never reach the page under it. The
// collection grid is the page with the most to hit, so the panel is opened
// over a full Albums tab in the real window, at the sizes of large screens.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "SettingsClickThrough"
    when: windowShown

    Component {
        id: appWindowHost
        Main {}
    }

    // Laid over the page, under the overlay, exactly where a control of the
    // panel is, so a leak is caught whatever the grid puts there.
    Component {
        id: probeC
        Item {
            property int taps: 0
            TapHandler { onTapped: parent.taps++ }
        }
    }

    function probeUnder(win, item) {
        var r = item.mapToItem(win.contentItem, 0, 0)
        var probe = createTemporaryObject(probeC, win.contentItem,
            { x: r.x, y: r.y, width: item.width, height: item.height, z: 1000 })
        verify(probe, "no probe")
        return probe
    }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
        var albums = []
        for (var i = 0; i < 300; ++i)
            albums.push({ id: 9000 + i, title: "Album " + (i + 1),
                          artists: "Interpret", coverUrl: "", type: "ALBUM",
                          numTracks: 10, year: "2020" })
        bridge.setFavoriteAlbumsForTest(albums)
    }

    function cleanup() {
        bridge.setFavoriteAlbumsForTest([])
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function typeName(obj) {
        return obj.toString().split("(")[0].split("_QML")[0]
    }

    function findByType(item, wanted) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || typeof c.width !== "number") continue
            if (typeName(c) === wanted) return c
            var found = findByType(c, wanted)
            if (found) return found
        }
        return null
    }

    function findByName(item, name) {
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var found = kids[i] ? findByName(kids[i], name) : null
            if (found) return found
        }
        return null
    }

    function openOverAlbums(w, h) {
        var win = createTemporaryObject(appWindowHost, testCase)
        verify(win, "the application window was not created")
        win.width = w
        win.height = h
        win.visible = true
        win.requestActivate()
        frame(win.contentItem)
        win.navigate("collection")
        tryVerify(function () { return win.currentPage === "collection" }, 2000)
        var page = findByType(win.contentItem, "CollectionPage")
        verify(page, "no collection page")
        page.activeTab = 1
        frame(win.contentItem)
        var sidebar = findByType(win.contentItem, "SideBar")
        sidebar.openSettings()
        var panel = sidebar.settingsPanel
        tryVerify(function () { return panel.visible && panel.opened }, 2000,
                  "the Settings panel did not open")
        frame(win.contentItem)
        return { win: win, panel: panel }
    }

    // Brings an item inside the panel's ScrollView into view and clicks it.
    function clickInPanel(s, item) {
        var scroller = findByName(s.panel.contentItem, "settingsScroll")
        var flick = scroller.contentItem
        var y = item.mapToItem(flick.contentItem, 0, 0).y
        flick.contentY = Math.max(0, Math.min(y - 40,
                                  flick.contentHeight - flick.height))
        frame(s.win.contentItem)
        mouseClick(item)
        frame(s.win.contentItem)
    }

    function test_check_now_stays_on_the_panel_data() {
        return [
            { tag: "1280x800",  w: 1280, h: 800 },
            { tag: "1920x1080", w: 1920, h: 1080 },
            { tag: "2560x1440", w: 2560, h: 1440 },
            { tag: "3840x2160", w: 3840, h: 2160 },
        ]
    }

    function test_check_now_stays_on_the_panel(data) {
        var s = openOverAlbums(data.w, data.h)
        var btn = findByName(s.panel.contentItem, "settingsCheckNowButton")
        verify(btn, "no Check now button")
        clickInPanel(s, btn)
        compare(s.win.currentPage, "collection",
                "a click on Check now opened what was under it")
        verify(s.panel.visible, "a click on Check now closed the panel")
    }

    // The panel scrolled to each kind of control, a probe under it. A scrolled
    // Flickable is what lets a passive TapHandler's press through.
    function test_controls_keep_their_clicks_data() {
        return [
            { tag: "button", name: "settingsCheckNowButton", twice: false },
            { tag: "switch", name: "settingsUpdateToggle",   twice: true },
        ]
    }

    function test_controls_keep_their_clicks(data) {
        var s = openOverAlbums(1920, 1080)
        var item = findByName(s.panel.contentItem, data.name)
        verify(item, "no " + data.name)
        var scroller = findByName(s.panel.contentItem, "settingsScroll")
        var flick = scroller.contentItem
        var y = item.mapToItem(flick.contentItem, 0, 0).y
        flick.contentY = Math.max(0, Math.min(y - 40, flick.contentHeight - flick.height))
        verify(flick.contentY > 0, "the panel did not scroll, so this proves nothing")
        frame(s.win.contentItem)
        var probe = probeUnder(s.win, item)
        mouseClick(item)
        if (data.twice) mouseClick(item)
        compare(probe.taps, 0, "a click on " + data.name + " reached the page beneath")
        compare(s.win.currentPage, "collection")
    }

    // The current theme's tile, so the click changes nothing.
    function findTile(item) {
        if (item.themeName !== undefined && item.themeName === prefs.theme && item.visible)
            return item
        for (var i = 0; i < item.children.length; i++) {
            var found = findTile(item.children[i])
            if (found) return found
        }
        return null
    }

    function test_theme_tile_keeps_its_click() {
        var s = openOverAlbums(1920, 1080)
        var flick = findByName(s.panel.contentItem, "settingsScroll").contentItem
        flick.contentY = 60
        frame(s.win.contentItem)
        var tile = findTile(flick.contentItem)
        verify(tile, "no tile for the current theme")
        var probe = probeUnder(s.win, tile)
        mouseClick(tile)
        compare(probe.taps, 0, "a click on a theme tile reached the page beneath")
    }

    // Every point of the panel, not only one button: a gap between rows
    // must not fall through either.
    function test_no_point_of_the_panel_falls_through_data() {
        return test_check_now_stays_on_the_panel_data()
    }

    function test_no_point_of_the_panel_falls_through(data) {
        var s = openOverAlbums(data.w, data.h)
        // Points in the side margins, where no control sits, so nothing in
        // the panel acts on the click.
        var p = s.panel.contentItem
        var pts = []
        for (var fy = 0.15; fy < 0.99; fy += 0.07) {
            pts.push([6, p.height * fy])
            pts.push([p.width - 14, p.height * fy])
        }
        for (var i = 0; i < pts.length; i++) {
            mouseClick(p, pts[i][0], pts[i][1])
            frame(s.win.contentItem)
            compare(s.win.currentPage, "collection",
                    "a click at " + pts[i] + " on the panel opened what was under it")
        }
    }
}
