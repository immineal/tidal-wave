// Selected text in a field is drawn in the theme's accent with its ink, in
// every theme. A field left unset takes the platform's highlight, which is
// a navy that belongs to no theme. tst_design_tokens checks the source of
// every field; this checks what three of them draw.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "TextSelection"
    when: windowShown

    Component { id: hostC; Window { width: 900; height: 700 } }
    Component { id: searchBarC; SearchBar { width: 400 } }
    Component { id: finderC;    LibraryFinder { width: 200 } }
    Component { id: newPlC;     NewPlaylistDialog { } }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        bridge.resetForTest()
    }

    function cleanupTestCase() {
        prefs.theme = "sea"
    }

    // Every item that keeps a text selection: TextInput and TextEdit both
    // have selectedText and selectionColor.
    function fields(item, out) {
        out = out || []
        if (!item) return out
        if (item.selectedText !== undefined && item.selectionColor !== undefined)
            out.push(item)
        for (var i = 0; i < item.children.length; ++i) fields(item.children[i], out)
        return out
    }

    function checkFields(list, what, theme) {
        verify(list.length > 0, what + " has no text field")
        for (var i = 0; i < list.length; ++i) {
            compare(list[i].selectionColor.toString(), Theme.accent.toString(),
                    what + " selects in another colour than the accent in " + theme)
            compare(list[i].selectedTextColor.toString(), Theme.accentInk.toString(),
                    what + " draws selected text in another colour than the accent ink in "
                    + theme)
        }
    }

    function test_fields_select_in_the_accent_data() {
        var rows = []
        var avail = ThemePalette.available()
        for (var i = 0; i < avail.length; i++)
            rows.push({ tag: avail[i].name, theme: avail[i].name })
        return rows
    }

    function test_fields_select_in_the_accent(data) {
        prefs.theme = data.theme
        var host = createTemporaryObject(hostC, testCase)
        host.visible = true

        var bar = createTemporaryObject(searchBarC, host.contentItem)
        bar.text = "abc"
        bar.takeFocus()
        checkFields(fields(bar), "the search field", data.theme)

        var finder = createTemporaryObject(finderC, host.contentItem)
        checkFields(fields(finder), "the collection finder", data.theme)

        var dlg = createTemporaryObject(newPlC, host.contentItem)
        dlg.open()
        tryVerify(function () { return dlg.opened }, 1000)
        checkFields(fields(dlg.contentItem.parent), "the new playlist dialog", data.theme)
        dlg.close()
    }
}
