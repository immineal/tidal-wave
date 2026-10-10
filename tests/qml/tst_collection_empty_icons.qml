// The five empty-state glyphs on CollectionPage, at the size they ask for.
// Each is a direct child of a ColumnLayout, which sizes its children from
// Layout.preferredWidth/Height or the implicit size and overwrites a plain
// width/height. The laid-out geometry is measured, because the width
// property still holds the requested number when the layout ignores it.
// Tabs: 0 tracks, 1 albums, 2 artists, 3 playlists, 4 mixes, all empty.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "CollectionEmptyIcons"
    when: windowShown
    width: 1000
    height: 800
    // TestCase declares visible: false, and an invisible tree reports every
    // item invisible and gives a Layout nothing to rearrange.
    visible: true

    readonly property int wanted: 40

    Component { id: holderC;     Item { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }

    function makeCollection(tab) {
        var holder = createTemporaryObject(holderC, testCase)
        verify(holder, "the holder was not created")
        holder.width = 1280
        holder.height = 760
        var page = createTemporaryObject(collectionC, holder, {})
        verify(page, "the collection page was not created")
        page.activeTab = tab
        waitForRendering(page, 2000)
        wait(1)
        return page
    }

    function test_every_empty_state_glyph_is_the_size_it_asks_for_data() {
        return [
            { tag: "tracks",    tab: 0, objName: "collectionEmptyTracksIcon" },
            { tag: "albums",    tab: 1, objName: "collectionEmptyAlbumsIcon" },
            { tag: "artists",   tab: 2, objName: "collectionEmptyArtistsIcon" },
            { tag: "playlists", tab: 3, objName: "collectionEmptyPlaylistsIcon" },
            { tag: "mixes",     tab: 4, objName: "collectionEmptyMixesIcon" },
        ]
    }

    function test_every_empty_state_glyph_is_the_size_it_asks_for(data) {
        var page = makeCollection(data.tab)

        var icon = findChild(page, data.objName)
        verify(icon, "the " + data.tag + " empty state has no glyph named "
                     + data.objName)
        verify(icon.visible,
               "the " + data.tag + " empty state is not showing, so its glyph "
               + "size says nothing - the tab or the fixture is wrong, not the icon")

        // The exact number: a Layout that stretched the glyph to fill would also
        // be wrong.
        compare(icon.width, testCase.wanted,
                "the " + data.tag + " glyph was laid out " + icon.width
                + "px wide, not " + testCase.wanted
                + " - a Layout child sized with width instead of "
                + "Layout.preferredWidth draws at VectorIcon's implicit 24")
        compare(icon.height, testCase.wanted,
                "the " + data.tag + " glyph was laid out " + icon.height
                + "px tall, not " + testCase.wanted)
    }

    // The ink follows the item. VectorIcon draws a 24x24 Shape under a Scale
    // transform, so the drawing is measured through mapToItem. The Shape is
    // found as the visible child, since VectorIcon gives it no objectName.
    function test_the_glyph_inside_is_drawn_at_the_items_size() {
        var page = makeCollection(1)
        var icon = findChild(page, "collectionEmptyAlbumsIcon")
        verify(icon, "the albums empty state has no glyph")

        var shape = null
        for (var i = 0; i < icon.children.length; ++i)
            if (icon.children[i].visible) { shape = icon.children[i]; break }
        verify(shape, "the glyph draws nothing at all")

        var a = shape.mapToItem(icon, 0, 0)
        var b = shape.mapToItem(icon, shape.width, shape.height)
        var inkW = b.x - a.x
        var inkH = b.y - a.y

        // About 34 at 40px and 20 at the implicit 24. A band, so the inset inside
        // VectorIcon stays VectorIcon's business.
        verify(inkW > 30 && inkH > 30,
               "the glyph is drawn " + inkW.toFixed(1) + "x" + inkH.toFixed(1)
               + "px inside a " + icon.width + "x" + icon.height
               + " item - at VectorIcon's implicit 24 this comes out near 20")
        verify(inkW <= testCase.wanted && inkH <= testCase.wanted,
               "the glyph is drawn larger than the item that holds it: "
               + inkW.toFixed(1) + "x" + inkH.toFixed(1))
    }
}
