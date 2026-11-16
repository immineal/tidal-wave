// A cast the device ends itself is said in the one toast, with the device's
// name, so the player bar going back to local does not come out of nowhere.
// Ended here, it says nothing. The cast stub is from tests/TestStubs.h.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "CastEnded"
    when: windowShown

    Component { id: appC; Main { } }

    function init() {
        app.setReducedMotionForTest(true)
        Toasts.dismiss()
    }

    function cleanup() {
        bridge.useCatalogueForTest("")
        Toasts.dismiss()
        if (cast.connected) cast.disconnect()
    }

    function showApp() {
        auth.setStateForTest(2)
        var win = createTemporaryObject(appC, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        win.update()
        verify(waitForRendering(win.contentItem))
        return win
    }

    function test_the_device_ending_the_cast_says_so() {
        showApp()
        cast.connectToDevice("Küche")
        verify(cast.connected)
        cast.endOnDeviceForTest()
        verify(!cast.connected)
        verify(Toasts.shown, "the end on the device went unsaid")
        compare(Toasts.text, "Casting ended on Küche")
        compare(Toasts.actionLabel, "", "the notice offers something to do")
    }

    function test_leaving_the_cast_here_says_nothing() {
        showApp()
        cast.connectToDevice("Küche")
        cast.disconnect()
        wait(50)
        verify(!Toasts.shown, "leaving the cast here was announced: " + Toasts.text)
    }

    function test_in_german() {
        verify(bridge.useCatalogueForTest("de"), "the German catalogue did not load")
        showApp()
        cast.connectToDevice("Küche")
        cast.endOnDeviceForTest()
        compare(Toasts.text, "Übertragung auf Küche beendet")
    }
}
