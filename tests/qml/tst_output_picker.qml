// One picker for "where is this playing", and the volume slider that comes
// back on hover once the bar is too narrow to carry one.
//
// The two live next to each other in the player bar's right-hand group and
// both draw upwards out of an 82px bar, so most of this file is about them
// not getting in each other's way.
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

    function hover(host, item) {
        var p = item.mapToItem(host.contentItem, item.width / 2, item.height / 2)
        mouseMove(host.contentItem, p.x, p.y)
        wait(1)
    }

    // Above the breakpoint the slider is in the bar and there is nothing to
    // reveal, so the flyout must stay out of the way.
    function test_a_wide_bar_keeps_its_slider_and_shows_no_flyout() {
        var host = showHost(playerBarHost, 1280, 200)
        var bar = host.bar
        verify(!bar.compactRight)
        verify(bar.volumeSlider.visible, "the wide bar lost its inline slider")

        hover(host, bar.volumeButton)
        wait(60)
        verify(!bar.hoverVolumePopup.visible,
               "a bar that already shows a slider popped a second one")
    }

    // Below it the inline slider is gone and muting is all that is left, so
    // pointing at the speaker has to bring a slider back.
    function test_hovering_the_speaker_below_the_breakpoint_reveals_a_slider() {
        var host = showHost(playerBarHost, 640, 200)
        var bar = host.bar
        verify(bar.compactRight, "640 should be a compact bar")
        verify(!bar.volumeSlider.visible, "the narrow bar kept its inline slider")
        verify(!bar.hoverVolumePopup.visible, "the flyout is up before anyone pointed at it")

        hover(host, bar.volumeButton)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 2000,
                  "hovering the speaker revealed no slider")
        verify(bar.hoverVolumeSlider.visible, "the flyout is empty")
        // A Popup forces its content to the size it worked out from the
        // content's implicit size, so a slider with no implicit height comes
        // out as a nothing-tall strip with no hit area at all.
        verify(bar.hoverVolumeSlider.height >= 16 && bar.hoverVolumeSlider.width >= 60,
               "the revealed slider is " + bar.hoverVolumeSlider.width.toFixed(1) + "x"
               + bar.hoverVolumeSlider.height.toFixed(1) + ", too small to aim at")

        // And reachable with the pointer, not just by calling its signal.
        var mid = bar.hoverVolumeSlider.mapToItem(
            host.contentItem, bar.hoverVolumeSlider.width / 2,
            bar.hoverVolumeSlider.height / 2)
        verify(mid.y >= 0 && mid.y <= host.height,
               "the flyout opened off the top of the window")

        // And it is a working slider, not a picture of one.
        bar.hoverVolumeSlider.moved(0.25)
        compare(Math.round(player.volume * 100), 25,
               "the revealed slider does not set the volume")
        verify(!player.muted, "moving the slider should unmute")
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
}
