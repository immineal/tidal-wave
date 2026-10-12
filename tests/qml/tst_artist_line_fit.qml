// components/ArtistLinks.qml on its own line: however wide the line is, no
// name ends past it. A font may draw the last glyph of a name past its
// advance, and "f" is one that several fonts do. Invented names.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ArtistLineFit"
    when: windowShown

    Component {
        id: lineHost
        Window {
            id: win
            width: 720; height: 80
            property alias line: links
            // Main.qml's router, which a click on a name asks for.
            function navigate(page, params) {}
            ArtistLinks {
                id: links
                width: 600
                namePrefix: "fit"
            }
        }
    }

    // Asks the item's window for a frame and waits for it. A window with
    // nothing new to draw swaps no frame.
    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function visibleNamed(item, objectName, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            if (c.objectName === objectName) out.push(c)
            visibleNamed(c, objectName, out)
        }
        return out
    }

    function test_no_name_ends_past_the_line() {
        var host = createTemporaryObject(lineHost, testCase)
        verify(host, "host window was not created")
        var line = host.line
        line.artistList = [
            { id: 11, name: "Blaskapelle Hinterhof" },
            { id: 22, name: "Trio Schilf" },
            { id: 33, name: "Kammerchor am Kliff" },
            { id: 44, name: "Rundfunk-Tanzorchester Salzwiesen" }
        ]
        host.visible = true
        frame(host.contentItem)

        var all = visibleNamed(line, "fitArtistName", [])
        compare(all.length, 4, "the fixture needs a line that holds all four names")
        var full = Math.ceil(line.mapFromItem(all[3], all[3].width, 0).x)
        verify(full < line.width, "the fixture needs a line that holds all four names")

        // Narrower by a few pixels at a time, so each name is the one that
        // elides at several widths.
        var elided = 0
        for (var w = full + 4; w >= 24; w -= 5) {
            line.width = w
            frame(host.contentItem)
            var names = visibleNamed(line, "fitArtistName", [])
            verify(names.length >= 1, "at " + w + "px the line shows no name at all")
            for (var i = 0; i < names.length; i++) {
                var right = line.mapFromItem(names[i], names[i].width, 0).x
                verify(right <= w + 0.5,
                       "at " + w + "px \"" + names[i].text + "\" runs "
                       + (right - w).toFixed(1) + "px past the artist line")
            }
            if (names[names.length - 1].truncated) ++elided
        }
        verify(elided >= 8, "only " + elided + " widths elided a name, so the "
               + "case measured lines that had room")
    }
}
