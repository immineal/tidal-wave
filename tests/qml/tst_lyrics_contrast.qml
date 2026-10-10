// The contrast of the active lyric line against its ground, on every palette.
// The line is drawn in Theme.textPrimary. The floor is 7:1 (WCAG AAA): the
// accents reach 4.5:1 on some palettes, so a lower floor would not catch a
// line painted in the accent. Eighteen rows: six palettes, each with neutral
// and tinted greys, plus true black on the three dark ones. palette() does
// not apply true black to a light palette.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "LyricsContrast"
    when: windowShown

    readonly property int sidebarWidth: 220

    // WCAG 2.1, the same arithmetic tests/tst_theme.cpp uses. Written out
    // here because the colour a delegate is painted in only exists in QML.
    function channel(c) {
        return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
    }

    function luminance(col) {
        return 0.2126 * channel(col.r) + 0.7152 * channel(col.g)
             + 0.0722 * channel(col.b)
    }

    function contrast(a, b) {
        var la = luminance(a), lb = luminance(b)
        var hi = Math.max(la, lb), lo = Math.min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    function makeTrack() {
        return { id: 1001, title: "A Song With Words In It",
                 artists: "Some Artist", albumTitle: "An Album", albumId: 55,
                 artistId: 77, coverUrl: "", coverUrl80: "", duration: 215 }
    }

    function init() {
        app.setReducedMotionForTest(true)
        player.setCurrentTrackForTest(makeTrack())
        player.setDurationForTest(215000)
        player.setPositionForTest(42000)
        prefs.theme = "sea"
        prefs.oledBlack = false
        prefs.tintedGreys = false
    }

    function cleanupTestCase() {
        prefs.theme = "sea"
        prefs.oledBlack = false
        prefs.tintedGreys = false
        app.setReducedMotionForTest(false)
    }

    Component {
        id: nowPlayingHost
        Window {
            id: npWin
            width: 1280; height: 900
            property bool   sleepTimerActive: false
            property bool   sleepStopAtEndOfTrack: false
            property int    sleepTimeLeft: 0
            property bool   sleepIsFading: false
            property bool   sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) { sleepTimerActive = true }
            function cancelSleepTimer() { sleepTimerActive = false }
            function formatSleepTime(seconds) { return "" + seconds }
            function navigate(page, params) {}
            function goBack() {}
            property bool fullScreen: false
            function toggleFullScreen() { fullScreen = !fullScreen }
            property alias page: np
            NowPlayingPage {
                id: np
                x: npWin.fullScreen ? 0 : testCase.sidebarWidth
                width: Math.max(0, npWin.width
                                   - (npWin.fullScreen ? 0 : testCase.sidebarWidth))
                height: npWin.height
            }
        }
    }

    function openLyrics(host) {
        var page = host.page
        var lines = []
        for (var i = 0; i < 12; i++)
            lines.push({ ms: i * 5000, text: "Line " + i + " of a lyric" })
        page.lyricsIsTimed = true
        page.lyricsData    = lines
        page.lyricsState   = "ready"
        page.userScrolled  = false
        page.currentLyricLine = 3
        page.showLyrics    = true
        tryVerify(function () { return page.lyricsness === 1 }, 3000,
                  "the lyrics panel never opened")
        waitForRendering(host.contentItem)
        return page
    }

    // Every realised lyric line, read off the delegates. The page's
    // properties can name an active line that the list paints as inactive.
    function linesOf(page) {
        var view = findChild(page, "nowPlayingLyricsView")
        verify(view, "the lyric list was not found")
        var out = []
        var kids = view.contentItem ? view.contentItem.children : []
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || !c.visible || typeof c.text !== "string"
                    || c.text.length === 0 || !c.font) continue
            out.push(c)
        }
        verify(out.length >= 2,
               "only " + out.length + " lyric line(s) were realised, so there "
               + "is nothing here to tell apart")
        return out
    }

    function activeLine(page) {
        var all = linesOf(page)
        var hit = []
        for (var i = 0; i < all.length; i++)
            if (all[i].active) hit.push(all[i])
        // Exactly one, and the one the page says. With every line active, or
        // none, a colour assertion would pass on the wrong line.
        compare(hit.length, 1,
                hit.length + " of " + all.length + " lyric lines call "
                + "themselves active")
        compare(hit[0].text, "Line " + page.currentLyricLine + " of a lyric",
                "the line that calls itself active is not the one the page is on")
        return hit[0]
    }

    function inactiveLine(page) {
        var all = linesOf(page)
        for (var i = 0; i < all.length; i++)
            if (!all[i].active) return all[i]
        fail("every realised line is the active one")
    }

    // The ground the words are read against while the panel is docked. Read
    // back from the panel, which fades its own fill out in the reading view.
    function panelGround(page) {
        var panel = findChild(page, "nowPlayingLyricsPanel")
        verify(panel, "the lyrics panel was not found")
        verify(panel.color.a > 0.99,
               "the docked panel is " + panel.color.a.toFixed(2)
               + " opaque, so its fill is not the ground the lines are on")
        return panel.color
    }

    function paletteRows() {
        var themes = [{ name: "sea",  dark: true  },
                      { name: "pine", dark: true  },
                      { name: "rust", dark: true  },
                      { name: "sky",  dark: false },
                      { name: "sand", dark: false },
                      { name: "clay", dark: false }]
        var rows = []
        for (var i = 0; i < themes.length; i++) {
            for (var t = 0; t < 2; t++) {
                var tinted = t === 1
                rows.push({ tag: themes[i].name + (tinted ? " tinted" : ""),
                            theme: themes[i].name, dark: themes[i].dark,
                            tinted: tinted, oled: false })
                if (themes[i].dark)
                    rows.push({ tag: themes[i].name
                                     + (tinted ? " tinted" : "") + " true black",
                                theme: themes[i].name, dark: themes[i].dark,
                                tinted: tinted, oled: true })
            }
        }
        return rows
    }

    function applyPalette(row) {
        prefs.theme       = row.theme
        prefs.oledBlack   = row.oled
        prefs.tintedGreys = row.tinted
        compare(ThemePalette.isDark, row.dark,
                row.tag + ": the palette changed side under the switches")
    }

    // ── the deliverable ──────────────────────────────────────────────────

    readonly property real contrastFloor: 7.0

    function test_the_active_lyric_line_is_maximum_contrast_ink_data() {
        return paletteRows()
    }

    function test_the_active_lyric_line_is_maximum_contrast_ink(row) {
        var host = createTemporaryObject(nowPlayingHost, testCase,
                                         { width: 1280, height: 900 })
        host.visible = true
        waitForRendering(host.contentItem)
        var page = openLyrics(host)
        applyPalette(row)
        waitForRendering(host.contentItem)

        var line   = activeLine(page)
        var ground = panelGround(page)
        var ratio  = contrast(line.color, ground)

        // The ratio first: a failure that reports it says more than a hex code.
        verify(ratio >= contrastFloor,
               row.tag + ": the active line is " + ratio.toFixed(2)
               + ":1 against the panel (" + line.color + " on " + ground
               + "), under the " + contrastFloor + ":1 this file holds it to")

        // Then the token by name: the ratio alone would accept any near-white.
        compare(line.color.toString(),
                ThemePalette.current.textPrimary.toString(),
                row.tag + ": the active line is " + line.color
                + " where textPrimary is " + ThemePalette.current.textPrimary)
        verify(line.color.toString() !== ThemePalette.current.accent.toString(),
               row.tag + ": the active line is still the accent")

        // And against the ground the reading view leaves when the panel's fill
        // fades out. Over cover art the top stop is clamped in C++, so bg is the
        // pessimistic case.
        var onPage = contrast(line.color, Theme.bg)
        verify(onPage >= contrastFloor,
               row.tag + ": the active line is " + onPage.toFixed(2)
               + ":1 against the page itself, under " + contrastFloor)

        console.log("CONTRAST " + row.tag
                    + " active=" + line.color + " panel=" + ground
                    + " ratio=" + ratio.toFixed(2)
                    + " onBg=" + onPage.toFixed(2)
                    + " accentWouldBe="
                    + contrast(ThemePalette.current.accent, ground).toFixed(2))
    }

    // The second cues. The active line is the only bold one and the only one
    // at full strength, so weight and opacity mark it as well as ink. The
    // hovered line shares the active line's colour.
    function test_the_active_line_is_marked_by_more_than_colour_data() {
        return paletteRows()
    }

    function test_the_active_line_is_marked_by_more_than_colour(row) {
        var host = createTemporaryObject(nowPlayingHost, testCase,
                                         { width: 1280, height: 900 })
        host.visible = true
        waitForRendering(host.contentItem)
        var page = openLyrics(host)
        applyPalette(row)
        waitForRendering(host.contentItem)

        var active   = activeLine(page)
        var inactive = inactiveLine(page)

        verify(active.font.bold,
               row.tag + ": the active line is not bold")
        verify(!inactive.font.bold,
               row.tag + ": an inactive line is bold too, so weight tells the "
               + "two apart no longer")
        verify(active.opacity > inactive.opacity + 0.05,
               row.tag + ": the active line is at " + active.opacity.toFixed(2)
               + " and an inactive one at " + inactive.opacity.toFixed(2)
               + ", so opacity tells the two apart no longer")
        // The ink differs from an inactive line's, which is the first cue.
        verify(active.color.toString() !== inactive.color.toString(),
               row.tag + ": the active and inactive lines are both "
               + active.color)
        // The active line is read against the inactive ones, so a change that
        // lifted one by flattening the other shows up here.
        var sep = contrast(active.color, inactive.color)
        verify(sep >= 1.5,
               row.tag + ": the active and inactive inks are only "
               + sep.toFixed(2) + ":1 apart")
    }
}
