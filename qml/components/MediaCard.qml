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

    // What a right-click pins (P2). The tile's own type doubles as the pin
    // kind; without an id there is nothing to pin and no menu is offered.
    property string itemId: ""
    property string pinKind: mediaType
    // An artist tile's subtitle is the word "Artist", a type label rather than
    // data, and a pin outlives the session it was made in, so the stored
    // subtitle would be a translated word frozen at pin time.
    readonly property string pinSubtitle: mediaType === "artist" ? "" : subtitle

    readonly property alias pinMenu: cardMenu

    // ── queueing ───────────────────────────────────────────────────────
    // The three kinds that ARE a tracklist. An artist is not one: "queue this
    // artist" has no honest meaning, and the only list available is their top
    // ten, which is a chart position rather than anything the user chose. A
    // song tile is not one either; a song is already a single track.
    readonly property bool canQueue: itemId.length > 0
        && (mediaType === "album" || mediaType === "playlist"
            || mediaType === "mix")

    // A tile carries an id and nothing else, so queueing one always fetches:
    // "add this album" has to mean every track on it, not the nothing the
    // tile itself knows. The callback is skipped on an error or an empty
    // result, so a failed fetch queues nothing and says nothing.
    function fetchTracks(cb) {
        function done(t, err) { if (!err && t && t.length > 0) cb(t) }
        if (mediaType === "album")         bridge.fetchAlbumTracks(Number(itemId), done)
        else if (mediaType === "playlist") bridge.fetchPlaylistTracks(itemId, done)
        else if (mediaType === "mix")      bridge.fetchMixTracks(itemId, done)
    }

    // Offered on the tile's own menu below, and callable from a host that
    // covers the tile with a menu of its own (CollectionPage's album grid),
    // so both routes queue the same thing and confirm the same way.
    function playNext()   { cardMenu.playNext() }
    function addToQueue() { cardMenu.addToQueue() }

    // What shows through where a round tile's artwork is cut away. It has to be
    // whatever the card is sitting on; every page that shows cards is a
    // Theme.bg ground, so that is the default, and a host on anything else
    // overrides it rather than getting a seam.
    property color artBackdrop: Theme.bg

    // The gaps the card is built from, so its height below and the art box's
    // position stay one piece of arithmetic.
    readonly property int artGap:    8   // art to title
    readonly property int lineGap:   2   // title to subtitle
    readonly property int bottomPad: 8

    width: cardSize
    // Spelled out instead of measured from a ColumnLayout. A layout takes a
    // child's preferred height from Layout.preferredHeight, else implicitHeight,
    // else - once, when it first measures - the child's plain height; a later
    // plain `height:` assignment does not invalidate that cache. The art box
    // carried a plain `height: cardSize`, so a card built while its grid was
    // still settling kept the stale box: its title was laid out across the
    // cover and its whole card came out shorter than the rest of its row (QA:
    // the leading card of every row sat lower and inset). Every card of a given
    // cardSize now derives the same height, so across a row the art boxes and
    // the title baselines line up by construction, whatever the covers are.
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
        // children, so on a card with a cover the ring was invisible. It is
        // drawn over the art further down instead.

        Image {
            id: img
            objectName: "cardImage"
            anchors.fill: parent
            source: coverUrl.length > 0 ? "image://tidal/" + coverUrl : ""
            // Crop, never fit. A fit letterboxes a cover that is not square,
            // which reads as a smaller picture than the card next to it; a crop
            // fills the box whatever the source's shape. Either way the box
            // itself is fixed, so no cover can reach the layout - and the
            // source is left to decode at its own resolution, because pinning
            // sourceSize on a crop makes Qt fit the decode into that box and
            // then scale the result back up to cover.
            fillMode: Image.PreserveAspectCrop
            smooth: true
            mipmap: true
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.dur(200) } }
        }

        // Qt clips to an item's bounding box, never to its rounded outline, so
        // an artist's photo filled the square and left only the wash over it
        // round: a disc drawn on a square picture. This paints the four corners
        // back out in the ground colour, so the art really is the circle that
        // the wash, the ring and the play button are placed against.
        //
        // A square's corner sits sqrt(2)/2 of the side from the centre and its
        // inscribed circle only 1/2, so a band of (sqrt(2)-1)/2 = 0.2072 of the
        // side covers the corners. A Rectangle paints its border inwards from
        // its radius, so a circle of (side + 2*band) with a border of `band`
        // has its inner edge exactly on the inscribed circle. It overshoots the
        // card either side, which is what imgRect's clip is for.
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
            name: mediaType === "artist" ? "artist" : "music"
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
                // A square card has a corner to tuck the button into. A disc
                // does not: the bottom right of its bounding box is outside the
                // art, so the button floated off the circle with the wash
                // ending behind it. On a disc it goes in the middle, which is
                // the only spot that stays fully on the art at every card size.
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
                    // The play triangle's own centre of area sits left of the
                    // glyph box's centre, so a disc that centres the box looks
                    // like the mark has slid backwards. Nudged, as the text
                    // glyph it replaces was.
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

    // P2. Right button only, so the cover's tap and hover handlers underneath
    // keep every left-click they had.
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
    }
}
