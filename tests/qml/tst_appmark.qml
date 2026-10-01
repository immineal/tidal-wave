// The app mark, qml/components/AppMark.qml.
//
// The mark used to be the text glyph U+224B set in DejaVu Sans, in two places,
// while the window and tray icons were already assets/icon.svg. So the app
// drew two different logos, and the in-app one changed shape on any machine
// without that font. This file holds the replacement in place: a drawn mark,
// on the theme tokens, with no Text in it anywhere.
//
// Deliberately no pixel geometry here. The band thickness and the wave are in
// one function in AppMark.qml and are allowed to be tuned; what must not come
// back is the font dependency, a hardcoded colour, or a mark that paints
// outside the box it was given.

import QtQuick
import QtQuick.Shapes
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "AppMark"
    width: 200; height: 200
    visible: true
    when: windowShown

    Component {
        id: markC
        AppMark {}
    }

    // Only to prove the no-Text walker below still recognises one.
    Component {
        id: probeC
        Item { Item { Text { text: "x" } } }
    }

    // The sidebar rail draws it at 28, the login page at 64, and 16 is the
    // smallest the mark is ever asked for (the tray).
    function sizes() {
        return [
            { tag: "16", size: 16 },
            { tag: "26", size: 26 },
            { tag: "48", size: 48 },
            { tag: "64", size: 64 }
        ]
    }

    function init() {
        prefs.theme = "midnight"
    }

    function cleanupTestCase() {
        prefs.theme = "midnight"
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function findByName(item, name) {
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    // Every ShapePath hanging off the Shape. They are not Items, so they are
    // in `data` rather than `children`.
    function bandPaths(mark) {
        var shape = findByName(mark, "appMarkBands")
        verify(shape, "the mark has no band Shape")
        var out = []
        for (var i = 0; i < shape.data.length; ++i) {
            if (shape.data[i] instanceof ShapePath) out.push(shape.data[i])
        }
        return out
    }

    function makeMark(size) {
        var mark = createTemporaryObject(markC, testCase, { width: size, height: size })
        verify(mark, "the mark would not instantiate at " + size)
        waitForRendering(mark)
        return mark
    }

    // ── it draws, and it stays inside its box ────────────────────────────

    function test_renders_at_size_data() { return sizes() }

    function test_renders_at_size(data) {
        var mark = makeMark(data.size)

        var tile = findByName(mark, "appMarkTile")
        verify(tile, "no tile at " + data.size)
        verify(tile.visible && tile.width > 0 && tile.height > 0,
               "the tile did not take a size at " + data.size)
        compare(bandPaths(mark).length, 3,
                "the mark should be three bands at " + data.size)
    }

    // A Shape drawn in a fixed 64-unit space and scaled down is the easy way
    // to paint over the edge of a small mark. mapRectToItem carries the Scale
    // transform, so this catches that.
    function test_nothing_overflows_data() { return sizes() }

    function test_nothing_overflows(data) {
        var mark = makeMark(data.size)
        var slop = 0.01
        var bad = []

        function walk(item) {
            var kids = item.children
            for (var i = 0; i < kids.length; ++i) {
                var c = kids[i]
                var r = c.mapToItem(mark, 0, 0, c.width, c.height)
                if (r.x < -slop || r.y < -slop
                    || r.x + r.width > mark.width + slop
                    || r.y + r.height > mark.height + slop) {
                    bad.push(c.objectName + " " + JSON.stringify(r))
                }
                walk(c)
            }
        }
        walk(mark)


        compare(bad.length, 0,
                "at " + data.size + "px the mark paints outside itself: " + bad.join(", "))
    }

    // ── the brand colours, deliberately not the tokens ──────────────────

    // The mark is the same artwork the window, tray and launcher show, and
    // those are a fixed PNG and SVG that cannot follow the in-app palette. A
    // logo that changed colour with the theme would stop reading as the same
    // thing as the icon beside it in the taskbar, so it is pinned to the brand
    // colours on purpose. assets/icon.svg is the source of truth for both.
    function test_tile_and_bands_use_the_brand_colours() {
        var mark = makeMark(64)
        var tile = findByName(mark, "appMarkTile")
        var bands = bandPaths(mark)

        // toString() because a colour read into a var is a value type whose
        // identity is not stable across a repaint; the hex is.
        compare(tile.color.toString(), "#00b2f8")
        for (var i = 0; i < bands.length; ++i)
            compare(bands[i].fillColor.toString(), "#ffffff",
                    "band " + i + " is not the brand white")
    }

    // The inverse of the old contract: switching the theme must NOT repaint
    // it. This is the assertion that catches someone "helpfully" rebinding the
    // mark to Theme.accent again.
    function test_theme_switch_leaves_the_mark_alone() {
        var mark = makeMark(64)
        var tile = findByName(mark, "appMarkTile")
        var bands = bandPaths(mark)
        var names = ["midnight", "forest", "ember", "daylight", "paper", "dawn"]

        for (var t = 0; t < names.length; ++t) {
            prefs.theme = names[t]
            waitForRendering(mark)

            compare(tile.color.toString(), "#00b2f8",
                    names[t] + " changed the mark's tile")
            for (var i = 0; i < bands.length; ++i)
                compare(bands[i].fillColor.toString(), "#ffffff",
                        names[t] + " changed band " + i)
        }

        // ...and the accent really did move across those six, so the test
        // above is not passing because every palette happens to agree.
        var accents = {}
        for (var k = 0; k < names.length; ++k) {
            prefs.theme = names[k]
            accents[Theme.accent.toString()] = true
        }
        verify(Object.keys(accents).length > 1,
               "the accent never changed, so this proves nothing")
    }

    // ── the regression that matters ──────────────────────────────────────

    // The whole point. A glyph mark renders differently, or as a tofu box,
    // wherever the font it was set in is missing.
    function test_no_text_anywhere_data() { return sizes() }

    function test_no_text_anywhere(data) {
        var mark = makeMark(data.size)
        var found = []

        function walk(item) {
            var kids = item.children
            for (var i = 0; i < kids.length; ++i) {
                var c = kids[i]
                // instanceof catches Label and anything else deriving from
                // Text; the string check catches a type that somehow is not
                // registered here.
                if (c instanceof Text || String(c).indexOf("QQuickText") === 0)
                    found.push(String(c))
                walk(c)
            }
        }
        walk(mark)

        compare(found.length, 0,
                "the mark is drawing text again at " + data.size + "px: " + found.join(", "))

        // A walker that recognises nothing would pass this silently, so prove
        // it still finds a Text when there is one.
        found = []
        var probe = createTemporaryObject(probeC, testCase)
        walk(probe)
        compare(found.length, 1, "the Text check has stopped recognising Text")
    }
}
