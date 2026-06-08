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
        anchors.fill: parent
        antialiasing: true
        ShapePath {
            strokeColor: root.color
            strokeWidth: root.strokeWidth
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root._pathFor(root.name) }
        }
    }

    function _pathFor(n) {
        switch (n) {
        case "music":
            return "M 11 16 A 3 3 0 1 1 8 13 A 3 3 0 0 1 11 16 Z M 11 16 L 11 5 L 17 7 L 17 10 L 11 8"
        case "artist":
            return "M 16 7 A 4 4 0 1 1 12 3 A 4 4 0 0 1 16 7 Z M 5 21 C 5 16, 19 16, 19 21"
        case "volume-mute":
            return "M 4 9 L 8 9 L 12 5 L 12 19 L 8 15 L 4 15 Z M 16 10 L 20 14 M 20 10 L 16 14"
        case "volume-low":
            return "M 4 9 L 8 9 L 12 5 L 12 19 L 8 15 L 4 15 Z M 15 9 A 3.5 3.5 0 0 1 15 15"
        case "volume-mid":
            return "M 4 9 L 8 9 L 12 5 L 12 19 L 8 15 L 4 15 Z M 15 9 A 3.5 3.5 0 0 1 15 15 M 18 7 A 7 7 0 0 1 18 17"
        case "volume-high":
            return "M 4 9 L 8 9 L 12 5 L 12 19 L 8 15 L 4 15 Z M 15 9 A 3.5 3.5 0 0 1 15 15 M 18 7 A 7 7 0 0 1 18 17 M 21 5 A 10.5 10.5 0 0 1 21 19"
        case "search":
            return "M 16 10 A 4.5 4.5 0 1 1 11.5 5.5 A 4.5 4.5 0 0 1 16 10 Z M 15 13.5 L 20 18.5"
        }
        return ""
    }
}
