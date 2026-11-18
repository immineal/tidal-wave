// A text field keeps the keyboard only while the user works in it: a press
// anywhere else gives it back to the window, so Space pauses again instead of
// typing into a filter.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "TextFocus"
    when: windowShown

    Component {
        id: appWindowHost
        Main {}
    }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function showApp() {
        var win = createTemporaryObject(appWindowHost, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        win.requestActivate()
        frame(win.contentItem)
        return win
    }

    function findAll(item, name, out) {
        if (item.objectName === name && item.visible) out.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) findAll(kids[i], name, out)
        return out
    }

    function findOne(item, name) {
        var all = findAll(item, name, [])
        verify(all.length > 0, "nothing visible is called " + name)
        return all[0]
    }

    function test_a_tab_click_takes_the_keyboard_from_the_collection_filter() {
        var win = showApp()
        win.navigate("collection")
        frame(win.contentItem)

        var bar = findOne(win.contentItem, "collectionSearch")
        mouseClick(bar)
        tryVerify(function () { return bar.focused }, 2000, "a click did not focus the filter")

        var labels = findAll(win.contentItem, "collectionTabLabel", [])
        verify(labels.length > 1, "the collection shows no tabs")
        mouseClick(labels[1])
        tryVerify(function () { return !bar.focused }, 2000,
                  "the filter kept the keyboard after a tab was clicked")

        keyClick(Qt.Key_Space)
        compare(bar.text, "", "Space typed into the filter")
    }

    function test_a_right_click_on_the_search_page_takes_the_keyboard_from_the_field() {
        var win = showApp()
        win.navigate("search")
        frame(win.contentItem)

        var bar = findOne(win.contentItem, "searchPageBar")
        tryVerify(function () { return bar.focused }, 2000, "the search page did not focus its field")

        var empty = findOne(win.contentItem, "searchEmptyState")
        mouseClick(empty, empty.width / 2, empty.height / 2, Qt.RightButton)
        tryVerify(function () { return !bar.focused }, 2000,
                  "the search field kept the keyboard after a press elsewhere")
    }

    function test_a_click_in_the_field_keeps_the_keyboard_there() {
        var win = showApp()
        win.navigate("collection")
        frame(win.contentItem)

        var bar = findOne(win.contentItem, "collectionSearch")
        mouseClick(bar)
        tryVerify(function () { return bar.focused }, 2000, "a click did not focus the filter")
        mouseClick(bar, bar.width - 20, bar.height / 2)
        wait(50)
        verify(bar.focused, "a second click inside the filter took its focus away")
        keyClick(Qt.Key_A)
        compare(bar.text, "a", "typing after the second click did not reach the filter")
    }
}
