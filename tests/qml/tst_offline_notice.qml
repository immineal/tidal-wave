// The window while Tidal cannot be reached: one notice above the page with a
// retry, gone by itself once the bridge hears from Tidal again, and a sidebar
// that does not call a library it could not load empty. The stubs are from
// tests/TestStubs.h.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "OfflineNotice"
    when: windowShown

    Component { id: appWindowHost; Main {} }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
        bridge.resetForTest()
        library.setEntriesForTest([])
    }

    function cleanup() {
        bridge.resetForTest()
        library.setLoadFailedForTest(false)
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
        frame(win.contentItem)
        return win
    }

    function test_one_notice_with_a_retry_that_clears_itself() {
        var win = showApp()
        var notice = findChild(win.contentItem, "offlineNotice")
        verify(notice, "the window has no offline notice")
        verify(!notice.visible, "the notice shows while Tidal answers")

        bridge.setOfflineForTest(true)
        frame(win.contentItem)
        verify(notice.visible && notice.height > 20, "offline, the window said nothing")
        mouseClick(findChild(notice, "offlineNoticeRetry"))
        compare(bridge.retryConnectionCallsForTest(), 1, "Try now asked nothing")

        bridge.setOfflineForTest(false)
        frame(win.contentItem)
        verify(!notice.visible, "the notice stayed up once Tidal answered")
        compare(notice.height, 0, "the notice still takes room")
    }

    function test_the_notice_says_when_the_library_is_the_saved_copy() {
        var win = showApp()
        bridge.setLibraryFromCacheForTest(true)
        bridge.setOfflineForTest(true)
        frame(win.contentItem)
        var t = findChild(win.contentItem, "offlineNoticeText")
        verify(t.text.indexOf("last saved") !== -1, "it did not say the library is the saved copy")
    }

    function test_the_sidebar_does_not_call_an_unloaded_library_empty() {
        library.setLoadFailedForTest(true)
        var win = showApp()
        var t = findChild(win.contentItem, "sidebarEmptyText")
        verify(t, "no sidebar empty line")
        compare(t.text, "Your collection could not be loaded")
    }
}
