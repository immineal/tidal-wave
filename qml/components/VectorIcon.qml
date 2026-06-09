import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property string name: ""
    property color color: "white"
    property real strokeWidth: 1.8

    implicitWidth: 24
    implicitHeight: 24

    Shape {
        id: shapeItem
        width: 24
        height: 24
        anchors.centerIn: parent
        antialiasing: true
        smooth: true

        transform: Scale {
            origin.x: 12
            origin.y: 12
            xScale: (root.width * 0.85) / 24
            yScale: (root.height * 0.85) / 24
        }

        ShapePath {
            strokeColor: root.color
            // Filled glyphs render as solid shapes; an extra stroke at small
            // sizes just bridges adjacent bars/edges into an unrecognizable
            // blob (e.g. the pause bars merging into a single square).
            strokeWidth: (root.name === "play" || root.name === "pause" || root.name === "more-vertical" || root.name === "more" || root.name === "heart-filled") ? 0 : root.strokeWidth
            fillColor: (root.name === "play" || root.name === "pause" || root.name === "more-vertical" || root.name === "more" || root.name === "heart-filled") ? root.color : "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root._pathFor(root.name) }
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
        case "music":
            return "M 9 18 V 5 L 21 3 V 16 M 9 8 L 21 6 M 9 18 A 3 3 0 1 1 6 15 A 3 3 0 0 1 9 18 Z M 21 16 A 3 3 0 1 1 18 13 A 3 3 0 0 1 21 16 Z"
        case "artist":
            return "M 12 11 A 4 4 0 1 0 12 3 A 4 4 0 0 0 12 11 Z M 4 21 A 8 8 0 0 1 20 21"
        case "user":
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
        case "queue":
            return "M 4 6 H 20 M 4 12 H 20 M 4 18 H 20"
        case "more-vertical":
            return "M 12 14 A 2 2 0 1 1 12 10 A 2 2 0 0 1 12 14 Z M 12 7 A 2 2 0 1 1 12 3 A 2 2 0 0 1 12 7 Z M 12 21 A 2 2 0 1 1 12 17 A 2 2 0 0 1 12 21 Z"
        case "x":
            return "M 18 6 L 6 18 M 6 6 L 18 18"
        case "more":
            return "M 3.5 12 A 1.5 1.5 0 1 0 6.5 12 A 1.5 1.5 0 1 0 3.5 12 Z M 10.5 12 A 1.5 1.5 0 1 0 13.5 12 A 1.5 1.5 0 1 0 10.5 12 Z M 17.5 12 A 1.5 1.5 0 1 0 20.5 12 A 1.5 1.5 0 1 0 17.5 12 Z"
        case "edit":
            return "M 11 4 H 4 A 2 2 0 0 0 2 6 V 20 A 2 2 0 0 0 4 22 H 18 A 2 2 0 0 0 20 20 V 13 M 18.5 2.5 A 2.121 2.121 0 1 1 21.5 5.5 L 12 15 L 8 16 L 9 12 L 18.5 2.5 Z"
        }
        return ""
    }
}
