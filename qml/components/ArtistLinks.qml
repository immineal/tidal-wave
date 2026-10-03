import QtQuick
import QtQuick.Window
import TidalWave

// One line of artist credits, with one hover target and one tab stop per
// artist, so a featured credit opens the guest rather than the lead (SPEC N2).
//
// It began as two copies, in components/PlayerBar.qml and in
// pages/NowPlayingPage.qml, and the note left on the second one said that if
// the two ever disagreed this was the pair to reconcile. They are one file now,
// and every other artists line in the app uses it as well.
//
// What a host has to say:
//
//   artistList       [{id, name}], as TidalBridge::trackToMap() and
//                    albumToMap() carry it. Empty or missing falls back to the
//                    joined line below.
//   joinedText       the joined names, for a map with no artistList.
//   fallbackArtistId the one artist such a map can name. 0 leaves the fallback
//                    line plain text, which is what the player bar wants: a
//                    click goes through to whatever sits under the line.
//   fontPixelSize    12 in the bar and the lists, 18 on Now Playing.
//   namePrefix       prefixes the objectNames the tests reach for:
//                    <prefix>ArtistLine on this item, <prefix>ArtistName per
//                    name, <prefix>ArtistSeparator per separator, and
//                    <prefix>Artists on the joined fallback.
//
// Height is implicit, never assigned: a Layout owns its children's size and
// ignores an explicit height in favour of the implicit one, so hosts in a
// RowLayout or ColumnLayout only have to say Layout.fillWidth.
Item {
    id: root

    property var    artistList: []
    property string joinedText: ""
    // `real` and not `int`, because an id is a qint64 in src/api/Models.h and
    // QML's int is 32-bit. TrackRow.trackId is a real for the same reason.
    property real   fallbackArtistId: 0
    property int    fontPixelSize: 12
    property string namePrefix: ""

    readonly property var credits:
        (artistList && artistList.length > 0) ? artistList : []

    // Sits between two names and belongs to neither, so it is not a link.
    readonly property string separator: qsTr(", ", "between two artist names")

    objectName: root.namePrefix + "ArtistLine"
    implicitHeight: Math.max(fallbackLine.implicitHeight, nameRow.implicitHeight)

    FontMetrics { id: fm; font.pixelSize: root.fontPixelSize }

    // Where the i-th name begins, measured on the names in front of it rather
    // than on the laid-out items: a delegate cannot see its siblings' widths,
    // and binding a width to the x a Row just assigned is how binding loops
    // start.
    function startX(i) {
        if (i <= 0) return 0
        var before = []
        for (var k = 0; k < i && k < root.credits.length; k++)
            before.push(root.credits[k].name)
        return fm.advanceWidth(before.join(root.separator))
    }

    // Guarded here rather than at each call site, so a credit with no id is a
    // no-op wherever it is activated from.
    function openArtist(artistId) {
        if (artistId > 0 && Window.window)
            Window.window.navigate("artist", { artistId: artistId })
    }

    // The stand-in for a track whose map predates artistList: recently-played
    // entries restored from disk, and anything a caller builds by hand. It is
    // the lead artist or nothing, which is all such a map says.
    Text {
        id: fallbackLine
        objectName: root.namePrefix + "Artists"
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.credits.length === 0
        text: root.joinedText
        color: fallbackHit.containsMouse ? Theme.textPrimary : Theme.textSec
        font.pixelSize: root.fontPixelSize
        elide: Text.ElideRight
        font.underline: fallbackHit.containsMouse
        activeFocusOnTab: visible && root.fallbackArtistId > 0
        Keys.onReturnPressed: root.openArtist(root.fallbackArtistId)
        Keys.onSpacePressed:  root.openArtist(root.fallbackArtistId)

        Rectangle {
            // Tracks the words, not the column the Text fills, so the ring and
            // the hit target do not float out to the right of a short name.
            x: -4; y: -4
            width:  Math.min(parent.width, parent.contentWidth) + 8
            height: parent.height + 8
            radius: Theme.radiusButton; color: "transparent"
            border.width: fallbackLine.activeFocus ? 2 : 0
            border.color: Theme.accent
        }
        MouseArea {
            id: fallbackHit
            width:  Math.min(parent.width, parent.contentWidth)
            height: parent.height
            enabled: root.fallbackArtistId > 0
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openArtist(root.fallbackArtistId)
        }
    }

    Row {
        id: nameRow
        width: parent.width
        visible: root.credits.length > 0
        spacing: 0

        Repeater {
            model: root.credits
            delegate: Row {
                id: credit
                required property var modelData
                required property int index

                readonly property bool linkable: Number(modelData.id) > 0
                readonly property real sepWidth: index > 0 ? sep.implicitWidth : 0
                // What the line has left once the names in front of this one
                // have taken theirs. The pixel of slack absorbs the difference
                // between the measured string and the rendered one.
                readonly property real room:
                    Math.max(0, nameRow.width - root.startX(index) - sepWidth - 1)
                // Too tight to read is too tight to aim at, so the name goes
                // rather than leaving a clickable sliver or an unreachable tab
                // stop behind.
                visible: room >= 8
                spacing: 0

                Text {
                    id: sep
                    objectName: root.namePrefix + "ArtistSeparator"
                    visible: credit.index > 0
                    text: root.separator
                    color: Theme.textSec
                    font.pixelSize: root.fontPixelSize
                }

                Text {
                    id: name
                    objectName: root.namePrefix + "ArtistName"
                    text: credit.modelData.name
                    // Only the name that runs out of line elides; the ones
                    // before it keep their full width.
                    width: Math.min(implicitWidth, credit.room)
                    elide: Text.ElideRight
                    font.pixelSize: root.fontPixelSize
                    font.underline: nameHit.containsMouse
                    color: nameHit.containsMouse ? Theme.textPrimary : Theme.textSec
                    // Tab reaches each artist in turn rather than one blob, and
                    // skips a credit with no id because there is nowhere for it
                    // to go.
                    activeFocusOnTab: credit.linkable
                    Keys.onReturnPressed: root.openArtist(Number(credit.modelData.id))
                    Keys.onSpacePressed:  root.openArtist(Number(credit.modelData.id))

                    Rectangle {
                        x: -4; y: -4
                        width:  parent.width + 8
                        height: parent.height + 8
                        radius: Theme.radiusButton; color: "transparent"
                        border.width: name.activeFocus ? 2 : 0
                        border.color: Theme.accent
                    }

                    // A MouseArea rather than a Tap/Hover handler pair: a
                    // TapHandler only takes a passive grab, so a click target
                    // underneath answers the same press and one click does both
                    // things. This one swallows it. Left button only, so a
                    // right-click still reaches the row menu under a track row.
                    //
                    // Disabled when the artist has no id, so that name is not a
                    // dead target: the click falls through like the gaps do, and
                    // nothing about it lights up.
                    //
                    // hoverEnabled here takes the hover event off whatever is
                    // behind the name. A parent MouseArea therefore stops
                    // reporting containsMouse while the pointer is on a name,
                    // which is why a host that dresses itself on hover reads it
                    // from a HoverHandler instead — see TrackRow's rowHover.
                    MouseArea {
                        id: nameHit
                        anchors.fill: parent
                        enabled: credit.linkable
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openArtist(Number(credit.modelData.id))
                    }
                }
            }
        }
    }
}
