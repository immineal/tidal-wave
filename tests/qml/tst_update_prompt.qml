// The update prompt: section K of HANDOFF.md, the half that is visible.
//
// The backend (src/ui/UpdateCheck.{h,cpp}, covered by tests/tst_update.cpp)
// decides *whether* there is something to offer. Everything asserted here is
// the other half: that the dialog appears exactly once per launch, that it
// names both versions, that each of the three buttons reaches the right
// invokable, that Escape means "Later" and never "Skip", and that it fits the
// smallest window the app allows (640x600, Main.qml's minimum).
//
// `update` has no double in tests/TestStubs.h, so this file builds its own
// below. It is deliberately not a no-op recorder: skipThisVersion() and
// remindLater() mutate state the way UpdateCheck does (remindLater clears the
// cached release, skip drops the offer), so a handler that calls one and then
// reads a version back is tested against the real shape.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "UpdatePrompt"
    when: windowShown

    // Main.qml's window minimum. The dialog has to fit inside it.
    readonly property int minWindowW: 640
    readonly property int minWindowH: 600

    readonly property string runningVersion: "0.4.0"
    readonly property string newVersion:     "v0.9.9"
    readonly property string newUrl:         "https://github.com/immineal/tidal-wave/releases/tag/v0.9.9"

    // ── the `update` double ──────────────────────────────────────────────

    QtObject {
        id: updateStub

        property bool    updateAvailable: false
        property string  latestVersion: ""
        property string  releaseUrl: ""
        property bool    enabled: true

        property int skipCount:  0
        property int laterCount: 0

        function skipThisVersion() {
            // UpdateCheck::skipThisVersion() returns early with nothing cached.
            if (latestVersion === "") return
            skipCount++
            updateAvailable = false
        }

        function remindLater() {
            // UpdateCheck::remindLater() forgets the release and keeps the
            // timestamp, so the offer is gone until a later check restores it.
            laterCount++
            latestVersion = ""
            releaseUrl = ""
            updateAvailable = false
        }

        function checkNow() {}

        // The state a launch wakes up in when the previous one found a release.
        function offerForTest(tag, url) {
            latestVersion = tag
            releaseUrl = url
            updateAvailable = enabled
        }

        function resetForTest() {
            enabled = true
            latestVersion = ""
            releaseUrl = ""
            updateAvailable = false
            skipCount = 0
            laterCount = 0
        }
    }

    // ── host ─────────────────────────────────────────────────────────────

    // A bare Window, because that is all the prompt needs: it is parented to
    // the window's overlay and knows nothing about the page under it.
    Component {
        id: promptHost
        Window {
            id: win
            width: testCase.minWindowW
            height: testCase.minWindowH
            property alias prompt: p
            UpdatePrompt {
                id: p
                check: updateStub
            }
        }
    }

    function init() {
        updateStub.resetForTest()
        app.resetForTest()
        prefs.setAppVersionForTest(runningVersion)
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function showHost(w, h) {
        var host = createTemporaryObject(promptHost, testCase)
        verify(host, "host window was not created")
        host.width = w
        host.height = h
        host.visible = true
        waitForRendering(host.contentItem)
        return host
    }

    // Opens the dialog and waits until it has actually been laid out. A Popup
    // that is merely `visible` has not been through a render pass yet, and
    // until it has, its content items still report a width of zero.
    function openPrompt(host) {
        var opened = host.prompt.showIfAvailable()
        tryVerify(function() { return host.prompt.visible }, 2000,
                  "the prompt never became visible")
        waitForRendering(host.prompt.contentItem)
        return opened
    }

    function collectText(item, out) {
        if (!item) return out
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false) continue
            if (typeof c.text === "string" && typeof c.wrapMode === "number")
                out.push(c.text)
            collectText(c, out)
        }
        return out
    }

    // Everything the dialog has on it, as one string, so an assertion does not
    // have to know which Text holds which half of a sentence.
    function promptText(prompt) {
        return collectText(prompt.contentItem, []).join(" | ")
    }

    // Collects every visible item that sticks out of its parent horizontally.
    // Four pixels of slack, as in tst_layout_player.qml: focus rings are drawn
    // with a deliberate negative margin.
    function collectOverflow(item, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            if (c.x < -4.5 || c.x + c.width > item.width + 4.5)
                out.push(c.toString().split("(")[0] + " x=" + c.x.toFixed(1)
                         + " w=" + c.width.toFixed(1)
                         + " in a parent " + item.width.toFixed(1) + " wide")
            collectOverflow(c, out)
        }
        return out
    }

    // ── nothing to show ──────────────────────────────────────────────────

    function test_silent_when_no_update() {
        var host = showHost(minWindowW, minWindowH)
        compare(host.prompt.showIfAvailable(), false,
                "the prompt offered itself with no release cached")
        wait(0)
        verify(!host.prompt.visible, "the prompt opened with nothing to offer")
    }

    // updateAvailable is left true on purpose. UpdateCheck already folds
    // `enabled` into it, so the C++ cannot produce this state - which is the
    // point: the dialog has to carry its own guard, or switching the check off
    // in Settings would stop mattering the day that folding changes.
    function test_silent_when_check_disabled() {
        var host = showHost(minWindowW, minWindowH)
        updateStub.latestVersion = newVersion
        updateStub.releaseUrl = newUrl
        updateStub.updateAvailable = true
        updateStub.enabled = false

        compare(host.prompt.showIfAvailable(), false,
                "the prompt offered itself with the check switched off")
        wait(0)
        verify(!host.prompt.visible, "the prompt opened with the check switched off")
    }

    function test_silent_without_a_backend() {
        // Guards the null path: a host that forgets to pass `check` must not
        // throw on the way through showIfAvailable().
        var host = showHost(minWindowW, minWindowH)
        host.prompt.check = null
        compare(host.prompt.showIfAvailable(), false, "the prompt opened with no backend")
    }

    // ── what it says ─────────────────────────────────────────────────────

    function test_shows_and_names_both_versions() {
        var host = showHost(minWindowW, minWindowH)
        updateStub.offerForTest(newVersion, newUrl)

        compare(openPrompt(host), true, "the prompt declined to open")

        var text = promptText(host.prompt)
        verify(text.indexOf(newVersion) !== -1,
               "the new version is not named: " + text)
        verify(text.indexOf(runningVersion) !== -1,
               "the running version is not named: " + text)
    }

    // The user's reason for keeping the feature this shape: it opens a page and
    // stops there. If that line ever goes, the dialog is making a promise the
    // code no longer prints.
    function test_says_it_installs_nothing() {
        var host = showHost(minWindowW, minWindowH)
        updateStub.offerForTest(newVersion, newUrl)
        openPrompt(host)

        var text = promptText(host.prompt).toLowerCase()
        verify(text.indexOf("browser") !== -1,
               "the dialog does not say it opens a browser: " + text)
        verify(text.indexOf("install") !== -1,
               "the dialog does not say it installs nothing: " + text)
    }

    function test_has_the_three_actions() {
        var host = showHost(minWindowW, minWindowH)
        updateStub.offerForTest(newVersion, newUrl)
        openPrompt(host)

        var text = promptText(host.prompt)
        verify(text.indexOf("Open release") !== -1, "no Open release button: " + text)
        verify(text.indexOf("Later") !== -1, "no Later button: " + text)
        verify(text.indexOf("Skip this version") !== -1, "no Skip button: " + text)
    }

    // ── the three actions ────────────────────────────────────────────────

    function test_open_release_opens_the_url() {
        var host = showHost(minWindowW, minWindowH)
        updateStub.offerForTest(newVersion, newUrl)
        openPrompt(host)

        mouseClick(host.prompt.openButton)
        tryVerify(function() { return !host.prompt.visible }, 2000,
                  "Open release left the dialog up")

        compare(app.lastOpenedUrlForTest(), newUrl,
                "Open release did not hand the release URL to app.openUrl()")
        compare(app.openedUrlsForTest().length, 1, "openUrl() was called more than once")
        // Opening the page is not a decision about the offer, so neither of the
        // two persisting actions may fire behind the user's back.
        compare(updateStub.skipCount, 0, "Open release skipped the version")
        compare(updateStub.laterCount, 0, "Open release postponed the version")
    }

    function test_later_postpones_and_closes() {
        var host = showHost(minWindowW, minWindowH)
        updateStub.offerForTest(newVersion, newUrl)
        openPrompt(host)

        mouseClick(host.prompt.laterButton)
        tryVerify(function() { return !host.prompt.visible }, 2000,
                  "Later left the dialog up")

        compare(updateStub.laterCount, 1, "Later did not call remindLater() exactly once")
        compare(updateStub.skipCount, 0, "Later called skipThisVersion()")
        compare(app.openedUrlsForTest().length, 0, "Later opened a browser")
    }

    function test_skip_persists_and_closes() {
        var host = showHost(minWindowW, minWindowH)
        updateStub.offerForTest(newVersion, newUrl)
        openPrompt(host)

        mouseClick(host.prompt.skipButton)
        tryVerify(function() { return !host.prompt.visible }, 2000,
                  "Skip left the dialog up")

        compare(updateStub.skipCount, 1, "Skip did not call skipThisVersion() exactly once")
        compare(updateStub.laterCount, 0, "Skip also postponed the version")
        compare(app.openedUrlsForTest().length, 0, "Skip opened a browser")
    }

    // ── Escape ───────────────────────────────────────────────────────────

    // Escape is "I am not dealing with this now", never "never show me this
    // release again" - a dismissal must not silently throw the release away.
    function test_escape_is_later_not_skip() {
        var host = showHost(minWindowW, minWindowH)
        updateStub.offerForTest(newVersion, newUrl)
        openPrompt(host)

        keyClick(Qt.Key_Escape)
        tryVerify(function() { return !host.prompt.visible }, 2000,
                  "Escape did not close the dialog")

        compare(updateStub.laterCount, 1, "Escape did not count as Later")
        compare(updateStub.skipCount, 0, "Escape skipped the version")
        compare(app.openedUrlsForTest().length, 0, "Escape opened a browser")
    }

    // ── once per launch ──────────────────────────────────────────────────

    // Hosted on the window rather than on a page precisely so navigating
    // cannot rebuild it; this covers the other half, a second deliberate ask.
    function test_does_not_reappear_after_dismissal() {
        var host = showHost(minWindowW, minWindowH)
        updateStub.offerForTest(newVersion, newUrl)
        compare(openPrompt(host), true, "the prompt declined to open")

        mouseClick(host.prompt.laterButton)
        tryVerify(function() { return !host.prompt.visible }, 2000)

        // Put the offer back, as a check completing mid-session would.
        updateStub.offerForTest(newVersion, newUrl)
        compare(host.prompt.showIfAvailable(), false,
                "the prompt offered itself a second time in one session")
        wait(0)
        verify(!host.prompt.visible, "the prompt came back after being dismissed")
        compare(updateStub.laterCount, 1, "the second ask ran a handler")
    }

    // ── size ─────────────────────────────────────────────────────────────

    function test_fits_the_minimum_window() {
        var host = showHost(minWindowW, minWindowH)
        updateStub.offerForTest(newVersion, newUrl)
        openPrompt(host)
        wait(0)

        var p = host.prompt
        verify(p.width <= minWindowW - 64 + 0.5,
               "the dialog is " + p.width + "px wide in a " + minWindowW + "px window")
        verify(p.height <= minWindowH - 64 + 0.5,
               "the dialog is " + p.height + "px tall in a " + minWindowH + "px window")
        verify(p.x >= -0.5 && p.y >= -0.5,
               "the dialog starts off the top or left of the window")
        verify(p.x + p.width <= minWindowW + 0.5 && p.y + p.height <= minWindowH + 0.5,
               "the dialog runs off the bottom or right of the window")

        // The clamp above would hold even if the content no longer fitted, so
        // check the content too: German runs longer than English and this is
        // where that would first show up.
        verify(p.contentItem.implicitHeight <= p.availableHeight + 0.5,
               "the content needs " + p.contentItem.implicitHeight
               + "px but only " + p.availableHeight + "px is left for it")

        var faults = collectOverflow(p.contentItem, [])
        verify(faults.length === 0,
               "the dialog overflows itself:\n  " + faults.join("\n  "))
    }

    function test_fits_data() {
        return [
            { tag: "640x600",   w: 640,  h: 600  },
            { tag: "820x600",   w: 820,  h: 600  },
            { tag: "960x1200",  w: 960,  h: 1200 },
            { tag: "1280x800",  w: 1280, h: 800  }
        ]
    }

    function test_fits(row) {
        var host = showHost(row.w, row.h)
        updateStub.offerForTest(newVersion, newUrl)
        openPrompt(host)
        wait(0)

        var p = host.prompt
        verify(p.width <= row.w - 64 + 0.5 && p.height <= row.h - 64 + 0.5,
               "the dialog is " + p.width + "x" + p.height + " in a " + row.tag + " window")
        var faults = collectOverflow(p.contentItem, [])
        verify(faults.length === 0,
               "the dialog overflows itself at " + row.tag + ":\n  " + faults.join("\n  "))
    }
}
