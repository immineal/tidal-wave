import QtQuick
import TidalWave

Item {
    id: root

    property string coverUrl: ""
    property string title: ""
    property string subtitle: ""
    property string mediaType: "album"
    property int    cardSize: 160

    // Artist tiles are discs, every other kind is a rounded square. Named once
    // here because the art, the wash, the focus ring and the play button all
    // have to agree on which shape this card is.
    readonly property bool roundArt: mediaType === "artist"

    // What a right-click pins. The tile's own type doubles as the pin kind;
    // without an id there is nothing to pin and no menu is offered.
    property string itemId: ""
    property string pinKind: mediaType
    // An artist's or a playlist's subtitle is a translated label, and a pin
    // outlives the session it was made in, so those two kinds store none.
    readonly property string pinSubtitle:
        (mediaType === "artist" || mediaType === "playlist") ? "" : subtitle

    readonly property alias pinMenu: cardMenu

    // The destructive entry on the tile's own menu, if the host offers one.
    // Empty on most pages. See ContextMenu.removeLabel.
    property string removeLabel: ""
    signal removeRequested()

    // The mark where there is no cover: the glyph of the kind the tile stands
    // for, and the track note for anything else.
    readonly property string placeholderGlyph:
        (mediaType === "album" || mediaType === "artist"
         || mediaType === "playlist" || mediaType === "mix") ? mediaType : "track"

    // ── queueing ───────────────────────────────────────────────────────
    // The three kinds that are a tracklist. An artist is not one (the only
    // list available is their top ten), and a song is already a single track.
    readonly property bool canQueue: itemId.length > 0
        && (mediaType === "album" || mediaType === "playlist"
            || mediaType === "mix")

    // A tile carries only an id, so queueing one always fetches every track.
    // The callback is skipped on an error or an empty result.
    function fetchTracks(cb) {
        function done(t, err) { if (!err && t && t.length > 0) cb(t) }
        if (mediaType === "album")         bridge.fetchAlbumTracks(Number(itemId), done)
        else if (mediaType === "playlist") bridge.fetchPlaylistTracks(itemId, done)
        else if (mediaType === "mix")      bridge.fetchMixTracks(itemId, done)
    }

    // What shows through where a round tile's artwork is cut away. It has to
    // match the ground the card sits on; a host not on Theme.bg overrides it.
    property color artBackdrop: Theme.bg

    // The gaps the card is built from, so its height below and the art box's
    // position stay one piece of arithmetic.
    readonly property int artGap:    8   // art to title
    readonly property int lineGap:   2   // title to subtitle
    readonly property int bottomPad: 8

    width: cardSize
    // Spelled out, not measured from a ColumnLayout: a layout caches a child's
    // plain height the first time it measures, and a later `height:` assignment
    // does not invalidate that. Every card of a cardSize is the same height.
    height: cardSize + artGap + titleText.height + lineGap + subText.height + bottomPad

    signal clicked()
    signal playClicked()

    activeFocusOnTab: true
    Keys.onReturnPressed: root.clicked()
    Keys.onSpacePressed:  root.clicked()

    Rectangle {
        id: imgRect
        objectName: "cardArt"
        // A fixed square, driven by cardSize alone: nothing about the cover
        // that loads into it may move it or its neighbours.
        width:  root.cardSize
        height: root.cardSize
        radius: root.roundArt ? width / 2 : Theme.radiusCard
        color: Theme.surfaceHigh
        clip: true
        // No focus ring here: a Rectangle paints its border under its own
        // children, so a cover would hide it. It is drawn over the art below.

        Image {
            id: img
            objectName: "cardImage"
            anchors.fill: parent
            source: coverUrl.length > 0 ? "image://tidal/" + coverUrl : ""
            // Crop, never fit: a fit letterboxes a cover that is not square. No
            // sourceSize: on a crop Qt fits the decode into that box and then
            // scales the result back up to cover.
            fillMode: Image.PreserveAspectCrop
            smooth: true
            mipmap: true
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.dur(200) } }
        }

        // Qt clips to an item's bounding box, never to its rounded outline, so
        // this ring paints the four corners of a round tile out in the ground
        // colour. A band of (sqrt(2)-1)/2 = 0.2072 of the side covers them.
        Rectangle {
            id: artCorners
            objectName: "cardArtCorners"
            visible: root.roundArt
            anchors.centerIn: parent
            readonly property int band: Math.ceil(root.cardSize * 0.2072) + 1
            width:  root.cardSize + 2 * band
            height: width
            radius: width / 2
            color: "transparent"
            border.width: band
            border.color: root.artBackdrop
            antialiasing: true
        }

        VectorIcon {
            visible: root.coverUrl.length === 0 || img.status === Image.Error
            anchors.centerIn: parent
            name: root.placeholderGlyph
            color: Theme.textDim
            width: 48
            height: 48
            strokeWidth: 1.5
        }

        Rectangle {
            id: scrim
            objectName: "cardScrim"
            anchors.fill: parent
            radius: parent.radius
            // Dims the art so the play button reads; a wash over cover art
            // cannot follow the ground, so it is the same in every theme.
            color: hov.hovered ? Theme.artScrim : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.dur(150) } }

            Rectangle {
                id: playButton
                objectName: "cardPlayButton"
                visible: hov.hovered
                width: 44
                height: 44
                radius: 22
                // A square card has a corner to tuck the button into. On a
                // disc that corner is off the art, so the button is centred.
                anchors.centerIn: root.roundArt ? parent : undefined
                anchors.bottom:   root.roundArt ? undefined : parent.bottom
                anchors.right:    root.roundArt ? undefined : parent.right
                anchors.margins:  root.roundArt ? 0 : 12
                color: Theme.accent

                VectorIcon {
                    anchors.centerIn: parent
                    name: "play"
                    color: Theme.accentInk
                    width: 18
                    height: 18
                    // The triangle's centre of area sits left of its box's
                    // centre, so the mark is nudged to look centred.
                    anchors.horizontalCenterOffset: 1
                }

                scale: playHov.hovered ? 1.05 : 1
                Behavior on scale { NumberAnimation { duration: Theme.dur(100) } }
                HoverHandler { id: playHov; cursorShape: Qt.PointingHandCursor }
                TapHandler   { onTapped: root.playClicked() }
            }
        }

        // Over everything, and on the tile's own radius, so it traces the
        // circle on an artist and the rounded square on everything else.
        Rectangle {
            objectName: "cardFocusRing"
            anchors.fill: parent
            visible: root.activeFocus
            color: "transparent"
            radius: parent.radius
            border.width: 4
            border.color: Theme.accent
            antialiasing: true
        }

        HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: root.clicked() }
    }

    Text {
        id: titleText
        objectName: "cardTitle"
        anchors.top: imgRect.bottom
        anchors.topMargin: root.artGap
        width: root.cardSize
        text: root.title
        color: Theme.textPrimary
        font.pixelSize: 14
        font.bold: true
        elide: Text.ElideRight
        wrapMode: Text.NoWrap
    }

    Text {
        id: subText
        objectName: "cardSubtitle"
        anchors.top: titleText.bottom
        anchors.topMargin: root.lineGap
        width: root.cardSize
        text: root.subtitle
        color: Theme.textSec
        font.pixelSize: 12
        elide: Text.ElideRight
        wrapMode: Text.NoWrap
    }

    // Right button only, so the cover's tap and hover handlers underneath
    // keep every left-click.
    MouseArea {
        objectName: "cardMenuArea"
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: function (mouse) {
            var p = mapToItem(root, mouse.x, mouse.y)
            cardMenu.showPin(p.x, p.y, root.pinKind, root.itemId,
                             root.title, root.pinSubtitle, root.coverUrl)
        }
    }

    ContextMenu {
        id: cardMenu
        objectName: "cardPinMenu"
        trackSource: root.canQueue ? root.fetchTracks : null
        // The tile has room above it on every page that shows one, and the
        // confirmation belongs next to the thing it is about.
        confirmAnchor: root
        removeLabel: root.removeLabel
        onRemoveRequested: root.removeRequested()
    }
}
