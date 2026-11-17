// The icon-only controls say what they do when pointed at: shuffle, previous,
// next, repeat and queue in the player bar, a card's play button and a track
// row's menu and download buttons. Each tip is the control's screen reader name, after the one
// delay in Theme.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ToolTips"
    when: windowShown

    function track() {
        return {
            id: 4242, title: "Weit hinter dem Horizont",
            artists: "Erika Mustermann", artistId: 11,
            artistList: [{ id: 11, name: "Erika Mustermann" }],
            albumTitle: "Nachtfahrt", albumId: 7788,
            coverUrl: "", coverUrl80: "", duration: 215, durationStr: "3:35"
        }
    }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        player.setCurrentTrackForTest(track())
    }

    Component {
        id: plainHost
        Window {
            width: 1100; height: 700
            function goBack() {}
            function navigate(page, params) {}
        }
    }

    Component { id: barC;  PlayerBar { } }
    Component { id: cardC; MediaCard { title: "Nachtfahrt"; subtitle: "Erika Mustermann"; itemId: "7788" } }
    Component { id: rowC;  TrackRow { width: 800 } }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function show() {
        var host = createTemporaryObject(plainHost, testCase)
        verify(host, "host window was not created")
        host.visible = true
        frame(host.contentItem)
        return host
    }

    function place(host, component, props) {
        var item = createTemporaryObject(component, host.contentItem, props || {})
        verify(item, "the control was not created")
        frame(host.contentItem)
        return item
    }

    function findNamed(item, name) {
        if (!item) return null
        if (item.objectName === name && item.visible !== false) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findNamed(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function hover(host, item) {
        var p = item.mapToItem(host.contentItem, item.width / 2, item.height / 2)
        mouseMove(host.contentItem, p.x, p.y)
    }

    // Pointed at, the shared tip comes up with this text, on the one delay,
    // dressed in the app's own look.
    function tipShows(host, item, want, what) {
        verify(item, what + " not found")
        hover(host, item)
        compare(item.ToolTip.delay, Theme.tooltipDelay, what + " has its own tool tip delay")
        tryVerify(function () {
            var tip = item.ToolTip.toolTip
            return tip && tip.visible && tip.text === want
        }, 3000, what + " shows no tool tip saying \"" + want + "\"")
        looksThemed(item.ToolTip.toolTip, what)
        mouseMove(host.contentItem, 1, 1)
    }

    // The look of SideBar's sidebarTip, which every tip in the app shares.
    function looksThemed(tip, what) {
        verify(tip, what + ": no tip")
        var bg = tip.background, label = tip.contentItem
        verify(bg && label, what + ": the tip has no background or no label")
        compare(String(bg.color), String(Theme.surfaceHigh), what + ": the tip's ground is the style's")
        compare(String(bg.border.color), String(Theme.border), what + ": the tip's border")
        compare(bg.radius, Theme.radiusMedium, what + ": the tip's corners")
        compare(String(label.color), String(Theme.textPrimary), what + ": the tip's text colour")
        compare(label.font.pixelSize, Theme.fontMeta, what + ": the tip's text size")
        compare(tip.leftPadding, Theme.space2, what + ": the tip's padding")
        compare(tip.topPadding, Theme.space2, what + ": the tip's padding")
    }

    Component {
        id: ownTipC
        Item {
            width: 80; height: 30
            property alias tip: own
            ToolTip { id: own; text: "Eigener Hinweis" }
        }
    }

    // A tip declared on its own, as SideBar's is, is the style's as well.
    function test_a_tip_of_its_own_is_themed() {
        var host = show()
        var item = place(host, ownTipC)
        item.tip.open()
        tryVerify(function () { return item.tip.opened }, 2000, "the tip did not open")
        looksThemed(item.tip, "a ToolTip { }")
        item.tip.close()
    }

    // The colours are bindings: a theme picked while the app runs reaches
    // the one shared tip, which outlives every control that showed it.
    function test_the_shared_tip_follows_the_theme() {
        var host = show()
        var card = place(host, cardC)
        var tip = card.ToolTip.toolTip
        var before = prefs.theme
        var start = String(tip.background.color)
        prefs.theme = ThemePalette.isDark ? "sky" : "pine"
        verify(String(tip.background.color) !== start, "the tip kept the old theme's ground")
        compare(String(tip.background.color), String(Theme.surfaceHigh))
        prefs.theme = before
    }

    function test_player_bar_icon_buttons_data() {
        return [
            { tag: "shuffle",  name: "playerBarShuffle",     want: "Shuffle" },
            { tag: "previous", name: "playerBarPrevious",    want: "Previous track" },
            { tag: "next",     name: "playerBarNext",        want: "Next track" },
            { tag: "repeat",   name: "playerBarRepeat",      want: "" },
            { tag: "queue",    name: "playerBarQueueButton", want: "Queue" },
        ]
    }

    function test_player_bar_icon_buttons(row) {
        var host = show()
        var bar = place(host, barC, { width: 1100 })
        var btn = findNamed(bar, row.name)
        // Repeat names its mode, so the tip is whatever the name is now.
        var want = row.want.length > 0 ? row.want : btn.Accessible.name
        verify(want.length > 0, row.name + " has no name to show")
        tipShows(host, btn, want, row.name)
    }

    function test_card_play_button() {
        var host = show()
        var card = place(host, cardC)
        hover(host, card)
        var play = null
        tryVerify(function () {
            play = findNamed(card, "cardPlayButton")
            return play !== null && play.visible
        }, 2000, "the card's play button did not come up on hover")
        tipShows(host, play, "Play", "the card's play button")
    }

    function test_track_row_menu_button() {
        var host = show()
        var t = track()
        var row = place(host, rowC, { title: t.title, artists: t.artists, trackData: t })
        hover(host, row)
        var menu = findNamed(row, "rowMenuButton")
        verify(menu, "the row has no menu button")
        tryVerify(function () { return menu.opacity > 0.99 }, 2000,
                  "the menu button did not come up on hover")
        tipShows(host, menu, "More options", "the row's menu button")
    }

    function test_track_row_download_button() {
        var host = show()
        var t = track()
        var row = place(host, rowC, { title: t.title, artists: t.artists, trackData: t })
        hover(host, row)
        var dl = findNamed(row, "trackDownloadButton")
        verify(dl, "the row has no download button")
        tryVerify(function () { return dl.opacity > 0.99 }, 2000,
                  "the download button did not come up on hover")
        tipShows(host, dl, "Download", "the row's download button")
    }
}
