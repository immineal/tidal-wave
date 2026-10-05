import QtQuick
import QtQuick.Shapes
import TidalWave

// The app mark: three parallel bands on a rounded accent tile, the same
// drawing as assets/icon.svg, so the window icon, the tray icon and the two
// in-app marks cannot drift apart.
//
// It used to be the text glyph U+224B set in DejaVu Sans, which renders as a
// different shape -- or as a tofu box -- on any machine without that font.
// Nothing here needs a font.
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
    //
    // Wave amplitude. Solving 7W + 2A = 64 for the band thickness W then makes
    // the thickness, the two gaps between bands and the top and bottom margins
    // all exactly equal, so no part of the stack reads heavier than the rest.
    readonly property real _amp: 5
    readonly property real _thick: (64 - 2 * root._amp) / 7
    // Half period. A band that is sloping is only cos(slope) as thick as at
    // its crests; at the 16 this started as, the 46 degree slope made the ink
    // visibly thinner where it crossed the middle. At 32 the slope is 25
    // degrees, the variation is about 9% and it stops reading.
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
        // The brand blue, not Theme.accent: this is the same mark the window,
        // tray and launcher show, and those cannot follow the in-app palette.
        // A logo that changed colour with the theme would not read as the same
        // thing as the icon sitting next to it in the taskbar.
        color: root.brandTile
        // radiusMark is the radius at the 64-unit design size. Scaling it with
        // the tile means a 26px mark and a 64px one are the same drawing,
        // rather than a sharp tile small and a near-circle large.
        radius: Theme.radiusMark * root._side / 64

        Shape {
            id: bands
            objectName: "appMarkBands"
            width: 64
            height: 64
            antialiasing: true
            smooth: true

            // Retina found the limit of `antialiasing: true` on its own. The
            // geometry renderer flattens these curves into triangles and leaves
            // the smoothing to the window's multisampling, which the app asks
            // for 4 samples of - and 4 samples is 4 coverage levels, which on a
            // shallow curve at 2x reads as visible stair-stepping rather than as
            // a soft edge. The curve renderer Qt 6.6 added computes coverage
            // analytically in the fragment shader instead, so the edge is smooth
            // at any scale factor and it needs no multisampling and no layer.
            //
            // Set here and not on VectorIcon: a layer or a heavier renderer is
            // per-item cost, VectorIcon is drawn once per row in virtualised
            // lists that are hundreds of rows long, and the mark is large, few
            // and the worst offender. Deliberately NOT `layer.samples`, which is
            // the other way to fix this: that puts an FBO under every item it is
            // set on, and measured on the software backend it made this edge
            // *worse*, dropping it from 93 distinct coverage levels to 42,
            // because an MSAA resolve quantises what was an analytic edge.
            //
            // Assigned rather than declared, and guarded by the property's own
            // existence, because preferredRendererType arrived in Qt 6.6 and this
            // project still builds against the 6.4 on Debian bookworm, where
            // declaring it would be a "cannot assign to non-existent property"
            // at load - the same class of breakage as commit 033d735. The `in`
            // test is false there and short-circuits before Shape.CurveRenderer
            // is ever named, so 6.4 sees no warning and no change. The software
            // backend ignores the preference entirely; its output is unchanged
            // byte for byte, which is what keeps Prefs::softwareRendering the
            // same drawing as before.
            Component.onCompleted: {
                if ("preferredRendererType" in bands)
                    bands.preferredRendererType = Shape.CurveRenderer
            }
            // Drawn at the design size and scaled as a whole, the way
            // VectorIcon does it, so the numbers above are the only ones.
            transform: Scale {
                xScale: tile.width / 64
                yScale: tile.height / 64
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

    // One band as a closed path: the top edge left to right, then the bottom
    // edge right to left. Both edges are the same wave offset by half the
    // thickness, which is what makes the band an even weight along its length.
    // Each half period is one cubic with both handles a third of the way in,
    // the usual sine approximation.
    function _band(cy) {
        var spans = 64 / root._half

        function edge(off, reversed) {
            var out = []
            for (var k = 0; k < spans; ++k) {
                var i = reversed ? spans - 1 - k : k
                var xa = (reversed ? i + 1 : i) * root._half
                var xb = (reversed ? i : i + 1) * root._half
                // Alternate crest and trough, so consecutive spans join
                // smoothly at the zero crossings.
                // Up first, then down, reading left to right, matching the
                // direction the old "≋" glyph ran. In Qt's coordinates y grows
                // downward, so "up" is the negative amplitude.
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
