// The app mark, qml/components/AppMark.qml: a drawn mark with no Text in
// it, so it needs no font. No pixel geometry is asserted here, since the
// band thickness and the wave may be tuned. What is held: no font
// dependency, the brand colours, and nothing painted outside the box.

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

    // A row glyph, for the test that VectorIcon carries no layer.
    Component {
        id: iconC
        VectorIcon { name: "play" }
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
        prefs.theme = "sea"
    }

    function cleanupTestCase() {
        prefs.theme = "sea"
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

    // ── the edge the curve renderer is here for ──────────────────────────

    // The curve renderer computes edge coverage analytically and needs no
    // multisampling. Guarded on the property, as AppMark is: it arrived in
    // Qt 6.6 and the project still builds against 6.4.
    function test_mark_prefers_the_curve_renderer() {
        var mark = makeMark(64)
        var shape = findByName(mark, "appMarkBands")
        verify(shape, "the mark has no band Shape")

        if (!("preferredRendererType" in shape)) {
            skip("Shape.preferredRendererType needs Qt 6.6; this Qt has no such property")
            return
        }
        compare(shape.preferredRendererType, Shape.CurveRenderer,
                "the mark is back on the renderer that stair-stepped at 2x")
    }

    // A layer is an FBO per item and the curve renderer is per-item GPU work.
    // VectorIcon is drawn once per row in long virtualised lists, so it
    // carries neither.
    function test_row_glyphs_carry_no_layer() {
        var icon = createTemporaryObject(iconC, testCase, { width: 24, height: 24 })
        verify(icon, "VectorIcon would not instantiate")
        waitForRendering(icon)

        var walk = function (item) {
            if (item.layer && item.layer.enabled)
                fail("a VectorIcon child has layer.enabled; that is an FBO on every row glyph")
            var kids = item.children
            for (var i = 0; i < kids.length; ++i) walk(kids[i])
        }
        walk(icon)
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

    // The mark is the artwork the window, tray and launcher show, and those
    // are fixed assets that cannot follow the palette, so the mark is pinned
    // to the brand colours. assets/icon.svg is the source of truth.
    function test_tile_and_bands_use_the_brand_colours() {
        var mark = makeMark(64)
        var tile = findByName(mark, "appMarkTile")
        var bands = bandPaths(mark)

        // toString() because a colour read into a var is a value type whose
        // identity is not stable across a repaint; the hex is.
        compare(tile.color.toString(), "#0079a8")
        for (var i = 0; i < bands.length; ++i)
            compare(bands[i].fillColor.toString(), "#ffffff",
                    "band " + i + " is not the brand white")
    }

    // Switching the theme must not repaint the mark: it has no binding to
    // Theme.accent.
    function test_theme_switch_leaves_the_mark_alone() {
        var mark = makeMark(64)
        var tile = findByName(mark, "appMarkTile")
        var bands = bandPaths(mark)
        var names = ["sea", "pine", "rust", "sky", "sand", "clay"]

        for (var t = 0; t < names.length; ++t) {
            prefs.theme = names[t]
            waitForRendering(mark)

            compare(tile.color.toString(), "#0079a8",
                    names[t] + " changed the mark's tile")
            for (var i = 0; i < bands.length; ++i)
                compare(bands[i].fillColor.toString(), "#ffffff",
                        names[t] + " changed band " + i)
        }

        // The accent has to differ across those six, or the loop above proves
        // nothing.
        var accents = {}
        for (var k = 0; k < names.length; ++k) {
            prefs.theme = names[k]
            accents[Theme.accent.toString()] = true
        }
        verify(Object.keys(accents).length > 1,
               "the accent never changed, so this proves nothing")
    }

    // ── the regression that matters ──────────────────────────────────────

    // A glyph mark renders differently, or as a tofu box, wherever its font
    // is missing.
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
