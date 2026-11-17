import QtQuick
import QtQuick.Controls
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
        storedSubtitle !== undefined ? "" + storedSubtitle
        : (mediaType === "artist" || mediaType === "playlist") ? "" : subtitle
    // Set by a host whose subtitle is a translated label for another kind.
    property var storedSubtitle: undefined

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
    readonly property int artGap:    Theme.space2   // art to title
    readonly property int lineGap:   Theme.spaceHalf   // title to subtitle
    readonly property int bottomPad: Theme.space2

    width: cardSize
    // Spelled out, not measured from a ColumnLayout: a layout caches a child's
    // plain height the first time it measures, and a later `height:` assignment
    // does not invalidate that. Every card of a cardSize is the same height.
    height: cardSize + artGap + titleText.height + lineGap + subText.height + bottomPad

    signal clicked()
    signal playClicked()

    // The keyboard is on the card or on its play button.
    readonly property bool keyboardOn: root.activeFocus || playButton.activeFocus

    // A host list sets this so its cards are one tab stop between them
    // (the current card); the arrows are the list's.
    property bool tabStop: true
    activeFocusOnTab: tabStop || activeFocus
    Keys.onReturnPressed: root.clicked()
    Keys.onSpacePressed:  root.clicked()
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Menu
                || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
            root.openMenu(16, root.cardSize)
            event.accepted = true
        }
    }
    function openMenu(x, y) {
        cardMenu.showPin(x, y, root.pinKind, root.itemId,
                         root.title, root.pinSubtitle, root.coverUrl)
    }
    Accessible.role: Accessible.Button
    Accessible.name: root.subtitle.length > 0
                     ? qsTr("%1, %2", "card for a screen reader: title, subtitle")
                           .arg(root.title).arg(root.subtitle)
                     : root.title
    Accessible.onPressAction: root.clicked()

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
            Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.motionMedium) } }
        }

        VectorIcon {
            visible: root.coverUrl.length === 0 || img.status === Image.Error
            anchors.centerIn: parent
            name: root.placeholderGlyph
            color: Theme.textDim
            width: 48
            height: 48
        }

        // The hover dim, over the whole cover and in its shape: a loaded cover
        // is drawn square (the clip is the box, not the rounding), so it is
        // square then. A wash over art is the same in every theme.
        Rectangle {
            id: scrim
            objectName: "cardScrim"
            anchors.fill: parent
            radius: !root.roundArt && img.status === Image.Ready ? 0 : parent.radius
            color: hov.hovered || root.keyboardOn ? Theme.artScrim : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.motionMedium) } }
        }

        // Qt clips to an item's bounding box, never to its rounded outline, so
        // this ring paints the four corners of a round tile out in the ground
        // colour. A band of (sqrt(2)-1)/2 = 0.2072 of the side covers them.
        // Over the dim, so the dim ends where the disc does.
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

        // A plain play glyph in the middle of the cover: it plays, the rest
        // of the cover opens the page.
        Item {
            id: playButton
            objectName: "cardPlayButton"
            visible: hov.hovered || root.keyboardOn
            // Next after its card in the tab order, and only while the
            // keyboard is on that card: the list stays one stop.
            activeFocusOnTab: root.tabStop || activeFocus
            Keys.onReturnPressed: root.playClicked()
            Keys.onSpacePressed:  root.playClicked()
            Accessible.role: Accessible.Button
            Accessible.name: qsTranslate("PlayerBar", "Play")
            Accessible.onPressAction: root.playClicked()
            width: 56
            height: 56
            anchors.centerIn: parent

            VectorIcon {
                anchors.centerIn: parent
                // The triangle's centre of area sits left of its box's
                // centre, so the mark is nudged to look centred.
                anchors.horizontalCenterOffset: 2
                name: "play"
                color: Theme.artInk
                width: 36
                height: 36
            }
            // Only for the keyboard: a ring, never a fill.
            Rectangle {
                anchors.fill: parent
                visible: playButton.activeFocus
                color: "transparent"
                radius: width / 2
                border.width: 2
                border.color: Theme.artInk
            }

            HoverHandler { id: playHov; cursorShape: Qt.PointingHandCursor }
            TapHandler   { onTapped: root.playClicked() }
            ToolTip.visible: playHov.hovered
            ToolTip.text: Accessible.name
            ToolTip.delay: Theme.tooltipDelay
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
        // Both tap handlers see a tap on the glyph; that one only plays.
        TapHandler {
            onTapped: function (eventPoint) {
                if (playButton.visible && playButton.contains(
                        playButton.mapFromItem(playButton.parent, eventPoint.position)))
                    return
                root.clicked()
            }
        }
    }

    Text {
        id: titleText
        objectName: "cardTitle"
        anchors.top: imgRect.bottom
        anchors.topMargin: root.artGap
        width: root.cardSize
        text: root.title
        color: Theme.textPrimary
        font.pixelSize: Theme.fontBody
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
        font.pixelSize: Theme.fontMeta
        // A line a little too long shrinks to fit, down to the micro size,
        // and is cut below that. The height stays the 13 px line's.
        fontSizeMode: Text.HorizontalFit
        minimumPixelSize: Theme.fontMicro
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
            root.openMenu(p.x, p.y)
        }
    }

    ContextMenu {
        id: cardMenu
        objectName: "cardPinMenu"
        trackSource: root.canQueue ? root.fetchTracks : null
        removeLabel: root.removeLabel
        onRemoveRequested: root.removeRequested()
    }
}
