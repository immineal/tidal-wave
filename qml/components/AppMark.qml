import QtQuick
import QtQuick.Shapes
import QtQuick.Window
import TidalWave

// The app mark: three parallel bands on a rounded accent tile, the same
// drawing as assets/icon.svg, so the window icon, the tray icon and the two
// in-app marks cannot drift apart. Nothing here needs a font.
Item {
    id: root

    // Fixed brand colours, matching assets/icon.svg exactly. Deliberately not
    // theme tokens: see the tile colour below.
    readonly property color brandTile: "#0079A8"
    readonly property color brandInk:  "#FFFFFF"

    implicitWidth: 64
    implicitHeight: 64

    // The mark is square. Taking the smaller side rather than stretching
    // keeps the bands at their drawn angle in a box that is not.
    readonly property real _side: Math.min(width, height)

    // ── geometry, in the 64x64 design space of assets/icon.svg ───────────
    // Wave amplitude. With 7W + 2A = 64, the band thickness W, the two gaps
    // between bands and the top and bottom margins are all equal.
    readonly property real _amp: 5
    readonly property real _thick: (64 - 2 * root._amp) / 7
    // Half period. A sloping band is only cos(slope) as thick as at its crests,
    // so a shorter period visibly thins the ink where it crosses the middle.
    readonly property real _half: 32
    readonly property var _centres: [1.5 * root._thick + root._amp,
                                     32,
                                     64 - (1.5 * root._thick + root._amp)]

    Rectangle {
        id: tile
        objectName: "appMarkTile"
        width: root._side
        height: root._side
        anchors.centerIn: parent
        // The fixed brand blue. The window, tray and launcher icons show
        // the same mark and cannot follow the in-app palette.
        color: root.brandTile
        // radiusMark is the radius at the 64-unit design size. Scaling it with
        // the tile means a 26px mark and a 64px one are the same drawing,
        // rather than a sharp tile small and a near-circle large.
        radius: Theme.radiusMark * root._side / 64

        // The Shape is built anew each time the mark enters a scene. Qt 6.4's
        // software renderer crashes on one that left a scene and came back.
        Loader {
            width: 64
            height: 64
            active: root.Window.window !== null

            // Drawn at the design size and scaled as a whole, the way
            // VectorIcon does it, so the numbers above are the only ones.
            transform: Scale {
                xScale: tile.width / 64
                yScale: tile.height / 64
            }

            sourceComponent: Shape {
                id: bands
                objectName: "appMarkBands"
                antialiasing: true
                smooth: true

                // The curve renderer (Qt 6.6+) smooths the edge without
                // multisampling. Assigned, not declared: the property does
                // not exist on Qt 6.4.
                Component.onCompleted: {
                    if ("preferredRendererType" in bands)
                        bands.preferredRendererType = Shape.CurveRenderer
                }

                // Filled, not stroked: a stroked wave shows a rounded line end
                // where it meets the tile edge. Each band spans the full 0..64, so
                // its flat ends sit exactly on that edge and never show.
                ShapePath {
                    strokeWidth: 0
                    fillColor: root.brandInk
                    PathSvg { path: root._band(root._centres[0]) }
                }
                ShapePath {
                    strokeWidth: 0
                    fillColor: root.brandInk
                    PathSvg { path: root._band(root._centres[1]) }
                }
                ShapePath {
                    strokeWidth: 0
                    fillColor: root.brandInk
                    PathSvg { path: root._band(root._centres[2]) }
                }
            }
        }
    }

    // One band as a closed path: the top edge left to right, then the bottom
    // edge right to left, both the same wave offset by half the thickness.
    // Each half period is one cubic with both handles a third of the way in.
    function _band(cy) {
        var spans = 64 / root._half

        function edge(off, reversed) {
            var out = []
            for (var k = 0; k < spans; ++k) {
                var i = reversed ? spans - 1 - k : k
                var xa = (reversed ? i + 1 : i) * root._half
                var xb = (reversed ? i : i + 1) * root._half
                // Alternate crest and trough, up first, so consecutive spans
                // join smoothly at the zero crossings. y grows downward, so
                // up is the negative amplitude.
                var yc = cy + (i % 2 === 0 ? -root._amp : root._amp) + off
                var t = (xb - xa) / 3
                out.push("C " + (xa + t) + " " + yc
                       + " " + (xb - t) + " " + yc
                       + " " + xb + " " + (cy + off))
            }
            return out.join(" ")
        }

        return "M 0 " + (cy - root._thick / 2) + " " + edge(-root._thick / 2, false)
             + " L 64 " + (cy + root._thick / 2) + " " + edge(root._thick / 2, true)
             + " Z"
    }
}
