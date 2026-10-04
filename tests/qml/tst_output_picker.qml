// One picker for "where is this playing", and the upright volume slider the
// speaker reveals on hover - in the player bar and in Now Playing, which build
// the same cluster out of the same pieces.
//
// The picker and the speaker live next to each other in both of them and both
// draw upwards, so a good part of this file is about them not getting in each
// other's way.
//
// Two doubles are built below rather than taken from tests/TestStubs.h, which
// this change does not own:
//   * StubPlayer has no availableAudioDevices(), so there would be no local
//     half of the menu to assert anything about;
//   * `cast` is always installed, and null is exactly the state every
//     non-Linux build is in, so it has to be injectable to be tested.
// Both go in through the properties the picker already has for them, the same
// way tst_settings.qml hands SettingsPanel its own device source.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "OutputPicker"
    when: windowShown
    visible: true
    width: 1280
    height: 800

    // ── the doubles ──────────────────────────────────────────────────────

    // Player::availableAudioDevices(): the "System default" sentinel first
    // with an empty id, then the real outputs.
    QtObject {
        id: audioStub
        property int reads: 0
        property var devices: []
        function availableAudioDevices() {
            reads++
            return devices
        }
        // Player::audioDevicesChanged(), raised when a sink appears, goes
        // away, or the system default moves. The real one is emitted from the
        // deferred turn in Player::onAudioOutputsChanged(); here a test emits
        // it by hand, which is the same thing as far as the picker can tell.
        signal audioDevicesChanged()
    }

    function threeDevices() {
        return [
            { id: "",   label: "System default",   isDefault: false },
            { id: "d1", label: "Built-in Analog",  isDefault: false },
            { id: "d2", label: "Scarlett 2i2 USB", isDefault: true  }
        ]
    }

    // ── fixtures ─────────────────────────────────────────────────────────

    function makeTrack() {
        return {
            id: 1001, title: "Ein Titel", artists: "Eine Band",
            albumTitle: "Ein Album", albumId: 42, artistId: 7,
            coverUrl: "", coverUrl80: "", duration: 215
        }
    }

    function init() {
        app.setReducedMotionForTest(true)
        player.setCurrentTrackForTest(makeTrack())
        player.setQueueForTest([makeTrack()], 0)
        player.setManualForTest([])
        player.setVolume(0.5)
        player.setMuted(false)
        prefs.audioDevice = ""
        cast.disconnect()
        cast.setDevicesForTest([])
        audioStub.reads = 0
        audioStub.devices = threeDevices()
    }

    function cleanup() {
        cast.disconnect()
        prefs.audioDevice = ""
    }

    Component {
        id: playerBarHost
        Window {
            id: pbWin
            width: 1280; height: 200
            property alias bar: pb
            PlayerBar {
                id: pb
                width: pbWin.width
                anchors.bottom: parent.bottom
            }
        }
    }

    // NowPlayingPage delegates its sleep timer to Window.window, so it needs a
    // window that answers for it. The same stand-in the other files use.
    Component {
        id: nowPlayingHost
        Window {
            id: npWin
            width: 1280; height: 900
            property alias page: np
            function navigate(page, params) {}
            function goBack() {}
            property bool fullScreen: false
            function toggleFullScreen() { fullScreen = !fullScreen }
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) {}
            function cancelSleepTimer() {}
            function formatSleepTime(seconds) { return "" }
            NowPlayingPage { id: np; width: npWin.width; height: npWin.height }
        }
    }

    function showHost(component, w, h) {
        var host = createTemporaryObject(component, testCase)
        verify(host, "host window was not created")
        host.width = w
        host.height = h
        host.visible = true
        waitForRendering(host.contentItem, 2000)
        return host
    }

    function settle(item) {
        wait(1)
        waitForRendering(item, 2000)
    }

    // ── tree walkers ─────────────────────────────────────────────────────

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function collectVisibleByName(item, name, out) {
        if (!item || item.visible === false) return out
        if (item.objectName === name) out.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) collectVisibleByName(kids[i], name, out)
        return out
    }

    function labelsOf(rows) {
        var out = []
        for (var i = 0; i < rows.length; ++i) out.push(rows[i].label)
        return out
    }

    // The picker's menu is a Popup, so its contents hang off its contentItem
    // and there is nothing to walk until it is open.
    function openPicker(host, picker) {
        picker.deviceSource = audioStub
        picker.openMenu()
        tryVerify(function () { return picker.menu.visible }, 2000,
                  "the output menu did not open")
        settle(host.contentItem)
        return picker.menu.contentItem
    }

    function barPicker(host) {
        var p = host.bar.outputButton
        verify(p, "the player bar has no output button")
        return p
    }

    // ── 1. one menu, two headings ────────────────────────────────────────

    function test_the_menu_lists_local_outputs_and_cast_targets_together() {
        cast.setDevicesForTest([{ id: "c1", name: "Living Room Speaker" },
                                { id: "c2", name: "Kitchen Display" }])
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)

        var local = collectVisibleByName(body, "outputLocalRow", [])
        compare(labelsOf(local).join(", "),
                "System default, Built-in Analog, Scarlett 2i2 USB",
                "the local half of the menu is wrong")

        var remote = collectVisibleByName(body, "outputCastRow", [])
        compare(labelsOf(remote).join(", "), "Living Room Speaker, Kitchen Display",
                "the cast half of the menu is wrong")

        verify(findByName(body, "outputLocalHeading").visible,
               "the local outputs have no heading")
        verify(findByName(body, "outputCastHeading").visible,
               "the cast targets have no heading")
        picker.menu.close()
    }

    // The sentinel is what "follow the system" is, and it has to come first
    // so the list reads as a choice rather than as a device list with an
    // oddity on the end.
    function test_system_default_is_the_first_local_row() {
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)
        var local = collectVisibleByName(body, "outputLocalRow", [])
        compare(local[0].label, "System default")
        verify(local[0].active, "nothing is ticked while prefs.audioDevice is empty")
        picker.menu.close()
    }

    // Hot-pluggable, so the list cannot be read once and kept.
    function test_the_device_list_is_re_read_every_time_the_menu_opens() {
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)
        var first = audioStub.reads
        verify(first > 0, "the menu never asked for a device list")
        picker.menu.close()

        audioStub.devices = [{ id: "", label: "System default", isDefault: false }]
        body = openPicker(host, picker)
        verify(audioStub.reads > first, "re-opening did not re-read the device list")
        compare(collectVisibleByName(body, "outputLocalRow", []).length, 1,
                "the menu still shows a device that went away")
        picker.menu.close()
    }

    // ── 2. picking one ───────────────────────────────────────────────────

    function test_picking_a_local_output_writes_the_preference() {
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)
        var local = collectVisibleByName(body, "outputLocalRow", [])

        local[2].selected()
        compare(prefs.audioDevice, "d2", "the picker did not write prefs.audioDevice")
        verify(!picker.menu.visible, "the menu stayed open after a choice")

        body = openPicker(host, picker)
        local = collectVisibleByName(body, "outputLocalRow", [])
        verify(local[2].active, "the chosen output is not ticked")
        verify(!local[0].active, "two rows are ticked at once")

        // And back to following the system.
        local[0].selected()
        compare(prefs.audioDevice, "", "\"System default\" must clear the setting")
    }

    function test_picking_a_cast_target_connects_to_it() {
        cast.setDevicesForTest([{ id: "c1", name: "Living Room Speaker" }])
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)

        var remote = collectVisibleByName(body, "outputCastRow", [])
        compare(remote.length, 1)
        remote[0].selected()
        compare(cast.lastConnectIdForTest(), "c1", "the row did not connect to its device")
        verify(cast.connected, "the cast did not come up")
        verify(!picker.menu.visible, "the menu stayed open after a choice")
        picker.menu.close()
    }

    // Exactly one row in the whole menu is ticked, and it is the one the
    // sound is going to.
    //
    // The fixture's id and name are the same string on purpose: CastManager
    // reports the device's own name through `deviceName`, which is what the
    // rows match on, while StubCast reports back whatever id it was handed.
    // They have to coincide for the tick to be assertable at all.
    function test_the_row_being_cast_to_is_the_only_one_ticked() {
        cast.setDevicesForTest([{ id: "Living Room Speaker", name: "Living Room Speaker" },
                                { id: "Kitchen Display",     name: "Kitchen Display"     }])
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)
        collectVisibleByName(body, "outputCastRow", [])[0].selected()

        body = openPicker(host, picker)
        var remote = collectVisibleByName(body, "outputCastRow", [])
        verify(remote[0].active, "the device being cast to is not ticked")
        verify(!remote[1].active, "a device nothing is playing on is ticked")
        var local = collectVisibleByName(body, "outputLocalRow", [])
        verify(!local[0].active && !local[1].active && !local[2].active,
               "a local output is still ticked while the sound is on a speaker")
        picker.menu.close()
    }

    // Picking a local output while casting has to stop the cast, or the
    // choice does nothing at all: the sound is not coming out of this
    // machine.
    function test_picking_a_local_output_stops_a_cast() {
        cast.setDevicesForTest([{ id: "c1", name: "Living Room Speaker" }])
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)
        collectVisibleByName(body, "outputCastRow", [])[0].selected()
        verify(cast.connected, "fixture should have left a cast running")

        body = openPicker(host, picker)
        collectVisibleByName(body, "outputLocalRow", [])[1].selected()
        verify(!cast.connected, "picking a speaker on this computer left the cast up")
        compare(prefs.audioDevice, "d1", "and it did not write the preference either")
    }

    // ── 3. the icon says where the sound is ──────────────────────────────

    function iconOf(picker) {
        var kids = picker.children
        for (var i = 0; i < kids.length; ++i)
            if (typeof kids[i].name === "string" && typeof kids[i].strokeWidth === "number")
                return kids[i]
        return null
    }

    function test_the_icon_is_a_speaker_until_it_is_casting() {
        cast.setDevicesForTest([{ id: "c1", name: "Living Room Speaker" }])
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var icon = iconOf(picker)
        verify(icon, "the output button draws no icon")
        compare(icon.name, "speaker", "the idle output button is not a speaker")
        verify(!picker.casting)

        var body = openPicker(host, picker)
        collectVisibleByName(body, "outputCastRow", [])[0].selected()
        settle(host.contentItem)
        verify(picker.casting, "the picker did not notice the cast")
        compare(icon.name, "cast",
                "the bar must show at a glance that the sound has left the machine")

        cast.disconnect()
        settle(host.contentItem)
        compare(icon.name, "speaker", "the icon did not come back")
    }

    // ── 4. no cast backend ───────────────────────────────────────────────

    // Every platform but Linux. The menu is a local picker and nothing else:
    // no heading with nothing under it, and no "searching" line that will
    // never finish.
    function test_the_menu_still_works_with_no_cast_backend() {
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        picker.castSource = null
        var body = openPicker(host, picker)

        compare(collectVisibleByName(body, "outputLocalRow", []).length, 3,
                "the local outputs went away with the cast backend")
        compare(collectVisibleByName(body, "outputCastRow", []).length, 0)
        verify(!findByName(body, "outputCastHeading").visible,
               "a cast heading with nothing under it")
        verify(!findByName(body, "outputCastSearching").visible,
               "a box with no cast backend is not searching for anything")

        collectVisibleByName(body, "outputLocalRow", [])[1].selected()
        compare(prefs.audioDevice, "d1", "the local half stopped working")
        compare(iconOf(picker).name, "speaker")
    }

    // ── 5. the same picker in Now Playing ────────────────────────────────

    function test_now_playing_offers_the_same_picker() {
        cast.setDevicesForTest([{ id: "c1", name: "Living Room Speaker" }])
        var host = showHost(nowPlayingHost, 1280, 900)
        var picker = findByName(host.page, "nowPlayingOutputButton")
        verify(picker, "Now Playing has no output picker")

        var body = openPicker(host, picker)
        compare(collectVisibleByName(body, "outputLocalRow", []).length, 3,
                "Now Playing's picker lists no local outputs")
        compare(collectVisibleByName(body, "outputCastRow", []).length, 1,
                "Now Playing's picker lists no cast targets")

        collectVisibleByName(body, "outputLocalRow", [])[2].selected()
        compare(prefs.audioDevice, "d2", "the page's picker does not write the preference")
    }

    // ── 6. volume on hover ───────────────────────────────────────────────
    //
    // The bar carries no slider at any width now: it says how loud it is in
    // words and reveals the slider, upright, when the speaker or the readout
    // is pointed at. "it can also go into its hover to show bar state, no?
    // also I want that hovered bar to be vertical not horizontal".

    function hover(host, item) {
        var p = item.mapToItem(host.contentItem, item.width / 2, item.height / 2)
        mouseMove(host.contentItem, p.x, p.y)
        wait(1)
    }

    // The widths the bar is measured at, wide and narrow. There is one
    // behaviour across all of them now, which is the thing being pinned: the
    // bar used to answer a hover only below 720.
    function barWidthRows() {
        return [{ tag: "640", w: 640 }, { tag: "720", w: 720 },
                { tag: "960", w: 960 }, { tag: "1280", w: 1280 }]
    }

    function test_the_bar_carries_no_inline_slider_data() { return barWidthRows() }

    function test_the_bar_carries_no_inline_slider(row) {
        var host = showHost(playerBarHost, row.w, 200)
        var bar = host.bar
        settle(host.contentItem)
        verify(!bar.hoverVolumePopup.visible,
               row.tag + ": the flyout is up before anyone pointed at it")
        // Nothing in the bar's own tree draws a slider. The flyout's one is in
        // the overlay, not under the bar, so a walk of the bar finds none.
        var strays = collectVisibleByName(bar, "volumeSliderHandle", [])
        compare(strays.length, 0,
                row.tag + ": the bar still draws " + strays.length
                + " inline volume slider(s)")
        // And what it does draw instead is the level in words.
        verify(bar.volumePercentText.visible,
               row.tag + ": the bar does not say how loud it is")
        compare(bar.volumePercentText.text, "50%",
                row.tag + ": the readout says " + bar.volumePercentText.text)
    }

    function test_hovering_the_speaker_reveals_a_slider_data() { return barWidthRows() }

    function test_hovering_the_speaker_reveals_a_slider(row) {
        var host = showHost(playerBarHost, row.w, 200)
        var bar = host.bar
        settle(host.contentItem)

        hover(host, bar.volumeButton)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 2000,
                  row.tag + ": hovering the speaker revealed no slider")
        var s = bar.hoverVolumeSlider
        verify(s.visible, row.tag + ": the flyout is empty")
        // A Popup forces its content to the size it worked out from the
        // content's implicit size, so a slider with no implicit height comes
        // out as a nothing-tall strip with no hit area at all.
        verify(s.height >= 60 && s.width >= 16,
               row.tag + ": the revealed slider is " + s.width.toFixed(1) + "x"
               + s.height.toFixed(1) + ", too small to aim at")

        // And it is a working slider, not a picture of one.
        s.moved(0.25)
        compare(Math.round(player.volume * 100), 25,
                row.tag + ": the revealed slider does not set the volume")
        verify(!player.muted, row.tag + ": moving the slider should unmute")
        // The readout under it follows, so the two never disagree.
        tryVerify(function () { return bar.volumePercentText.text === "25%" }, 2000,
                  row.tag + ": the readout still says "
                  + bar.volumePercentText.text + " after the slider moved")
    }

    // Vertical, which is the instruction: "I want that hovered bar to be
    // vertical not horizontal". Measured three ways, because a tall box with a
    // horizontal slider in it would pass the first one on its own.
    function test_the_revealed_slider_is_vertical() {
        var host = showHost(playerBarHost, 1280, 200)
        var bar = host.bar
        hover(host, bar.volumeButton)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 2000,
                  "the flyout did not open")
        var s = bar.hoverVolumeSlider
        verify(s.height > s.width * 2,
               "the revealed slider is " + s.width.toFixed(1) + "x"
               + s.height.toFixed(1) + ", which is not upright")

        // The handle travels down the slider as the volume falls, and up as it
        // rises - and does not travel sideways at all.
        var handle = findByName(s, "volumeSliderHandle")
        verify(handle, "the revealed slider has no handle")
        player.setVolume(1)
        wait(0)
        var topY = handle.mapToItem(s, 0, 0).y
        var topX = handle.mapToItem(s, 0, 0).x
        player.setVolume(0)
        wait(0)
        var botY = handle.mapToItem(s, 0, 0).y
        var botX = handle.mapToItem(s, 0, 0).x
        verify(botY - topY >= s.height - handle.height - 1,
               "full to silent moved the handle " + (botY - topY).toFixed(1)
               + "px down a " + s.height.toFixed(1) + "px slider")
        compare(botX.toFixed(1), topX.toFixed(1),
                "the handle moved sideways, so the slider is not upright")
        verify(topY >= -0.01 && botY + handle.height <= s.height + 0.01,
               "the handle runs " + topY.toFixed(1) + ".."
               + (botY + handle.height).toFixed(1) + " in a "
               + s.height.toFixed(1) + "px slider")

        // Louder is higher: the fill is at the bottom.
        var fill = findByName(s, "volumeSliderFill")
        verify(fill, "the revealed slider has no fill")
        player.setVolume(0.25)
        wait(0)
        var fillBottom = fill.mapToItem(s, 0, fill.height).y
        verify(Math.abs(fillBottom - s.height) <= 1.0,
               "the fill ends at " + fillBottom.toFixed(1) + " in a "
               + s.height.toFixed(1) + "px slider, so it is not filling upwards")
        verify(fill.height < s.height / 2,
               "at a quarter volume the fill is " + fill.height.toFixed(1)
               + " of " + s.height.toFixed(1))
    }

    // Upward, out of an 82px bar. Downward there is nothing but the bottom of
    // the screen.
    function test_the_flyout_opens_upward() {
        var host = showHost(playerBarHost, 1280, 200)
        var bar = host.bar
        hover(host, bar.volumeButton)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 2000,
                  "the flyout did not open")
        var popup = bar.hoverVolumePopup
        var btn = bar.volumeButton
        var popupBottom = popup.contentItem.mapToItem(
            host.contentItem, 0, popup.contentItem.height).y
        var btnTop = btn.mapToItem(host.contentItem, 0, 0).y
        verify(popupBottom <= btnTop,
               "the flyout's content runs to " + popupBottom.toFixed(1)
               + " where the speaker starts at " + btnTop.toFixed(1)
               + ", so it did not open upward")
        verify(popup.contentItem.mapToItem(host.contentItem, 0, 0).y >= 0,
               "the flyout opened off the top of the window")
        // Centred on the speaker rather than hanging off one side of it.
        var popupMid = popup.contentItem.mapToItem(
            host.contentItem, popup.contentItem.width / 2, 0).x
        var btnMid = btn.mapToItem(host.contentItem, btn.width / 2, 0).x
        verify(Math.abs(popupMid - btnMid) <= 1.5,
               "the flyout is centred at " + popupMid.toFixed(1)
               + " against a speaker at " + btnMid.toFixed(1))
    }

    // The readout is half of one hover target, not a label beside it: a
    // pointer running along the row reaches the percentage first.
    function test_hovering_the_percentage_reveals_the_slider_too() {
        var host = showHost(playerBarHost, 1280, 200)
        var bar = host.bar
        hover(host, bar.volumePercentText)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 2000,
                  "pointing at the readout revealed no slider")
    }

    // The gap between the two halves is paid inside the readout rather than as
    // a layout margin, so there is no dead strip between them for the pointer
    // to fall into. Downwards now, not sideways: the readout sits under the
    // speaker, so the strip to keep shut is between the glyph's bottom edge and
    // the top of the number's box.
    //
    // At or above, not exactly at. The bar's readout is lifted 7px over the
    // empty bottom of the speaker's 32px tap target, so that the air between
    // the glyph and the digits comes out the same here as in Now Playing
    // (PlayerBar.volumeSpeakerBoxSlack, measured in section 9 below). The two
    // boxes overlap by those 7px, and an overlap belongs to both of them -
    // which is this promise with room to spare. Only a gap belongs to neither.
    function test_the_speaker_and_the_readout_touch() {
        var host = showHost(playerBarHost, 1280, 200)
        var bar = host.bar
        var btn = bar.volumeButton
        var pct = bar.volumePercentText
        var btnBottom = btn.mapToItem(bar, 0, btn.height).y
        var pctTop    = pct.mapToItem(bar, 0, 0).y
        verify(pctTop - btnBottom <= 0.5,
               "the readout starts at y=" + pctTop.toFixed(1)
               + " where the speaker ends at " + btnBottom.toFixed(1)
               + ", leaving a strip that belongs to neither")
        // And the far ends: the two of them between them cover every row of the
        // stack, so there is nowhere inside it a pointer is over neither.
        var stack = bar.volumeStack
        var top    = btn.mapToItem(stack, 0, 0).y
        var bottom = pct.mapToItem(stack, 0, pct.height).y
        verify(top <= 0.5 && bottom >= stack.height - 0.5,
               "the pair covers " + top.toFixed(1) + "-" + bottom.toFixed(1)
               + " of a " + stack.height.toFixed(1)
               + "px stack, so an end of it is hovered by neither of them")
        // And the pointer really can cross the seam: a hover there opens the
        // flyout, which is the thing the arithmetic above is for. Aimed one row
        // under the speaker's bottom edge, which is the row that used to be the
        // readout's first and is now 7px into it.
        verify(!bar.hoverVolumePopup.visible, "the flyout is up unprompted")
        var seam = btn.mapToItem(host.contentItem, btn.width / 2, btn.height + 1)
        mouseMove(host.contentItem, seam.x, seam.y)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 2000,
                  "the seam between the speaker and the readout dropped the hover")
    }

    // Pointing somewhere else puts it away again.
    function test_the_flyout_closes_when_the_pointer_leaves() {
        var host = showHost(playerBarHost, 640, 200)
        var bar = host.bar
        hover(host, bar.volumeButton)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 2000,
                  "the flyout did not open")

        mouseMove(host.contentItem, 20, 20)
        tryVerify(function () { return !bar.hoverVolumePopup.visible }, 2000,
                  "the flyout stayed up after the pointer left")
    }

    // ...but not at once. A pointer travelling diagonally from the speaker
    // into the slider above it is off both of them for a frame or two, and a
    // flyout that closed on that frame could never be reached.
    function test_the_flyout_waits_before_closing() {
        var host = showHost(playerBarHost, 1280, 200)
        var bar = host.bar
        hover(host, bar.volumeButton)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 2000,
                  "the flyout did not open")

        // Off both of them, the way the diagonal crossing is.
        mouseMove(host.contentItem, 20, 20)
        wait(40)
        verify(bar.hoverVolumePopup.visible,
               "the flyout shut 40ms after the pointer left it, which is inside"
               + " the time a pointer takes to cross into it")
        // And coming back inside the grace period keeps it, rather than
        // closing and reopening.
        hover(host, bar.volumeButton)
        wait(40)
        verify(bar.hoverVolumePopup.visible,
               "the flyout did not survive the pointer coming back")
    }

    // The speaker still mutes. The flyout is hover-only, so it never takes a
    // click, and that is half of how it stays out of the output menu's way.
    function test_the_speaker_still_mutes_on_a_click() {
        var host = showHost(playerBarHost, 640, 200)
        var bar = host.bar
        var btn = bar.volumeButton
        var p = btn.mapToItem(host.contentItem, btn.width / 2, btn.height / 2)
        mouseClick(host.contentItem, p.x, p.y)
        wait(1)
        verify(player.muted, "clicking the speaker no longer mutes")
    }

    // The other half: both of these draw upwards out of the same 82px bar,
    // so the output menu wins outright while it is open.
    function test_the_output_menu_and_the_hover_slider_are_never_both_up() {
        var host = showHost(playerBarHost, 640, 200)
        var bar = host.bar
        var picker = barPicker(host)

        hover(host, bar.volumeButton)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 2000,
                  "the flyout did not open")

        openPicker(host, picker)
        tryVerify(function () { return !bar.hoverVolumePopup.visible }, 2000,
                  "the slider stayed over the bar while the output menu was open")

        // And it does not come back while the menu is still up, pointer or
        // no pointer.
        hover(host, bar.volumeButton)
        wait(80)
        verify(!bar.hoverVolumePopup.visible,
               "hovering reopened the slider underneath the output menu")
        picker.menu.close()
    }

    // The output button is a separate control from the speaker, and pointing
    // at it is not a request for the volume slider.
    function test_hovering_the_output_button_does_not_reveal_the_slider() {
        var host = showHost(playerBarHost, 640, 200)
        var bar = host.bar
        hover(host, bar.outputButton)
        wait(80)
        verify(!bar.hoverVolumePopup.visible,
               "the output button is not the volume control")
    }

    // ── 6b. the same control in Now Playing ──────────────────────────────
    //
    // One behaviour everywhere: the page builds its cluster out of the same
    // pieces and reveals the same PlayerBar.VolumeFlyout. These cases are the
    // page's half of the bargain, because a shared component is only shared
    // while both callers still wire it up.

    // The cluster the page is actually drawing. Both exist at all times and
    // the live objectNames follow whichever is visible.
    function liveCluster(page) {
        var riding = findByName(page, "nowPlayingVolumeCluster")
        var ownRow = findByName(page, "nowPlayingVolumeOwnCluster")
        verify(riding && ownRow, "the page is missing one of its two clusters")
        verify(riding.visible !== ownRow.visible,
               "the page is drawing " + (riding.visible ? "both" : "neither")
               + " of its volume clusters")
        return riding.visible ? riding : ownRow
    }

    function offstageCluster(page) {
        var riding = findByName(page, "nowPlayingVolumeCluster")
        var ownRow = findByName(page, "nowPlayingVolumeOwnCluster")
        return riding.visible ? ownRow : riding
    }

    // A Popup is not an Item, so it is not in the cluster's `children` and no
    // tree walk will find it. The cluster hands it over instead.
    function nowPlayingFlyout(page) {
        var f = liveCluster(page).flyout
        verify(f, "the page's live cluster has no volume flyout")
        return f
    }

    function test_the_page_reveals_the_same_vertical_slider() {
        var host = showHost(nowPlayingHost, 1280, 900)
        var page = host.page
        settle(host.contentItem)

        var mute = findByName(page, "nowPlayingMuteButton")
        verify(mute, "the page has no mute button")
        var flyout = nowPlayingFlyout(page)
        verify(!flyout.visible, "the page's flyout is up before anyone pointed at it")

        hover(host, mute)
        tryVerify(function () { return flyout.visible }, 2000,
                  "pointing at the page's speaker revealed no slider")
        var s = flyout.slider
        verify(s.height > s.width * 2,
               "the page's revealed slider is " + s.width.toFixed(1) + "x"
               + s.height.toFixed(1) + ", which is not upright")
        // A tall box is not an upright slider: the handle has to run down it.
        // A horizontal slider in a 20x110 popup passes the line above and
        // nothing else here.
        var handle = findByName(s, "volumeSliderHandle")
        verify(handle, "the page's revealed slider has no handle")
        player.setVolume(1)
        wait(0)
        var topY = handle.mapToItem(s, 0, 0).y
        player.setVolume(0)
        wait(0)
        var botY = handle.mapToItem(s, 0, 0).y
        verify(botY - topY >= s.height - handle.height - 1,
               "full to silent moved the page's handle " + (botY - topY).toFixed(1)
               + "px down a " + s.height.toFixed(1) + "px slider")

        // Upward here too: below the transport row is the Up Next list.
        var popupTop = s.mapToItem(host.contentItem, 0, 0).y
        var muteTop  = mute.mapToItem(host.contentItem, 0, 0).y
        verify(popupTop < muteTop,
               "the page's flyout starts at " + popupTop.toFixed(1)
               + " against a speaker at " + muteTop.toFixed(1))

        s.moved(0.4)
        compare(Math.round(player.volume * 100), 40,
                "the page's revealed slider does not set the volume")
    }

    // The page draws no slider at rest either: three controls, and the fourth
    // is in the overlay only while it is wanted.
    function test_the_page_carries_no_inline_slider() {
        var host = showHost(nowPlayingHost, 1280, 900)
        var page = host.page
        settle(host.contentItem)
        var strays = collectVisibleByName(page, "volumeSliderHandle", [])
        compare(strays.length, 0,
                "the page still draws " + strays.length + " inline volume slider(s)")
    }

    // Two clusters exist and one is drawn, so two flyouts exist as well. The
    // offstage one must never answer a hover it cannot have received.
    function test_only_the_live_cluster_can_open_a_flyout() {
        var host = showHost(nowPlayingHost, 1280, 900)
        var page = host.page
        settle(host.contentItem)
        var mute = findByName(page, "nowPlayingMuteButton")
        hover(host, mute)
        tryVerify(function () { return nowPlayingFlyout(page).visible }, 2000,
                  "the live cluster's flyout did not open")
        var offstage = offstageCluster(page).flyout
        verify(offstage, "the offstage cluster has no flyout, so this case is blind")
        compare(offstage.objectName, "nowPlayingVolumeFlyoutOffstage",
                "the offstage flyout is wearing the live name")
        verify(!offstage.visible,
               "the cluster that is not on screen put a slider on it")
    }

    // The page's picker and the page's flyout draw into the same space, the
    // same way the bar's two do.
    function test_the_pages_output_menu_also_wins() {
        var host = showHost(nowPlayingHost, 1280, 900)
        var page = host.page
        settle(host.contentItem)
        var mute = findByName(page, "nowPlayingMuteButton")
        var flyout = nowPlayingFlyout(page)
        hover(host, mute)
        tryVerify(function () { return flyout.visible }, 2000,
                  "the page's flyout did not open")

        var picker = findByName(page, "nowPlayingOutputButton")
        verify(picker, "the page has no output picker")
        openPicker(host, picker)
        tryVerify(function () { return !flyout.visible }, 2000,
                  "the page's slider stayed up while its output menu was open")
        picker.menu.close()
    }

    // ── 7. telling four sinks on one card apart ──────────────────

    // What the Debian box actually reports: one synthetic default and four
    // PipeWire sinks that all belong to the same controller. ALSA names a
    // sink after the card first and the socket last, so the first thirty-odd
    // characters are identical and the only part that says which socket this
    // is sits at the very end - which is exactly what elide-right threw away.
    // Every row read "Tiger Lake-H HD Audio Contr…" and the user could not
    // pick. A short-named sink hot-plugged in beside them rendered in full,
    // which is what proved it was width against length and nothing else.
    function tigerLake() {
        return [
            { id: "",   label: "System default", isDefault: false },
            { id: "s1", label: "Tiger Lake-H HD Audio Controller Speaker", isDefault: true },
            { id: "s2", label: "Tiger Lake-H HD Audio Controller HDMI / DisplayPort 1", isDefault: false },
            { id: "s3", label: "Tiger Lake-H HD Audio Controller HDMI / DisplayPort 2", isDefault: false },
            { id: "s4", label: "Tiger Lake-H HD Audio Controller HDMI / DisplayPort 3", isDefault: false }
        ]
    }

    function labelTextOf(row) {
        var t = findByName(row, "outputRowLabel")
        verify(t, "an output row draws no label")
        return t
    }

    function test_four_sinks_on_one_card_do_not_all_read_the_same() {
        audioStub.devices = tigerLake()
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)

        var rows = collectVisibleByName(body, "outputLocalRow", [])
        compare(rows.length, 5, "the menu lost a sink")

        var seen = ({})
        for (var i = 0; i < rows.length; ++i) {
            var t = labelTextOf(rows[i])
            verify(!t.truncated,
                   "row " + i + " still does not fit: \"" + t.text
                   + "\" is drawn for \"" + rows[i].fullLabel + "\"")
            verify(seen[t.text] === undefined,
                   "two rows both read \"" + t.text
                   + "\"; nothing in the menu tells them apart")
            seen[t.text] = true
        }

        // And what survived is the end of the name. The end is the part that
        // says which socket the sound comes out of.
        var tails = ["Speaker", "DisplayPort 1", "DisplayPort 2", "DisplayPort 3"]
        for (var j = 0; j < tails.length; ++j) {
            var drawn = labelTextOf(rows[j + 1]).text
            verify(drawn.indexOf(tails[j]) !== -1,
                   "row " + (j + 1) + " reads \"" + drawn + "\" and has lost \""
                   + tails[j] + "\", which is the only part that named it")
        }
        picker.menu.close()
    }

    // Folding the card name away is only safe because the row still knows the
    // whole string, which is what its tooltip shows.
    function test_a_folded_row_still_knows_the_whole_name() {
        audioStub.devices = tigerLake()
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)
        var rows = collectVisibleByName(body, "outputLocalRow", [])

        verify(rows[1].label !== rows[1].fullLabel,
               "nothing was folded here, so this case proves nothing")
        compare(rows[1].fullLabel, "Tiger Lake-H HD Audio Controller Speaker",
                "the row forgot the name it stands for")
        compare(rows[0].label, "System default",
                "the sentinel is not hardware and must never be folded")
        picker.menu.close()
    }

    // The degenerate case the fold has to survive: a box with two cards, where
    // no prefix is common to everything. The pair that does share one is
    // folded; the odd one out keeps its whole name, and nothing truncates.
    function test_a_device_that_shares_no_prefix_keeps_its_whole_name() {
        audioStub.devices = [
            { id: "",   label: "System default", isDefault: false },
            { id: "s1", label: "Tiger Lake-H HD Audio Controller Speaker", isDefault: false },
            { id: "s2", label: "Tiger Lake-H HD Audio Controller HDMI / DisplayPort 1", isDefault: false },
            { id: "u1", label: "Scarlett 2i2 USB", isDefault: true }
        ]
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)
        var rows = collectVisibleByName(body, "outputLocalRow", [])
        compare(rows.length, 4)

        compare(rows[3].label, "Scarlett 2i2 USB",
                "a device with nothing in common with the others lost part of its name")
        verify(rows[1].label !== rows[1].fullLabel,
               "the two sinks that do share a card name were not folded")
        for (var i = 0; i < rows.length; ++i)
            verify(!labelTextOf(rows[i]).truncated,
                   "row " + i + " does not fit: \"" + labelTextOf(rows[i]).text + "\"")
        picker.menu.close()
    }

    // A shared prefix that is short is not the problem, and folding it would
    // read worse than leaving it: "Speaker Left" must not become "… Left".
    function test_a_short_shared_prefix_is_left_alone() {
        audioStub.devices = [
            { id: "",  label: "System default", isDefault: false },
            { id: "a", label: "Speaker Left",   isDefault: false },
            { id: "b", label: "Speaker Right",  isDefault: false }
        ]
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)
        var rows = collectVisibleByName(body, "outputLocalRow", [])
        compare(labelsOf(rows).join(", "), "System default, Speaker Left, Speaker Right",
                "a prefix this short should have been left where it was")
        picker.menu.close()
    }

    // One long-named sink and nothing to fold it against. There is no prefix
    // to hide, so the backstop has to carry it: the middle goes, not the end.
    function test_a_lone_long_name_loses_its_middle_and_not_its_end() {
        audioStub.devices = [
            { id: "",   label: "System default", isDefault: false },
            { id: "s1", label: "Tiger Lake-H HD Audio Controller Speaker", isDefault: true }
        ]
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)
        var rows = collectVisibleByName(body, "outputLocalRow", [])

        compare(rows[1].label, rows[1].fullLabel,
                "there was nothing to fold against, so the name should be whole")
        compare(labelTextOf(rows[1]).elide, Text.ElideMiddle,
                "with nothing to fold, only eliding the middle keeps the end of the "
                + "name, and the end is the part that names the socket")
        picker.menu.close()
    }

    // ── 8. hot-plug with the menu already open ───────────────────

    // `pactl load-module` with the picker up: the menu did not change, and
    // closing and reopening it was the only way to see the new sink.
    function test_a_sink_added_while_the_menu_is_open_appears_in_it() {
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)
        compare(collectVisibleByName(body, "outputLocalRow", []).length, 3)

        audioStub.devices = threeDevices().concat(
            [{ id: "hp", label: "TwaveHotplugTest", isDefault: false }])
        audioStub.audioDevicesChanged()

        tryVerify(function () {
            return collectVisibleByName(body, "outputLocalRow", []).length === 4
        }, 2000, "a sink plugged in while the picker was open never showed up in it")
        verify(picker.menu.visible, "the menu closed instead of refreshing")
        compare(labelsOf(collectVisibleByName(body, "outputLocalRow", []))[3],
                "TwaveHotplugTest", "the new sink is not the one that appeared")
        picker.menu.close()
    }

    function test_a_sink_removed_while_the_menu_is_open_goes_away() {
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        var body = openPicker(host, picker)
        compare(collectVisibleByName(body, "outputLocalRow", []).length, 3)

        audioStub.devices = [{ id: "", label: "System default", isDefault: false }]
        audioStub.audioDevicesChanged()

        tryVerify(function () {
            return collectVisibleByName(body, "outputLocalRow", []).length === 1
        }, 2000, "the menu still offers a sink that has been unplugged")
        picker.menu.close()
    }

    // The refresh is not an excuse to put a menu on screen. Nobody asked for
    // one, and the next open still has to be fresh.
    function test_a_hot_plug_does_not_open_a_menu_nobody_asked_for() {
        var host = showHost(playerBarHost, 1280, 200)
        var picker = barPicker(host)
        picker.deviceSource = audioStub
        verify(!picker.menu.visible, "the menu is up before anything opened it")

        audioStub.devices = threeDevices().concat(
            [{ id: "hp", label: "TwaveHotplugTest", isDefault: false }])
        audioStub.audioDevicesChanged()
        wait(60)
        verify(!picker.menu.visible, "a hot-plug opened the output menu on its own")

        var body = openPicker(host, picker)
        compare(collectVisibleByName(body, "outputLocalRow", []).length, 4,
                "opening the menu after a hot-plug showed a stale list")
        picker.menu.close()
    }

    // Now Playing instantiates the same component, so it has to get the same
    // refresh - that is the whole reason this lives in the component and not
    // at one of the two call sites.
    function test_now_playings_picker_refreshes_on_a_hot_plug_too() {
        var host = showHost(nowPlayingHost, 1280, 900)
        var picker = findByName(host.page, "nowPlayingOutputButton")
        verify(picker, "Now Playing has no output picker")
        var body = openPicker(host, picker)
        compare(collectVisibleByName(body, "outputLocalRow", []).length, 3)

        audioStub.devices = threeDevices().concat(
            [{ id: "hp", label: "TwaveHotplugTest", isDefault: false }])
        audioStub.audioDevicesChanged()

        tryVerify(function () {
            return collectVisibleByName(body, "outputLocalRow", []).length === 4
        }, 2000, "Now Playing's picker did not notice the hot-plug")
        picker.menu.close()
    }

    // ── 9. the number reads as the speaker's caption ─────────────────────
    //
    // The user, on the pair of them: "The volume icon and the percentage can go
    // closer together. At the moment, they have pretty much the same spacing as
    // each does to the output selector, which doesn't make sense. Like they are
    // contextually relevant to one another, they can be closer together. and the
    // same distance in the bar and now playing please."
    //
    // Two requirements, and neither one is a constant:
    //
    //   * the same distance in the two places. Both files already paid the gap
    //     as the readout's own 4px topPadding, the same number in both - and the
    //     two still did not match. The bar's speaker is an IconButton, whose box
    //     is Math.max(size + 12, 32): a 32px tap target around an 18px glyph,
    //     with 7px of empty box under the glyph that Now Playing's bare 18px
    //     Item does not have. Same number, 7px more air in the bar: 19px against
    //     12 at the level this case sets, 18 against 11 at a louder one. What the
    //     user is comparing is the air, so that is what is compared here, and a
    //     case that read volumeStackGap out of the two files would have agreed
    //     with itself while the screen disagreed;
    //
    //   * and the pair has to read as one object, which means the air inside it
    //     has to be clearly less than the air between it and the output picker.
    //     In the bar that was 19px against the 25 to the picker: "pretty much the
    //     same spacing", exactly as reported.
    //
    // Measured as ink, not as geometry, because every box here is bigger than
    // what is drawn in it. A Text's box carries the font's ascent above the
    // digits' caps - 4px at this size - and reports none of it. VectorIcon is
    // worse: its Shape is permanently 24x24 and blown up by a Scale transform,
    // so the glyph's own item rect is not where the paint lands either, and the
    // ink stops short of it at both ends. Nothing short of the painted pixels
    // answers "how far apart do these look".
    //
    // The volume is init()'s 0.5, so the glyph is "volume-mid" and the readout
    // "50%" in both places: the same ink on both sides of the gap, which is what
    // makes the two numbers comparable at all. A different level picks one of the
    // other three speaker glyphs, whose ink is a pixel shorter or taller - and is
    // so in both places at once, which is why the two can be held equal while
    // neither is held to a number.

    // grabImage(item) grabs the whole window and then crops it at the item's
    // x/y - which are its coordinates in its *parent*, not in the window. Only
    // an item parented straight to the window's content item therefore grabs
    // itself. A volume stack six layouts deep grabs whatever sits at the same
    // offset from the window's corner, which for the player bar is the empty air
    // above the bar: a clean white rectangle in which every measurement below
    // reads zero. Written the wrong way round, this case reports no ink at all
    // rather than a wrong gap - which is only useful because the band count is
    // checked, and is why it is.
    //
    // So the content item is what is grabbed - its x/y are 0, so the crop is the
    // whole window - and everything is indexed in window coordinates.
    //
    // Twice, because the first grab of a freshly shown window comes back blank.
    function windowInk(host) {
        grabImage(host.contentItem)
        return grabImage(host.contentItem)
    }

    // The surface a cluster sits on, sampled from a corner of the item being
    // measured: the stack is 36 wide around an 18px glyph and the picker 32
    // around a 20px one, so both corners are bare surface in both places.
    function surfaceAt(img, rect) {
        return { r: img.red(rect.x, rect.y),
                 g: img.green(rect.x, rect.y),
                 b: img.blue(rect.x, rect.y) }
    }

    // Paint rather than surface. A sum over the three channels: far above the
    // noise on a flat fill, far below Theme.textDim's contrast against it.
    function inked(img, ref, x, y) {
        return Math.abs(img.red(x, y)   - ref.r)
             + Math.abs(img.green(x, y) - ref.g)
             + Math.abs(img.blue(x, y)  - ref.b) > 24
    }

    function rowHasInk(img, ref, rect, y) {
        for (var x = rect.x; x < rect.x + rect.w; ++x)
            if (inked(img, ref, x, y)) return true
        return false
    }

    function colHasInk(img, ref, rect, x) {
        for (var y = rect.y; y < rect.y + rect.h; ++y)
            if (inked(img, ref, x, y)) return true
        return false
    }

    // The rows of `rect` that carry paint, grouped into runs of consecutive
    // rows. A speaker over a readout is two runs with blank rows between them,
    // and the count is half the assertion: one run means one of the two drew
    // nothing - the trap this file's neighbours keep falling into, where an item
    // of the right size whose painting never happened still answers visible and
    // still measures correctly.
    function inkBands(img, ref, rect) {
        var bands = []
        var open = null
        for (var y = rect.y; y < rect.y + rect.h; ++y) {
            if (rowHasInk(img, ref, rect, y)) {
                if (open === null) { open = { top: y, bottom: y }; bands.push(open) }
                else open.bottom = y
            } else {
                open = null
            }
        }
        return bands
    }

    function boxOf(item, root) {
        var p = item.mapToItem(root, 0, 0)
        return { x: Math.round(p.x), y: Math.round(p.y),
                 w: Math.round(item.width), h: Math.round(item.height) }
    }

    // The air between the glyph's last painted row and the digits' first.
    function speakerToReadoutInk(img, stack, root, where) {
        var rect = boxOf(stack, root)
        var ref = surfaceAt(img, rect)
        var bands = inkBands(img, ref, rect)
        compare(bands.length, 2,
                where + ": the stack paints " + bands.length + " band(s) of ink "
                + "in its " + rect.w + "x" + rect.h + " box, not the speaker and "
                + "the readout - one of the two drew nothing")
        verify(bands[0].bottom - bands[0].top >= 4 && bands[1].bottom - bands[1].top >= 4,
               where + ": the two bands are " + (bands[0].bottom - bands[0].top + 1)
               + " and " + (bands[1].bottom - bands[1].top + 1) + " rows of ink, "
               + "which is too little of either to be a glyph and a number")
        return bands[1].top - bands[0].bottom - 1
    }

    // ...and the air between the pair and the picker beside it: the rightmost
    // painted column of the stack against the leftmost of the picker. The two
    // boxes do not overlap, so neither can be mistaken for the other.
    function stackToPickerInk(img, stack, picker, root, where) {
        var sRect = boxOf(stack, root)
        var pRect = boxOf(picker, root)
        verify(pRect.x >= sRect.x + sRect.w,
               where + ": the picker starts at x=" + pRect.x
               + " inside a stack that ends at " + (sRect.x + sRect.w))
        var sRef = surfaceAt(img, sRect)
        var pRef = surfaceAt(img, pRect)
        var last = -1
        for (var x = sRect.x; x < sRect.x + sRect.w; ++x)
            if (colHasInk(img, sRef, sRect, x)) last = x
        var first = -1
        for (x = pRect.x; x < pRect.x + pRect.w && first < 0; ++x)
            if (colHasInk(img, pRef, pRect, x)) first = x
        verify(last >= 0, where + ": the volume stack painted nothing at all")
        verify(first >= 0, where + ": the output picker painted nothing at all")
        return first - last - 1
    }

    // The mechanism, kept honest. The bar buys its half of this by lifting the
    // readout over the empty bottom of the speaker's tap target, and a lift is
    // only allowed to overlap: the moment the readout's box stops reaching the
    // speaker's there is a strip inside the stack that neither of them hovers,
    // and a pointer travelling from the glyph down to the number drops the
    // flyout in it. Boxes and not ink here, because hovering is a box question.
    function checkOneHoverTarget(speaker, readout, stack, root, where) {
        var s = boxOf(speaker, root), r = boxOf(readout, root), t = boxOf(stack, root)
        verify(r.y <= s.y + s.h + 0.5,
               where + ": a " + (r.y - (s.y + s.h))
               + "px strip opened between the speaker and the readout that "
               + "belongs to neither of them")
        verify(s.y <= t.y + 0.5 && r.y + r.h >= t.y + t.h - 0.5,
               where + ": the speaker starts at " + s.y + " and the readout ends "
               + "at " + (r.y + r.h) + " in a stack spanning " + t.y + "-"
               + (t.y + t.h) + ", so part of the stack is hovered by neither")
    }

    function volumeInkIn(host, stack, speaker, readout, picker, where) {
        settle(host.contentItem)
        var img = windowInk(host)
        // One device pixel per logical one, which is what the suite's offscreen
        // platform gives: every figure below is read out of the grab and
        // compared against geometry that is in logical pixels, so a scaled
        // window would quietly double one side of that.
        compare(img.width, Math.round(host.width),
                where + ": the grab is " + img.width + " pixels across a "
                + host.width + "px window, so the ink and the geometry below are "
                + "not in the same units")
        checkOneHoverTarget(speaker, readout, stack, host.contentItem, where)
        return {
            inner: speakerToReadoutInk(img, stack, host.contentItem, where),
            outer: stackToPickerInk(img, stack, picker, host.contentItem, where)
        }
    }

    function test_the_readout_sits_as_close_to_the_speaker_in_both_places() {
        var barHost = showHost(playerBarHost, 1280, 200)
        var bar = barHost.bar
        var inBar = volumeInkIn(barHost, bar.volumeStack, bar.volumeButton,
                                bar.volumePercentText, bar.outputButton, "the bar")

        var pageHost = showHost(nowPlayingHost, 1280, 900)
        var page = pageHost.page
        var cluster = liveCluster(page)
        var mute   = findByName(cluster, "nowPlayingMuteButton")
        var pct    = findByName(cluster, "nowPlayingVolumePercent")
        var picker = findByName(cluster, "nowPlayingOutputButton")
        verify(mute && pct && picker,
               "the page's live cluster is missing one of its three controls")
        var inPage = volumeInkIn(pageHost, cluster.stack, mute, pct, picker,
                                 "Now Playing")

        // The ask, in the only terms it was made in. One pixel of slack and not
        // more: these are two renderings of the same glyph over the same digits
        // in the same font, so anything they differ by is a difference the user
        // can see.
        verify(Math.abs(inBar.inner - inPage.inner) <= 1,
               "the speaker is " + inBar.inner + "px above the number in the bar "
               + "and " + inPage.inner + "px above it in Now Playing. Both files "
               + "pay the gap as the readout's topPadding and both hold the same "
               + "number, so this is not a constant that got out of step - it is "
               + "the 7px of empty box under the bar's IconButton glyph")

        // And the pair reads as one object: half again as much air to the picker
        // as there is inside the pair, in both places. At the 19px inside against
        // 25px out the bar had, that is the complaint; it is 12 against 25 now.
        verify(inBar.inner * 1.5 <= inBar.outer,
               "the bar puts " + inBar.inner + "px between the speaker and the "
               + "number and only " + inBar.outer + "px between the pair and the "
               + "output picker, so the three read as three separate controls")
        verify(inPage.inner * 1.5 <= inPage.outer,
               "Now Playing puts " + inPage.inner + "px between the speaker and "
               + "the number and only " + inPage.outer + "px between the pair and "
               + "the output picker")

        // Not nothing, either: the two are a glyph and its caption, not one
        // smudge. Anything that collapsed the gap outright would satisfy both
        // of the cases above.
        verify(inBar.inner >= 4 && inPage.inner >= 4,
               "the speaker and the number are " + inBar.inner + "px apart in the "
               + "bar and " + inPage.inner + "px apart in Now Playing, which is "
               + "close enough to be touching")
    }
}
