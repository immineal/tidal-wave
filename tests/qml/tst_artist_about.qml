// The artist's name over the hero photo: no outline, and readable on the
// gradient over the brightest or darkest photo in every palette. Every id and
// name below is invented.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ArtistAbout"
    when: windowShown
    width: 1700
    height: 900
    // TestCase declares visible: false, and an invisible tree reports every
    // item invisible, so a shown section would read as hidden.
    visible: true

    readonly property int artistId: 900000051

    Component { id: holderC; Item { } }
    Component { id: artistC; ArtistPage { anchors.fill: parent } }
    Component { id: swatchC; Rectangle { width: 32; height: 32 } }
    Component { id: metricsC; FontMetrics { } }

    function makePage(width) {
        var holder = createTemporaryObject(holderC, testCase)
        verify(holder, "the holder was not created")
        holder.width = width || 960
        holder.height = 800
        var page = createTemporaryObject(artistC, holder, {})
        verify(page, "the page was not created")
        return page
    }

    // Asks the item's window for a frame and waits for it.
    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function settle(item) {
        frame(item)
        wait(1)
    }

    function open(detail, width) {
        bridge.setArtistForTest(detail, [], [])
        var page = makePage(width)
        page.artistId = testCase.artistId
        settle(page)
        return page
    }

    function cleanup() {
        bridge.resetHeadersForTest()
        prefs.theme = "sea"
        prefs.oledBlack = false
        prefs.tintedGreys = false
    }

    // ── the name over the photo ──────────────────────────────────────────────

    function test_nameHasNoOutline() {
        var page = open({ id: testCase.artistId, name: "Eine Band" })
        var name = findChild(page, "artistName")
        verify(name, "the hero has no name text")
        compare(name.style, Text.Normal)
    }

    // WCAG 2.1, as tests/qml/tst_lyrics_contrast.qml.
    function channel(c) {
        return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
    }
    function luminance(col) {
        return 0.2126 * channel(col.r) + 0.7152 * channel(col.g) + 0.0722 * channel(col.b)
    }
    function contrast(a, b) {
        var la = luminance(a), lb = luminance(b)
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
    }

    // A plain photo of one colour. Inside the hero Image it takes the photo's
    // opacity and its place under the gradient.
    function photoOf(photo, colour) {
        var swatch = createTemporaryObject(swatchC, photo, { color: colour })
        verify(swatch, "the stand-in photo was not created")
        swatch.anchors.fill = photo
        return swatch
    }

    function test_nameReadsOverAWhiteOrBlackPhoto_data() {
        var rows = []
        var themes = ["sea", "pine", "rust", "sky", "sand", "clay"]
        for (var i = 0; i < themes.length; ++i)
            for (var p = 0; p < 2; ++p)
                rows.push({ tag: themes[i] + (p ? " black" : " white"),
                            theme: themes[i], photo: p ? "black" : "white" })
        return rows
    }

    // The ground behind the name's top line, where the photo shows most,
    // against the name's colour. 4.5:1 although the name is large text.
    function test_nameReadsOverAWhiteOrBlackPhoto(row) {
        prefs.theme = row.theme
        // Two lines, so the top of the name sits as high as it can.
        var page = open({ id: testCase.artistId,
                          name: "Ein sehr langer Bandname der sicher zwei Zeilen braucht und noch mehr" }, 900)
        var photo = findChild(page, "artistHeroPhoto")
        var name = findChild(page, "artistName")
        verify(photo && name)
        photoOf(photo, row.photo)
        name.opacity = 0
        settle(page)
        var hero = photo.parent
        var img = grabImage(hero)
        var top = name.mapToItem(hero, 0, 0)
        var worst = 99
        for (var x = top.x + 2; x < top.x + name.width; x += 40) {
            var ground = img.pixel(Math.round(x), Math.round(top.y + 2))
            worst = Math.min(worst, contrast(name.color, ground))
        }
        name.opacity = 1
        verify(worst >= 4.5, row.tag + ": the name reads at " + worst.toFixed(2) + ":1")
    }
}
