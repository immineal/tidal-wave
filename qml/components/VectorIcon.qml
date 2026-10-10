import QtQuick
import QtQuick.Shapes
import QtQuick.Window
import TidalWave

Item {
    id: root
    property string name: ""
    property color color: Theme.textPrimary
    property real strokeWidth: 1.8

    implicitWidth: 24
    implicitHeight: 24

    // Glyphs drawn as solid shapes. An extra stroke on these at small sizes
    // bridges adjacent bars/edges into an unrecognizable blob (e.g. the pause
    // bars merging into a single square).
    readonly property var _filled: ["play", "pause", "more-vertical", "more", "heart-filled", "pin-filled"]
    // Dot-grid glyphs are zero-length segments with round caps: the stroke
    // width *is* the dot diameter, so they need a heavier one to read.
    readonly property var _fat: ["grip"]

    readonly property bool isFilled: _filled.indexOf(name) !== -1

    // "track" is not drawn as a path; see trackStrip below for why.
    readonly property bool isSnappedBars: name === "track"

    // The Shape is built anew each time the icon enters a scene. Qt 6.4's
    // software renderer crashes on one that left a scene and came back, as
    // every glyph in a menu does when the menu reopens.
    Loader {
        id: shapeItem
        visible: !root.isSnappedBars
        width: 24
        height: 24
        anchors.centerIn: parent
        active: root.Window.window !== null

        transform: Scale {
            origin.x: 12
            origin.y: 12
            xScale: (root.width * 0.85) / 24
            yScale: (root.height * 0.85) / 24
        }

        sourceComponent: Shape {
            antialiasing: true
            smooth: true

            ShapePath {
                strokeColor: root.color
                strokeWidth: root.isFilled
                             ? 0
                             : (root._fat.indexOf(root.name) !== -1 ? root.strokeWidth * 1.45 : root.strokeWidth)
                fillColor: root.isFilled ? root.color : "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: root._pathFor(root.name) }
            }

            // Solid detail drawn on top of a stroked glyph.
            ShapePath {
                strokeWidth: 0
                fillColor: root.color
                PathSvg { path: root._accentFor(root.name) }
            }

            // Stroked detail drawn on top of a filled glyph.
            ShapePath {
                strokeColor: root.color
                strokeWidth: root._overlayFor(root.name) === "" ? 0 : root.strokeWidth
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: root._overlayFor(root.name) }
            }
        }
    }

    // The seven-bar "track" strip, snapped to whole device pixels. As a stroked
    // path the bars come out 1, 2 or 3 device px wide depending on where their
    // edges fall. Here pitch and bar are whole device px, so all bars match.
    Item {
        id: trackStrip
        visible: root.isSnappedBars
        height: root.height

        readonly property real dpr: Math.max(1, Screen.devicePixelRatio)
        readonly property real unit: (root.width * 0.85) / 24
        readonly property int pitchDev: Math.max(2, Math.round(3.2 * trackStrip.unit * trackStrip.dpr))
        readonly property int barDev:   Math.ceil(trackStrip.pitchDev / 2)
        // Six whole pitches plus the last bar: the ink, not the trailing gap.
        readonly property int stripDev: 6 * trackStrip.pitchDev + trackStrip.barDev
        width: trackStrip.stripDev / trackStrip.dpr

        // Positioned in whole device px, not by anchors.centerIn, which centres
        // on a fractional offset and lets each edge snap independently. Clipped
        // where seven bars do not fit the box (12px at DPR 1).
        clip: trackStrip.stripDev > Math.round(root.width * trackStrip.dpr)
        x: Math.round((root.width * trackStrip.dpr - trackStrip.stripDev) / 2)
           / trackStrip.dpr
        y: 0

        readonly property int boxDev: Math.round(root.height * trackStrip.dpr)

        // Every bar's height gets the same parity as the box, so (box - height)
        // is even and the bar sits on one exact centre line.
        function barHeightDev(i) {
            var h = Math.round(2 * trackStrip.halfUnits[i] * trackStrip.unit * trackStrip.dpr)
            if (((trackStrip.boxDev - h) % 2 + 2) % 2 !== 0) h += 1
            return Math.max(1, h)
        }

        // Half-heights in grid units. Every bar is centred on the middle line,
        // which tells this apart from the now-playing bars on their baseline.
        readonly property var halfUnits: [3, 6.5, 4, 9, 5, 7.5, 2.5]

        Repeater {
            model: 7
            Rectangle {
                required property int index
                objectName: "trackBar"
                color: root.color
                antialiasing: false
                x: index * trackStrip.pitchDev / trackStrip.dpr
                width: trackStrip.barDev / trackStrip.dpr
                readonly property int hDev: trackStrip.barHeightDev(index)
                height: hDev / trackStrip.dpr
                y: ((trackStrip.boxDev - hDev) / 2) / trackStrip.dpr
            }
        }
    }

    function _pathFor(n) {
        switch (n) {
        case "home":
            return "M 3 9 L 12 2 L 21 9 V 20 A 2 2 0 0 1 19 22 H 5 A 2 2 0 0 1 3 20 Z M 9 22 V 12 H 15 V 22"
        case "search":
            return "M 11 19 A 8 8 0 1 0 11 3 A 8 8 0 0 0 11 19 Z M 21 21 L 16.65 16.65"
        case "heart":
        case "heart-filled":
            return "M 19 14 C 21 11 22 8 19 5 C 16 2 13 5 12 6 C 11 5 8 2 5 5 C 2 8 3 11 5 14 L 12 21 Z"
        // A waveform strip: seven bars, each centred on y=12. That symmetry is
        // what tells it from the now-playing bars, which stand on a baseline.
        // Pitch 3.2 is a 1px bar with a 1px gap at the 15-16px it is used at.
        case "track":
            return "M 2.4 9 V 15 M 5.6 5.5 V 18.5 M 8.8 8 V 16 M 12 3 V 21"
                 + " M 15.2 7 V 17 M 18.4 4.5 V 19.5 M 21.6 9.5 V 14.5"
        case "artist":
            return "M 20 21 V 19 A 4 4 0 0 0 16 15 H 8 A 4 4 0 0 0 4 19 V 21 M 12 11 A 4 4 0 1 0 12 3 A 4 4 0 0 0 12 11 Z"
        case "settings":
            return "M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z M 12 15 A 3 3 0 1 1 12 9 A 3 3 0 0 1 12 15 Z"
        case "volume-mute":
            return "M 11 5 L 6 9 H 2 V 15 H 6 L 11 19 V 5 Z M 22 9 L 16 15 M 16 9 L 22 15"
        case "volume-low":
            return "M 11 5 L 6 9 H 2 V 15 H 6 L 11 19 V 5 Z M 15.18 8.82 A 4.5 4.5 0 0 1 15.18 15.18"
        case "volume-mid":
            return "M 11 5 L 6 9 H 2 V 15 H 6 L 11 19 V 5 Z M 15.18 8.82 A 4.5 4.5 0 0 1 15.18 15.18 M 17.3 6.7 A 7.5 7.5 0 0 1 17.3 17.3"
        case "volume-high":
            return "M 11 5 L 6 9 H 2 V 15 H 6 L 11 19 V 5 Z M 15.18 8.82 A 4.5 4.5 0 0 1 15.18 15.18 M 17.3 6.7 A 7.5 7.5 0 0 1 17.3 17.3 M 19.42 4.58 A 10.5 10.5 0 0 1 19.42 19.42"
        case "play":
            return "M 6 4 L 19 12 L 6 20 Z"
        case "pause":
            return "M 6 4 H 10 V 20 H 6 Z M 14 4 H 18 V 20 H 14 Z"
        case "shuffle":
            return "M 16 3 H 21 V 8 M 4 20 L 21 3 M 21 16 V 21 H 16 M 15 15 L 21 21 M 4 4 L 9 9"
        case "previous":
            return "M 19 20 L 9 12 L 19 4 Z M 5 19 V 5"
        case "next":
            return "M 5 4 L 15 12 L 5 20 Z M 19 5 V 19"
        case "repeat":
            return "M 17 2 L 21 6 L 17 10 M 3 11 V 10 A 4 4 0 0 1 7 6 H 21 M 7 22 L 3 18 L 7 14 M 21 13 V 14 A 4 4 0 0 1 17 18 H 3"
        case "repeat-one":
            return "M 17 2 L 21 6 L 17 10 M 3 11 V 10 A 4 4 0 0 1 7 6 H 21 M 7 22 L 3 18 L 7 14 M 21 13 V 14 A 4 4 0 0 1 17 18 H 3 M 11 11 L 12 10 V 14 M 10 14 H 14"
        case "clock":
            return "M 12 2 A 10 10 0 1 0 12 22 A 10 10 0 1 0 12 2 M 12 6 V 12 L 16 14"
        // Three bare lines read as a hamburger menu, so _accentFor adds a mark.
        case "queue":
            return "M 3 6 H 21 M 3 12 H 21 M 3 18 H 13"
        case "playlist":
            return "M 3 6 H 16 M 3 12 H 12 M 3 18 H 11 M 21 18 V 6 M 21 18 A 2.5 2.5 0 1 0 16 18 A 2.5 2.5 0 1 0 21 18"
        case "album":
            return "M 12 2 A 10 10 0 1 0 12 22 A 10 10 0 1 0 12 2 M 12 9.5 A 2.5 2.5 0 1 0 12 14.5 A 2.5 2.5 0 1 0 12 9.5"
        case "mix":
            return "M 8.6 8.6 A 4.8 4.8 0 0 0 8.6 15.4 M 15.4 8.6 A 4.8 4.8 0 0 1 15.4 15.4"
                 + " M 5.2 5.2 A 9.6 9.6 0 0 0 5.2 18.8 M 18.8 5.2 A 9.6 9.6 0 0 1 18.8 18.8"
        case "library":
            return "M 4 4 V 20 M 8.5 8 V 20 M 13 6 V 20 M 17 7.5 L 20.5 20"
        case "waves":
            return "M 2 6 C 3.67 4 5.33 4 7 6 C 8.67 8 10.33 8 12 6 C 13.67 4 15.33 4 17 6 C 18.67 8 20.33 8 22 6"
                 + " M 2 12 C 3.67 10 5.33 10 7 12 C 8.67 14 10.33 14 12 12 C 13.67 10 15.33 10 17 12 C 18.67 14 20.33 14 22 12"
                 + " M 2 18 C 3.67 16 5.33 16 7 18 C 8.67 20 10.33 20 12 18 C 13.67 16 15.33 16 17 18 C 18.67 20 20.33 20 22 18"
        case "pin":
            return "M 8 3 H 16 L 14 9 L 17 13 H 7 L 10 9 L 8 3 Z M 12 13 V 21"
        case "pin-filled":
            return "M 8 3 H 16 L 14 9 L 17 13 H 7 L 10 9 Z"
        case "globe":
            return "M 12 2 A 10 10 0 1 0 12 22 A 10 10 0 1 0 12 2 M 2.5 9 H 21.5 M 2.5 15 H 21.5 M 12 2 C 15 5.5 15 18.5 12 22 M 12 2 C 9 5.5 9 18.5 12 22"
        case "speaker":
            return "M 6 2 H 18 A 1.5 1.5 0 0 1 19.5 3.5 V 20.5 A 1.5 1.5 0 0 1 18 22 H 6 A 1.5 1.5 0 0 1 4.5 20.5 V 3.5 A 1.5 1.5 0 0 1 6 2 Z M 12 17.5 A 3.5 3.5 0 1 0 12 10.5 A 3.5 3.5 0 0 0 12 17.5 Z M 12 6 H 12.01"
        case "grip":
            return "M 9 6 H 9.01 M 9 12 H 9.01 M 9 18 H 9.01 M 15 6 H 15.01 M 15 12 H 15.01 M 15 18 H 15.01"
        case "panel-left":
            return "M 3.5 4 H 20.5 A 1.5 1.5 0 0 1 22 5.5 V 18.5 A 1.5 1.5 0 0 1 20.5 20 H 3.5 A 1.5 1.5 0 0 1 2 18.5 V 5.5 A 1.5 1.5 0 0 1 3.5 4 Z M 9 4 V 20"
        case "chevron-left":
            return "M 15 5 L 8 12 L 15 19"
        case "chevron-right":
            return "M 9 5 L 16 12 L 9 19"
        // The same chevron mirrored, not rotated at runtime: a transform on
        // the Shape rounds the stroke onto a different pixel grid.
        case "chevron-up":
            return "M 5 15 L 12 8 L 19 15"
        case "chevron-down":
            return "M 5 9 L 12 16 L 19 9"
        // Four corner brackets, arms pointing out of the frame; the exit state
        // turns the arms inwards. Corner radius 2, as on home and settings.
        case "fullscreen":
            return "M 9 3 H 5 A 2 2 0 0 0 3 5 V 9"
                 + " M 15 3 H 19 A 2 2 0 0 1 21 5 V 9"
                 + " M 15 21 H 19 A 2 2 0 0 0 21 19 V 15"
                 + " M 9 21 H 5 A 2 2 0 0 1 3 19 V 15"
        case "fullscreen-exit":
            return "M 9 3 V 7 A 2 2 0 0 1 7 9 H 3"
                 + " M 15 3 V 7 A 2 2 0 0 0 17 9 H 21"
                 + " M 21 15 H 17 A 2 2 0 0 0 15 17 V 21"
                 + " M 3 15 H 7 A 2 2 0 0 1 9 17 V 21"
        case "plus":
            return "M 12 5 V 19 M 5 12 H 19"
        case "info":
            return "M 12 2 A 10 10 0 1 0 12 22 A 10 10 0 1 0 12 2 M 12 16.5 V 11 M 12 7.8 H 12.01"
        case "more-vertical":
            return "M 12 14 A 2 2 0 1 1 12 10 A 2 2 0 0 1 12 14 Z M 12 7 A 2 2 0 1 1 12 3 A 2 2 0 0 1 12 7 Z M 12 21 A 2 2 0 1 1 12 17 A 2 2 0 0 1 12 21 Z"
        case "x":
            return "M 18 6 L 6 18 M 6 6 L 18 18"
        case "more":
            return "M 3.5 12 A 1.5 1.5 0 1 0 6.5 12 A 1.5 1.5 0 1 0 3.5 12 Z M 10.5 12 A 1.5 1.5 0 1 0 13.5 12 A 1.5 1.5 0 1 0 10.5 12 Z M 17.5 12 A 1.5 1.5 0 1 0 20.5 12 A 1.5 1.5 0 1 0 17.5 12 Z"
        case "edit":
            return "M 11 4 H 4 A 2 2 0 0 0 2 6 V 20 A 2 2 0 0 0 4 22 H 18 A 2 2 0 0 0 20 20 V 13 M 18.5 2.5 A 2.121 2.121 0 1 1 21.5 5.5 L 12 15 L 8 16 L 9 12 L 18.5 2.5 Z"
        case "download":
            return "M 12 3 V 15 M 7 10 L 12 15 L 17 10 M 4 20 H 20"
        case "check":
            return "M 5 12 L 10 17 L 19 7"
        // A sheet over a sheet, for "Copy link". A chain link cannot be drawn
        // at this size: its two half-rings close into one flat oval.
        case "copy":
            return "M 10 8.5 H 19.5 A 2 2 0 0 1 21.5 10.5 V 20 A 2 2 0 0 1 19.5 22 H 10 A 2 2 0 0 1 8 20 V 10.5 A 2 2 0 0 1 10 8.5 Z"
                 + " M 5 15.5 A 2 2 0 0 1 3 13.5 V 4 A 2 2 0 0 1 5 2 H 14.5 A 2 2 0 0 1 16.5 4 V 6"
        // A screen with its bottom left corner opened up and the signal rising
        // out of it: dot, inner arc, outer arc, all centred on (2.5, 19.5). The
        // three gaps are even, which is what stays legible at 16px.
        case "cast":
            return "M 2.5 7.5 V 5 A 1.5 1.5 0 0 1 4 3.5 H 20 A 1.5 1.5 0 0 1 21.5 5 V 18 A 1.5 1.5 0 0 1 20 19.5 H 14.5"
                 + " M 2.5 14.7 A 4.8 4.8 0 0 1 7.3 19.5"
                 + " M 2.5 11 A 8.5 8.5 0 0 1 11 19.5"
        // A bin: lid, handle, tapered body, two ribs. The ribs stop it reading
        // as a cup at 16px.
        case "trash":
            return "M 4 6.5 H 20"
                 + " M 9.5 6.5 V 4.5 A 1.5 1.5 0 0 1 11 3 H 13 A 1.5 1.5 0 0 1 14.5 4.5 V 6.5"
                 + " M 6.5 6.5 V 19.5 A 2 2 0 0 0 8.5 21.5 H 15.5 A 2 2 0 0 0 17.5 19.5 V 6.5"
                 + " M 10 10.5 V 17.5 M 14 10.5 V 17.5"
        }
        return ""
    }

    function _accentFor(n) {
        switch (n) {
        case "queue":  return "M 16.5 14.6 L 22 18 L 16.5 21.4 Z"
        case "mix":    return "M 13.7 12 A 1.7 1.7 0 1 0 10.3 12 A 1.7 1.7 0 1 0 13.7 12 Z"
        case "cast":   return "M 3.7 19.5 A 1.2 1.2 0 1 0 1.3 19.5 A 1.2 1.2 0 1 0 3.7 19.5 Z"
        }
        return ""
    }

    function _overlayFor(n) {
        if (n === "pin-filled") return "M 12 13 V 21"
        return ""
    }

    // ── "this is playing" ────────────────────────────────────────────────
    // Five bars standing on a baseline, where the "track" strip is seven bars
    // centred on a line, so the two differ by structure. Under reduced motion
    // the sequence runs once and parks each bar on its `rest` height.
    component PlayingIndicator : Item {
        id: ind

        // Whether the bars move. The mark is drawn either way: a paused row
        // is still the row you are on, so pausing dims it rather than
        // deleting it.
        property bool animate: true
        property color color: Theme.accent

        implicitWidth: 16
        implicitHeight: 14

        // Derived from the width, so the bars never reach past their own box.
        // Five bars and four gaps of three quarters of a bar are 8 bar widths.
        readonly property real barWidth: width / 8
        readonly property real gap: barWidth * 0.75

        // ── live levels ──────────────────────────────────────────────────
        // True only while the preference is on and audio is arriving. A paused
        // track, a gap between tracks and a build before Qt 6.8 fall back to
        // the animation. Reduced motion wins over the spectrum.
        readonly property bool useSpectrum: Spectrum.active && !Theme.reduceMotion

        // A band at zero still draws something: five bars collapsed to nothing
        // in a quiet passage would read as stopped.
        readonly property real minFrac: 0.12

        // Short-circuits before touching Spectrum.levels, so while the feature
        // is off no binding in here depends on it.
        function levelAt(i) {
            if (!useSpectrum) return 0
            var v = Spectrum.levels[i]
            return v === undefined ? 0 : v
        }

        opacity: animate ? 1 : 0.45
        Behavior on opacity { NumberAnimation { duration: Theme.dur(120) } }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            height: ind.height
            spacing: ind.gap

            Repeater {
                // Heights as fractions of the box, so the figure is the same
                // at any size. The resting row is uneven on purpose: five
                // bars of one height read as a bar chart.
                model: [
                    { rest: 0.45, peak: 1.00, trough: 0.20, ms: 420 },
                    { rest: 0.80, peak: 0.55, trough: 1.00, ms: 320 },
                    { rest: 0.30, peak: 0.90, trough: 0.15, ms: 500 },
                    { rest: 0.65, peak: 0.35, trough: 0.95, ms: 360 },
                    { rest: 0.50, peak: 0.85, trough: 0.25, ms: 460 }
                ]

                delegate: Rectangle {
                    id: bar
                    required property var modelData
                    // Which band this bar shows, bass on the left.
                    required property int index

                    readonly property real restH:   ind.height * modelData.rest
                    readonly property real peakH:   ind.height * modelData.peak
                    readonly property real troughH: ind.height * modelData.trough

                    // The live height, when there is one. Reads through
                    // ind.levelAt(), which is what makes this a binding on
                    // Spectrum.levels only while the feature is on.
                    readonly property real specH:
                        ind.height * (ind.minFrac
                                      + (1 - ind.minFrac) * ind.levelAt(bar.index))

                    // A Row places its children only horizontally, so the
                    // floor is set here. Not an anchor: `parent` is null while
                    // a Repeater builds its delegate, and that warns.
                    y: ind.height - bar.height
                    width: ind.barWidth
                    height: bar.restH
                    radius: width / 2
                    color: ind.color

                    // The animation below writes `height` directly, which
                    // drops the binding above; this puts the resting height
                    // back if the box is resized while the bars are still.
                    onRestHChanged: if (!seq.running && !ind.useSpectrum) bar.height = bar.restH

                    // Spectrum mode assigns the height, like the animation. A
                    // conditional binding on `height` would be dropped by the
                    // animation's first write and never come back.
                    onSpecHChanged: if (ind.useSpectrum) bar.height = bar.specH

                    // Leaving the live path: the animation restarts by itself
                    // if it is allowed to, but a paused row has no animation
                    // to put the bar back, so it is put back here.
                    readonly property bool live: ind.useSpectrum
                    onLiveChanged: {
                        if (bar.live) bar.height = bar.specH
                        else if (!seq.running) bar.height = bar.restH
                    }

                    // Enabled only on the live path. The analyser publishes at
                    // 25 Hz and the screen draws at 60; without this the bars
                    // step where they should move.
                    Behavior on height {
                        enabled: ind.useSpectrum
                        NumberAnimation {
                            duration: Theme.dur(70)
                            easing.type: Easing.OutQuad
                        }
                    }

                    SequentialAnimation {
                        id: seq
                        running: ind.animate && ind.visible && !ind.useSpectrum
                        loops: Theme.reduceMotion ? 1 : Animation.Infinite
                        NumberAnimation {
                            target: bar; property: "height"; to: bar.peakH
                            duration: Theme.dur(bar.modelData.ms)
                            easing.type: Easing.InOutSine
                        }
                        NumberAnimation {
                            target: bar; property: "height"; to: bar.troughH
                            duration: Theme.dur(bar.modelData.ms)
                            easing.type: Easing.InOutSine
                        }
                        NumberAnimation {
                            target: bar; property: "height"; to: bar.restH
                            duration: Theme.dur(Math.round(bar.modelData.ms * 0.6))
                            easing.type: Easing.InOutSine
                        }
                        onStopped: if (!ind.useSpectrum) bar.height = bar.restH
                    }
                }
            }
        }
    }
}
