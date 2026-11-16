// One version of each control. The tab strips on Search and My Collection,
// the three search fields, and the switches in Settings and the sleep timer
// were each built twice or more, and drifted apart in size and behaviour.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "SharedControls"
    when: windowShown

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        bridge.resetForTest()
    }

    Component { id: appHost; Main { } }
    Component {
        id: npHost
        Window {
            width: 1280; height: 900
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) {}
            function cancelSleepTimer() {}
            function formatSleepTime(seconds) { return "0:30" }
            property bool fullScreen: false
            function toggleFullScreen() {}
            function navigate(page, params) {}
            function goBack() {}
            property alias page: np
            NowPlayingPage { id: np; anchors.fill: parent }
        }
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function showApp() {
        var win = createTemporaryObject(appHost, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        frame(win.contentItem)
        return win
    }

    function typeName(obj) {
        return obj.toString().split("(")[0].split("_QML")[0]
    }

    // Hidden ones too: the search tabs only show once there is a query.
    function findByType(item, wanted) {
        if (!item) return null
        if (typeName(item) === wanted) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByType(kids[i], wanted)
            if (hit) return hit
        }
        return null
    }

    function findNamed(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findNamed(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function pageOn(win, page, type) {
        win.navigate(page, {})
        var p = null
        tryVerify(function () { p = findByType(win.contentItem, type); return p !== null },
                  3000, page + " did not load")
        frame(win.contentItem)
        return p
    }

    function test_both_tab_rows_are_the_shared_strip() {
        var win = showApp()
        var search = pageOn(win, "search", "SearchPage")
        var a = findByType(search, "TabStrip")
        verify(a, "the Search page builds its own tab row")
        var collection = pageOn(win, "collection", "CollectionPage")
        var b = findByType(collection, "TabStrip")
        verify(b, "My Collection builds its own tab row")
        compare(a.chipHeight, b.chipHeight, "the two strips' chips differ in height")
    }

    Component {
        id: stripHost
        Window {
            width: 600; height: 80
            property alias strip: ts
            TabStrip { id: ts; x: 10; y: 10; width: 580; animate: false
                       model: ["Tracks (12)", "Albums (8)", "Artists (3)", "Mixes (4)"] }
        }
    }

    // The chosen tab is bold, like the chosen sort word, and each chip is
    // sized off its bold label, so choosing one moves nothing.
    function test_the_chosen_tab_is_bold_and_moves_nothing() {
        var win = createTemporaryObject(stripHost, testCase)
        win.visible = true
        frame(win.contentItem)
        var ts = win.strip
        var labels = [], chips = []
        ;(function walk(it) {
            if (it.objectName === "tabTabLabel") labels.push(it)
            for (var k = 0; k < it.children.length; ++k) walk(it.children[k])
        })(ts)
        compare(labels.length, 4)
        for (var i = 0; i < 4; ++i) chips.push(labels[i].parent)
        var xs = chips.map(function (c) { return c.mapToItem(ts, 0, 0).x })
        ts.currentIndex = 1
        frame(win.contentItem)
        verify(labels[1].font.bold, "the chosen tab is not bold")
        verify(!labels[0].font.bold && !labels[2].font.bold, "a tab not chosen is bold")
        for (i = 0; i < 4; ++i)
            verify(Math.abs(chips[i].mapToItem(ts, 0, 0).x - xs[i]) <= 0.5,
                   "tab " + i + " moved when another was chosen")
    }

    function test_the_search_fields_are_one_height() {
        var win = showApp()
        var finder = findByType(win.contentItem, "LibraryFinder")
        verify(finder, "the sidebar has no finder")
        var search = pageOn(win, "search", "SearchPage")
        var a = findNamed(search, "searchPageBar")
        var collection = pageOn(win, "collection", "CollectionPage")
        var b = findNamed(collection, "collectionSearch")
        verify(a && b, "a page lost its search field")
        compare(a.height, b.height, "Search's field and My Collection's differ in height")
        compare(finder.fieldHeight, a.height, "the sidebar's finder is another height")
    }

    function test_the_sleep_fade_switch_is_the_shared_toggle() {
        var host = createTemporaryObject(npHost, testCase)
        verify(host, "Now Playing was not created")
        host.visible = true
        frame(host.contentItem)
        var np = host.page
        var popup = null
        for (var i = 0; i < np.data.length; ++i)
            if (np.data[i] && np.data[i].objectName === "nowPlayingSleepTimerPopup") popup = np.data[i]
        if (!popup) {
            // Deeper in: walk every item's data for the popup.
            var stack = [np]
            while (stack.length && !popup) {
                var it = stack.pop()
                for (var k = 0; it.data && k < it.data.length; ++k) {
                    var d = it.data[k]
                    if (!d) continue
                    if (d.objectName === "nowPlayingSleepTimerPopup") { popup = d; break }
                    stack.push(d)
                }
            }
        }
        verify(popup, "Now Playing has no sleep timer popup")
        var sw = findNamed(popup.contentItem, "nowPlayingSleepFadeToggle")
        verify(sw, "the fade switch is not the shared Toggle")
        compare(typeName(sw), "Toggle")
    }
}
