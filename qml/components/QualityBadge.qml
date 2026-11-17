import QtQuick
import TidalWave

// The one quality badge, in the player bar and in Now Playing: the real
// format once the stream has said it, on the tier's colour. `withTier` puts
// the tier's name in front, for a place with room for both.
Rectangle {
    id: badge
    objectName: "qualityBadge"

    property bool withTier: false
    readonly property string quality: player.audioQuality
    readonly property string format: player.audioFormat

    visible: quality.length > 0
    implicitWidth: label.implicitWidth + 2 * Theme.space2
    implicitHeight: label.implicitHeight + 2 * Theme.space1
    radius: Theme.radiusBadge
    color: quality === "HI_RES_LOSSLESS" ? Theme.accentWash
         : quality === "LOSSLESS" ? Theme.greenWash : Theme.surfaceHigh

    Accessible.role: Accessible.StaticText
    Accessible.name: label.text

    Text {
        id: label
        objectName: "qualityBadgeText"
        anchors.centerIn: parent
        // Elides where the place it sits in is narrower than the words.
        width: Math.min(implicitWidth, badge.width - 2 * Theme.space2)
        elide: Text.ElideRight
        text: {
            var tier = player.qualityLabel(badge.quality)
            if (badge.format.length === 0) return tier
            return badge.withTier ? tier + " · " + badge.format : badge.format
        }
        color: Theme.textPrimary
        font.pixelSize: Theme.fontMicro
        font.bold: true
    }
}
