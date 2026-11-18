// What an icon costs where it is not seen. Every row and card carries several
// that are hidden most of the time (the play glyph until hover, the
// placeholder once the cover is in, the playing bars on every row but one),
// and each made its full set of items anyway.

import QtQuick
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "IconCost"
    when: windowShown
    visible: true
    width: 300; height: 200

    Component { id: iconC; VectorIcon { width: 24; height: 24 } }
    Component { id: barsC; VectorIcon.PlayingIndicator { } }

    function itemsIn(item) {
        var n = 1
        for (var i = 0; i < item.children.length; ++i) n += itemsIn(item.children[i])
        return n
    }
    function named(item, name, out) {
        if (item.objectName === name) out.push(item)
        for (var i = 0; i < item.children.length; ++i) named(item.children[i], name, out)
        return out
    }

    function test_a_hidden_icon_builds_no_glyph() {
        var icon = createTemporaryObject(iconC, testCase, { name: "play", visible: false })
        verify(icon)
        wait(1)
        compare(itemsIn(icon), 5, "a hidden icon is its item, two idle loaders and an empty strip")
        icon.visible = true
        tryVerify(function () { return itemsIn(icon) > 5 }, 1000, "shown, the glyph is drawn")
        var drawn = itemsIn(icon)
        icon.visible = false
        wait(1)
        compare(itemsIn(icon), drawn, "once drawn the glyph is kept, so showing it again is free")
    }

    function test_only_the_track_glyph_has_bars() {
        var icon = createTemporaryObject(iconC, testCase, { name: "album" })
        verify(icon)
        compare(named(icon, "trackBar", []).length, 0)
        icon.name = "track"
        compare(named(icon, "trackBar", []).length, 7)
    }

    // A cover's placeholder is the track glyph, hidden behind the cover.
    function test_a_hidden_track_glyph_builds_no_bars() {
        var icon = createTemporaryObject(iconC, testCase, { name: "track", visible: false })
        verify(icon)
        compare(named(icon, "trackBar", []).length, 0)
        icon.visible = true
        compare(named(icon, "trackBar", []).length, 7)
    }

    function test_hidden_playing_bars_are_not_built() {
        var bars = createTemporaryObject(barsC, testCase, { visible: false })
        verify(bars)
        compare(itemsIn(bars), 3, "the indicator, its box and an empty Repeater")
        bars.visible = true
        compare(itemsIn(bars), 8, "shown, the five bars are built")
    }
}
