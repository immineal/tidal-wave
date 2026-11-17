import QtQuick
import TidalWave

// The small "E" that marks a track as explicit, as Tidal and other players
// draw it. The letter is a mark and stays as it is in every language; the
// name a screen reader hears is translated.
Rectangle {
    id: badge
    readonly property string label: "E"

    implicitWidth: 16
    implicitHeight: 16
    radius: Theme.radiusSmall
    color: Theme.textSec

    Accessible.role: Accessible.StaticText
    Accessible.name: qsTr("Explicit", "mark on a track whose lyrics are as recorded")

    Text {
        anchors.centerIn: parent
        text: badge.label
        color: Theme.bg
        font.pixelSize: Theme.fontMicro
        font.bold: true
    }
}
