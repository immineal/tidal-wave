// Home's feed tabs on the greeting's line: at any width they never cover the
// greeting, they move under it where the line is too short, and they still
// switch the feed by mouse and keyboard.

import QtQuick
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "HomeTabs"
    when: windowShown
    visible: true
    width: 1200
    height: 900

    Component { id: holderC; Item { } }
    Component { id: homeC;   HomePage { anchors.fill: parent } }

    function feed(de) {
        return { tabs: [{ name: de ? "Für dich" : "For you", feed: "static" },
                        { name: de ? "Wir empfehlen" : "Staff Picks", feed: "editorial" }],
                 modules: [{ id: "NEW_ALBUM_SUGGESTIONS", title: "Suggested new albums for you",
                             context: "", ownRow: "", mediaType: "album",
                             items: [{ kind: "album", id: 1, title: "First New",
                                       artists: "Invented Artist", coverUrl: "" }] }] }
    }
    function staff() {
        return { tabs: feed(false).tabs,
                 modules: [{ id: "STAFF_ALBUMS", title: "Albums with no skips", context: "",
                             ownRow: "", mediaType: "album",
                             items: [{ kind: "album", id: 9, title: "Staff Album",
                                       artists: "Invented Artist", coverUrl: "" }] }] }
    }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
        library.setEntriesForTest([])
        player.setPlayingForTest(false)
        player.setCurrentTrackForTest({ id: 51, title: "Signal Box", artists: "Kestrel Arcade",
                                        coverUrl: "" })
    }
    function cleanup() {
        app.setReducedMotionForTest(false)
        player.setCurrentTrackForTest({})
    }

    function settle(item) {
        wait(1)
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function findByName(item, name) {
        if (item.objectName === name) return item
        for (var i = 0; i < item.children.length; ++i) {
            var hit = findByName(item.children[i], name)
            if (hit) return hit
        }
        return null
    }
    function chipsOf(strip) {
        var out = []
        for (var i = 0; i < strip.children.length; ++i) {
            var c = strip.children[i]
            if (c.visible && c.current !== undefined) out.push(c)
        }
        return out
    }
    function rectIn(item, page) {
        var p = item.mapToItem(page, 0, 0)
        return { x: p.x, y: p.y, w: item.width, h: item.height }
    }
    function overlaps(a, b) {
        return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    }

    function makeHome(width, de) {
        bridge.setHomeFeedForTest("static", feed(de))
        bridge.setHomeFeedForTest("editorial", staff())
        var holder = createTemporaryObject(holderC, testCase, { width: width, height: 900 })
        var page = createTemporaryObject(homeC, holder, {})
        verify(page, "HomePage was not created")
        // The longest greeting in each language.
        page.greeting = de ? "Guten Morgen" : "Good afternoon"
        settle(holder)
        return page
    }

    // Checks the header at the page's current width and says where the tabs went.
    function checkHeader(page, tag) {
        var title = findByName(page, "homeTitle")
        var strip = findByName(page, "homeTabsRow")
        var header = findByName(page, "homeHeader")
        var card = findByName(page, "homeContinue")
        verify(strip.visible, tag + ": no tabs over a feed that names two")
        var t = rectIn(title, page)
        // The greeting's own glyphs, not the item, which can be wider.
        t.w = title.contentWidth
        var h = rectIn(header, page)
        var chips = chipsOf(strip)
        compare(chips.length, 2, tag)
        var below = false
        for (var i = 0; i < chips.length; ++i) {
            var c = rectIn(chips[i], page)
            verify(!overlaps(t, c), tag + ": chip " + i + " covers the greeting")
            verify(c.x >= h.x - 0.5 && c.x + c.w <= h.x + h.w + 0.5,
                   tag + ": chip " + i + " sticks out of the page's margins")
            if (c.y >= t.y + t.h) below = true
            else verify(c.x >= t.x + t.w + Theme.space4 - 0.5,
                        tag + ": chip " + i + " sits too close to the greeting")
            verify(card.mapToItem(page, 0, 0).y >= c.y + c.h + Theme.space4,
                   tag + ": the Continue card is not under chip " + i)
        }
        var label = findByName(chips[0], "homeTabLabel")
        if (below) {
            verify(Math.abs(chips[0].mapToItem(page, 0, 0).x - t.x) <= 0.5,
                   tag + ": the tabs under the greeting do not start where it does")
        } else {
            var greetBase = title.mapToItem(page, 0, title.baselineOffset).y
            var tabBase = label.mapToItem(page, 0, label.baselineOffset).y
            verify(Math.abs(greetBase - tabBase) <= 1,
                   tag + ": the tabs are off the greeting's baseline by " + (tabBase - greetBase))
        }
        return below ? "below" : "inline"
    }

    function test_the_tabs_never_cover_the_greeting_data() {
        var rows = []
        var widths = [1180, 900, 640, 572, 480, 420, 360]
        for (var i = 0; i < widths.length; ++i) {
            rows.push({ tag: "en " + widths[i], width: widths[i], de: false })
            rows.push({ tag: "de " + widths[i], width: widths[i], de: true })
        }
        return rows
    }
    function test_the_tabs_never_cover_the_greeting(data) {
        var page = makeHome(data.width, data.de)
        var where = checkHeader(page, data.tag)
        if (data.width >= 900) compare(where, "inline", "the tabs left a wide greeting line")
        if (data.width <= 360) compare(where, "below", "the tabs stayed on a line too short for them")
    }

    // Narrow and back: the tabs come back onto the line, on one row.
    function test_the_tabs_follow_the_width_both_ways() {
        var page = makeHome(1180, true)
        var holder = page.parent
        compare(checkHeader(page, "wide"), "inline")
        holder.width = 360
        settle(holder)
        compare(checkHeader(page, "narrow"), "below")
        holder.width = 1180
        settle(holder)
        compare(checkHeader(page, "wide again"), "inline")
        var strip = findByName(page, "homeTabsRow")
        var chips = chipsOf(strip)
        compare(chips[0].y, chips[1].y, "the chips wrapped on the line")
        // The width the page plans with is the width the chips take.
        var used = chips[1].x + chips[1].width
        verify(strip.lineWidth >= used - 0.5 && strip.lineWidth - used <= chips.length,
               "lineWidth " + strip.lineWidth + " is not the chips' " + used)
    }

    function test_a_click_switches_the_feed_data() {
        return [{ tag: "on the line", width: 1180 }, { tag: "under the greeting", width: 360 }]
    }
    function test_a_click_switches_the_feed(data) {
        var page = makeHome(data.width, false)
        var strip = findByName(page, "homeTabsRow")
        var chips = chipsOf(strip)
        mouseClick(chips[1])
        settle(page)
        compare(page.feedTab, "editorial", "a click on the second tab did not switch the feed")
        compare(strip.currentIndex, 1)
        verify(findByName(page, "homeFeedRow_STAFF_ALBUMS"), "the staff picks rows did not come")
        mouseClick(chips[0])
        settle(page)
        compare(page.feedTab, "static")
        compare(strip.currentIndex, 0)
    }

    // Greeting, then the tabs in order, then the Continue card; each tab
    // named by its label and selectable from the keyboard.
    function test_the_keyboard_reaches_the_tabs_in_order() {
        var page = makeHome(1180, false)
        var chips = chipsOf(findByName(page, "homeTabsRow"))
        var card = findByName(page, "homeContinue")
        compare(a11y.name(chips[0]), "For you")
        compare(a11y.name(chips[1]), "Staff picks")
        compare(a11y.role(chips[0]), Accessible.PageTab)
        verify(chips[0].Accessible.selected && !chips[1].Accessible.selected)

        chips[0].forceActiveFocus(Qt.TabFocusReason)
        verify(chips[0].activeFocus)
        keyClick(Qt.Key_Tab)
        verify(chips[1].activeFocus, "Tab did not go from the first tab to the second")
        keyClick(Qt.Key_Space)
        settle(page)
        compare(page.feedTab, "editorial", "Space did not choose the focused tab")
        verify(chips[1].Accessible.selected)
        keyClick(Qt.Key_Tab)
        verify(card.activeFocus, "Tab did not go from the tabs to the Continue card")
        keyClick(Qt.Key_Backtab)
        verify(chips[1].activeFocus, "Shift+Tab did not come back to the tabs")
    }
}
