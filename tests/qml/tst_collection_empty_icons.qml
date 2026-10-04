// The five empty-state glyphs on CollectionPage, at the size they were asked
// for.
//
// Each of them was written as
//
//     VectorIcon { Layout.alignment: ...; name: "..."; width: 40; height: 40 }
//
// and every one is a direct child of a ColumnLayout. A Layout owns the geometry
// of its direct children, so a plain width/height is assigned once and then
// overwritten on the first rearrange; what survives is the item's implicit size,
// and VectorIcon declares implicitWidth/implicitHeight 24. All five therefore
// drew at 24 where 40 was intended - small enough to read as a different design
// rather than as a bug, which is why it sat there.
//
// This is the repo's own documented trap. CollectionPage's own layout says it
// four lines above the first of these icons ("A ColumnLayout reads
// Layout.preferredHeight, not a plain height, so these spacers have to declare
// it or they collapse to nothing"), RadioPage's back chevron says it again, and
// the panel 8ec30ed added to AlbumPage gets it right. It had never been
// asserted, so nothing stopped the next one.
//
// Measured rather than read. A test that checked the source for
// `Layout.preferredWidth` would pass on a file that sets it to the wrong number,
// and a test that read the `width` *property* would pass on the broken version
// too - the property holds 40, it is the laid-out geometry that is 24. So this
// asks the running item how big it ended up.
//
// The five tabs: 0 tracks, 1 albums, 2 artists, 3 playlists, 4 mixes. Every
// list is empty because the stub's favourites are, which is the state these
// items exist for.

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
    // item invisible - which would make the visibility half of this meaningless
    // and, worse, is the state in which a Layout has nothing to rearrange.
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

        // The number, not merely "bigger than the implicit 24". A Layout that
        // stretched it to fill would also be wrong.
        compare(icon.width, testCase.wanted,
                "the " + data.tag + " glyph was laid out " + icon.width
                + "px wide, not " + testCase.wanted
                + " - a Layout child sized with width instead of "
                + "Layout.preferredWidth draws at VectorIcon's implicit 24")
        compare(icon.height, testCase.wanted,
                "the " + data.tag + " glyph was laid out " + icon.height
                + "px tall, not " + testCase.wanted)
    }

    // And the ink is that big, not just the item.
    //
    // VectorIcon draws into a Shape that is always 24x24 and is blown up by a
    // Scale transform reading `root.width * 0.85 / 24`. So the *child* stays 24
    // whatever happens, and an item of the right size whose drawing had not
    // followed would pass every assertion above. What is measured here is where
    // the Shape's two opposite corners land in the icon's own coordinates, which
    // is mapToItem's job and does apply the transform: 24 * 40 * 0.85 / 24 = 34
    // against 24 * 24 * 0.85 / 24 = 20.4 when the size is the implicit one.
    //
    // Found by shape rather than by name, because VectorIcon is shared with the
    // rest of the app and this file has no business adding an objectName to it.
    // Its two children are the Shape and the strip used for the "track" glyph
    // alone, and only one of them is ever visible.
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

        // 34 at 40px, 20.4 at the implicit 24. Asserted as a band rather than a
        // number so the 0.85 inset inside VectorIcon stays VectorIcon's business.
        verify(inkW > 30 && inkH > 30,
               "the glyph is drawn " + inkW.toFixed(1) + "x" + inkH.toFixed(1)
               + "px inside a " + icon.width + "x" + icon.height
               + " item - at VectorIcon's implicit 24 this comes out near 20")
        verify(inkW <= testCase.wanted && inkH <= testCase.wanted,
               "the glyph is drawn larger than the item that holds it: "
               + inkW.toFixed(1) + "x" + inkH.toFixed(1))
    }
}
