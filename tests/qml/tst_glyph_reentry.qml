// A glyph that leaves a scene and comes back, which is what a menu's icons do
// every time the menu closes and opens again. VectorIcon and AppMark are the
// two components that draw with a Shape, so each gets a Popup of its own.

import QtQuick
import QtQuick.Controls
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "GlyphReentry"
    when: windowShown

    // Enough trips that a Shape kept across them crashes the software
    // renderer of Qt 6.4 every time.
    readonly property int trips: 40

    Component {
        id: iconHost
        Window {
            width: 200; height: 160
            color: "white"
            property alias popup: pop
            property alias glyph: glyph
            Popup {
                id: pop
                x: 40; y: 30
                padding: 20
                enter: null
                exit: null
                background: Rectangle { color: "white" }
                contentItem: Item {
                    implicitWidth: 48; implicitHeight: 48
                    // Stroked, and with ink in the middle of its box.
                    VectorIcon { id: glyph; name: "clock"; color: "black"; width: 48; height: 48 }
                }
            }
        }
    }

    // On black, so that the only white in the box is the mark's bands.
    Component {
        id: markHost
        Window {
            width: 200; height: 160
            color: "black"
            property alias popup: pop
            property alias glyph: glyph
            Popup {
                id: pop
                x: 40; y: 30
                padding: 20
                enter: null
                exit: null
                background: Rectangle { color: "black" }
                contentItem: Item {
                    implicitWidth: 48; implicitHeight: 48
                    AppMark { id: glyph; width: 48; height: 48 }
                }
            }
        }
    }

    // `light` is what the Shape paints with: black strokes on a white ground
    // for the icon, white bands on a blue tile for the mark.
    function glyphRows() {
        return [{ tag: "VectorIcon", host: iconHost, light: false },
                { tag: "AppMark",    host: markHost, light: true }]
    }

    function shown(component) {
        var host = createTemporaryObject(component, testCase)
        verify(host, "the host window was not created")
        host.visible = true
        waitForRendering(host.contentItem)
        return host
    }

    // A frame is asked for and then waited on. With none pending,
    // waitForRendering() on Qt 6.4 sits out its five seconds.
    function frame(host) {
        host.update()
        waitForRendering(host.contentItem)
    }

    // grabImage() crops at an item's position in its parent, so the content
    // item is grabbed and the glyph is found in window coordinates.
    function grab(host) { return grabImage(host.contentItem) }

    function boxOf(host) {
        var p = host.glyph.mapToItem(null, 0, 0)
        return { x: Math.round(p.x), y: Math.round(p.y),
                 w: Math.round(host.glyph.width), h: Math.round(host.glyph.height) }
    }

    // Pixels the Shape painted, counted in the middle half of the box, which
    // is clear of the mark's rounded corners. A channel runs from 0 to 255.
    function paint(img, box, light) {
        var n = 0
        for (var y = box.y + box.h / 4; y < box.y + 3 * box.h / 4; ++y) {
            for (var x = box.x + box.w / 4; x < box.x + 3 * box.w / 4; ++x) {
                var v = img.red(x, y) + img.green(x, y) + img.blue(x, y)
                if (light ? v > 690 : v < 255) n++
            }
        }
        return n
    }

    function firstDifference(a, b, box) {
        for (var y = box.y; y < box.y + box.h; ++y) {
            for (var x = box.x; x < box.x + box.w; ++x) {
                if (a.red(x, y) !== b.red(x, y) || a.green(x, y) !== b.green(x, y)
                        || a.blue(x, y) !== b.blue(x, y))
                    return x + "," + y
            }
        }
        return ""
    }

    function test_a_glyph_can_leave_the_scene_and_come_back_data() { return glyphRows() }

    function test_a_glyph_can_leave_the_scene_and_come_back(row) {
        var host = shown(row.host)
        for (var i = 0; i < trips; ++i) {
            host.popup.open()
            frame(host)
            host.popup.close()
            frame(host)
        }
        host.popup.open()
        frame(host)
        verify(paint(grab(host), boxOf(host), row.light) > 20,
               row.tag + " drew nothing after " + trips + " trips out of the scene")
    }

    function test_a_returning_glyph_is_the_same_drawing_from_its_first_frame_data() {
        return glyphRows()
    }

    function test_a_returning_glyph_is_the_same_drawing_from_its_first_frame(row) {
        var host = shown(row.host)
        host.popup.open()
        frame(host)
        var box = boxOf(host)
        var before = grab(host)
        var drawn = paint(before, box, row.light)
        verify(drawn > 20, row.tag + " painted only " + drawn + " pixels to begin with")

        host.popup.close()
        frame(host)
        compare(paint(grab(host), box, row.light), 0,
                row.tag + " is still on screen with its popup closed")

        // The grab draws a frame of its own, and no event loop runs between
        // the popup opening and that frame: it is the first one a user gets.
        host.popup.open()
        var first = grab(host)
        compare(paint(first, box, row.light), drawn,
                row.tag + " is not all there in the first frame after it returns")
        compare(firstDifference(before, first, box), "",
                row.tag + " differs from itself in the first frame after it returns")

        frame(host)
        compare(firstDifference(before, grab(host), box), "",
                row.tag + " differs from itself a frame after it returns")
    }
}
