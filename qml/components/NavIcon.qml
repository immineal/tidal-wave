import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property string name: "home"   // "home" | "search" | "heart"
    property color  color: "white"
    implicitWidth: 18
    implicitHeight: 18

    Shape {
        anchors.fill: parent
        antialiasing: true
        ShapePath {
            strokeColor: root.color
            strokeWidth: 1.6
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root._pathFor(root.name) }
        }
    }

    function _pathFor(n) {
        switch (n) {
        case "home":
            return "M2.5 9.5 L9 3 L15.5 9.5 L15.5 15.5 L2.5 15.5 Z " +
                   "M7 15.5 L7 11.5 L11 11.5 L11 15.5"
        case "search":
            return "M3 8 A5 5 0 1 0 13 8 A5 5 0 1 0 3 8 " +
                   "M12.2 12.2 L16.5 16.5"
        case "heart":
            return "M9 15.5 C4 11.7 2 8.8 3.6 6.3 C4.8 4.5 7.4 4.6 9 6.8 " +
                   "C10.6 4.6 13.2 4.5 14.4 6.3 C16 8.8 14 11.7 9 15.5 Z"
        }
        return ""
    }
}
