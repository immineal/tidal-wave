import QtQuick
import TidalWave

// The one on/off switch; Qt Quick Controls' Switch brings a style of its own.
// With `rainbow` set, a checked track is a glass rainbow that flows in when
// it is switched on and drifts gently while it is on screen.
Item {
    id: tg
    property bool checked: false
    property bool rainbow: false
    // How the rainbow comes in: 0 a glass bead rides the front, 1 it pours in
    // with a caustic edge, 2 it opens out of the knob. The rest look is the same.
    property int rainbowFlip: 0
    // What a screen reader calls the switch: the title beside it.
    property string label: ""
    // A row that takes the keyboard for the switch lights its ring here.
    property bool showFocus: activeFocus
    signal toggled()

    implicitWidth: 38
    implicitHeight: 22
    activeFocusOnTab: true
    Keys.onReturnPressed: tg.toggled()
    Keys.onSpacePressed:  tg.toggled()
    Accessible.role: Accessible.CheckBox
    Accessible.name: tg.label
    Accessible.checkable: true
    Accessible.checked: tg.checked
    Accessible.onPressAction: tg.toggled()
    Accessible.onToggleAction: tg.toggled()

    readonly property bool showingRainbow: rainbow && checked
    // 0 off, 1 on; the flip runs it, the shader and the fallback read it.
    property real reveal: showingRainbow ? 1 : 0
    Behavior on reveal {
        enabled: tg.rainbow
        NumberAnimation {
            duration: Theme.dur(Theme.motionMedium + Theme.motionFast)
            easing.type: Easing.OutQuad
        }
    }

    // The software renderer draws no ShaderEffect; there the picture fades.
    readonly property bool glass: rainbow
        && GraphicsInfo.api !== GraphicsInfo.Software
        && GraphicsInfo.api !== GraphicsInfo.Unknown
        && rainbowArt.item !== null && rainbowArt.item.glassReady

    // Idle motion only where someone can see it: not behind a closed popup,
    // a hidden or minimised window, or scrolled out of its Flickable.
    property Item _flick: null
    Component.onCompleted: {
        if (!rainbow) return
        for (var p = parent; p; p = p.parent)
            if (p.flickableDirection !== undefined) { _flick = p; break }
    }
    readonly property bool _inView: {
        if (!_flick) return true
        var h = _flick.height + 0 * _flick.contentY   // re-read on scroll
        var y = tg.mapToItem(_flick, 0, 0).y
        return y + tg.height > 0 && y < h
    }
    readonly property bool onScreen: visible && _inView
        && Window.visibility !== Window.Hidden
        && Window.visibility !== Window.Minimized
    readonly property bool idleMotion: glass && showingRainbow && onScreen
        && !Theme.reduceMotion

    // The idle strength eases in and out; its clock keeps running until the
    // strength is gone, so nothing jumps when the switch goes off. Out of
    // sight it drops at once and the clock stops with it.
    property real idle: idleMotion ? 1 : 0
    Behavior on idle {
        enabled: tg.onScreen
        NumberAnimation { duration: Theme.dur(Theme.motionSlow) }
    }
    // The drift is slow, so a 30 Hz clock moves it smoothly and asks for
    // half or less of the frames a display-rate animation would.
    property real phase: 0
    readonly property int idleStepMs: 33
    readonly property bool clockRunning: idleClock.running
    Timer {
        id: idleClock
        interval: tg.idleStepMs
        repeat: true
        running: tg.idleMotion || tg.idle > 0
        property double last: 0
        onRunningChanged: last = Date.now()
        onTriggered: {
            var now = Date.now()
            // Seconds, wrapped at the shader's PERIOD.
            tg.phase = (tg.phase + Math.min(now - last, 100) / 1000) % 12
            last = now
        }
    }

    Rectangle {
        id: track
        anchors.fill: parent
        radius: Theme.radiusChip
        // The rainbow paints its own soft edge, so the off track's fill and
        // border fade out as it comes in.
        color: !tg.rainbow ? (tg.checked ? Theme.accent : Theme.surface)
             : tg.reveal <= 0 ? Theme.surface
             : tg.reveal >= 1 ? "transparent"
             : Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 1 - tg.reveal)
        border.width: tg.rainbow && tg.reveal >= 1 ? 0 : 1
        border.color: !tg.rainbow ? (tg.checked ? Theme.accent : Theme.border)
                    : tg.reveal <= 0 ? Theme.border
                    : Qt.rgba(Theme.border.r, Theme.border.g, Theme.border.b,
                              Theme.border.a * (1 - tg.reveal))

        // tools/make-rainbow.py draws the picture at 1x, 2x and 3x. It reaches
        // 4px past the track for the glow, over the off track, under the knob.
        Loader {
            id: rainbowArt
            active: tg.rainbow
            visible: tg.reveal > 0
            x: -4; y: -4
            width: tg.width + 8; height: tg.height + 8
            sourceComponent: Item {
                readonly property bool glassReady: lens.status === ShaderEffect.Compiled
                Image {
                    id: picture
                    objectName: "toggleRainbow"
                    anchors.fill: parent
                    // The glass samples it even while it is hidden.
                    visible: tg.reveal > 0 && !tg.glass
                    opacity: tg.reveal
                    source: "../../assets/toggle-rainbow.png"
                    smooth: true
                }
                ShaderEffect {
                    id: lens
                    objectName: "toggleRainbowGlass"
                    anchors.fill: parent
                    visible: tg.glass && tg.reveal > 0
                    property var source: picture
                    property real reveal: tg.reveal
                    property real idle: tg.idle
                    property real phase: tg.phase
                    property real variant: tg.rainbowFlip
                    property real knob: knobDot.x + knobDot.width / 2
                    property size box: Qt.size(width, height)
                    // Baked by tools/make-rainbow-shader.sh for Qt 6.4 and later.
                    fragmentShader: "../../assets/toggle-rainbow.frag.qsb"
                }
            }
        }

        Rectangle {
            id: knobDot
            objectName: "toggleKnob"
            width: parent.height - 6
            height: width
            radius: Theme.radiusChip
            y: 3
            x: tg.checked ? parent.width - width - 3 : 3
            // On the rainbow it turns white as the colour comes in.
            color: !tg.rainbow ? (tg.checked ? Theme.accentInk : Theme.textSec)
                 : tg.reveal <= 0 ? Theme.textSec
                 : tg.reveal >= 1 ? Theme.accentInk
                 : Qt.tint(Theme.textSec, Qt.rgba(Theme.accentInk.r, Theme.accentInk.g,
                                                  Theme.accentInk.b, tg.reveal))
            Behavior on x {
                NumberAnimation { duration: Theme.dur(Theme.motionFast); easing.type: Easing.OutCubic }
            }
        }

        // Focus draws its ring over the rainbow's glow too.
        Rectangle {
            anchors.fill: parent
            radius: Theme.radiusChip
            visible: tg.showFocus
            color: "transparent"
            border.width: 2
            border.color: Theme.accent
        }
    }
    HoverHandler { cursorShape: Qt.PointingHandCursor }
    TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: tg.toggled() }
}
