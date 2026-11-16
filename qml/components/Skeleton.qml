import QtQuick
import TidalWave

// The shape of a page while its content is on the way: grey blocks where the
// hero, the rows or the cards will land, on the page's own ground. It breathes
// slowly, and stands still under reduced motion.
Item {
    id: skel
    objectName: "loadingSkeleton"

    property bool loading: false
    // "detail": a hero and track rows (album, playlist, mix, radio, artist).
    // "cards":  section headings over rows of cards (home, search).
    // "grid":   a grid of cards (collection).
    // "rows":   track rows alone (collection's tracks).
    property string kind: "detail"
    // How far down the page the shapes start, for a page that keeps its
    // own header in view while it loads.
    property int topInset: 0

    visible: loading
    anchors.fill: parent
    // Over the page, under DetailBar (z 10): the way back stays in reach.
    z: 5

    // Whatever was on the page before stays out of sight, and the blocks
    // under the pointer take its clicks. Above topInset the page shows.
    Rectangle {
        anchors.fill: parent
        anchors.topMargin: skel.topInset
        color: Theme.bg
        MouseArea { anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.AllButtons }
    }

    readonly property color block: Theme.surfaceHigh
    // The track rows' and cards' sizes, as TrackRow and HorizontalSection draw them.
    readonly property int rowH: 52
    readonly property int cardSize: 160
    readonly property int cardGap: 16
    readonly property alias pulse: pulseAnim
    readonly property alias shapes: shapes

    Item {
        id: shapes
        anchors.fill: parent
        anchors.topMargin: skel.topInset
        clip: true

        // Under reduced motion it does not run, so the blocks sit at full
        // strength rather than wherever the pulse was.
        SequentialAnimation on opacity {
            id: pulseAnim
            objectName: "skeletonPulse"
            running: skel.visible && !Theme.reduceMotion
            loops: Animation.Infinite
            alwaysRunToEnd: false
            NumberAnimation { from: 1; to: 0.55; duration: Theme.dur(Theme.motionSlow * 2); easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.55; to: 1; duration: Theme.dur(Theme.motionSlow * 2); easing.type: Easing.InOutSine }
            onRunningChanged: if (!running) shapes.opacity = 1
        }

        // ── detail: DetailHero's art and lines, then the tracklist ────────
        Item {
            visible: skel.kind === "detail" || skel.kind === "rows"
            anchors.fill: parent

            Item {
                id: heroBox
                visible: skel.kind === "detail"
                width: parent.width
                height: visible ? 280 : 0
                Rectangle {
                    id: art
                    objectName: "skeletonArt"
                    x: Theme.space16
                    anchors.verticalCenter: parent.verticalCenter
                    width: 200; height: 200
                    radius: Theme.radiusSmall
                    color: skel.block
                }
                Column {
                    anchors.left: art.right
                    anchors.leftMargin: Theme.space6
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space3
                    Rectangle { width: 64;  height: 10; radius: height / 2; color: skel.block }
                    Rectangle { width: Math.min(360, heroBox.width * 0.4); height: 28; radius: Theme.radiusSmall; color: skel.block }
                    Rectangle { width: 180; height: 12; radius: height / 2; color: skel.block }
                    Item { width: 1; height: Theme.space2 }
                    Row {
                        spacing: Theme.space3
                        Rectangle { width: 96; height: 36; radius: height / 2; color: skel.block }
                        Rectangle { width: 36; height: 36; radius: height / 2; color: skel.block }
                        Rectangle { width: 36; height: 36; radius: height / 2; color: skel.block }
                    }
                }
            }

            Column {
                id: rowsCol
                anchors.top: heroBox.bottom
                anchors.topMargin: Theme.space4
                x: Theme.space6
                width: parent.width - 2 * Theme.space6
                Repeater {
                    model: Math.max(0, Math.ceil((shapes.height - heroBox.height) / skel.rowH))
                    Item {
                        objectName: "skeletonRow"
                        required property int index
                        width: rowsCol.width
                        height: skel.rowH
                        Rectangle {
                            id: num
                            x: Theme.space3
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14; height: 10; radius: height / 2; color: skel.block
                        }
                        Rectangle {
                            id: rowArt
                            anchors.left: num.right
                            anchors.leftMargin: Theme.space4
                            anchors.verticalCenter: parent.verticalCenter
                            width: 36; height: 36; radius: Theme.radiusSmall; color: skel.block
                        }
                        Column {
                            anchors.left: rowArt.right
                            anchors.leftMargin: Theme.space3
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.space2
                            // Lengths that vary, so it reads as a list of titles.
                            Rectangle { width: 140 + (index * 53) % 120; height: 11; radius: height / 2; color: skel.block }
                            Rectangle { width: 80 + (index * 37) % 70;  height: 9;  radius: height / 2; color: skel.block }
                        }
                        Rectangle {
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.space4
                            anchors.verticalCenter: parent.verticalCenter
                            width: 32; height: 10; radius: height / 2; color: skel.block
                        }
                    }
                }
            }
        }

        // ── cards: headings over rows of cards, as HorizontalSection ──────
        Column {
            visible: skel.kind === "cards"
            anchors.fill: parent
            anchors.topMargin: Theme.space6
            spacing: Theme.space8
            Rectangle {
                x: Theme.space6
                width: 220; height: 28; radius: Theme.radiusSmall; color: skel.block
            }
            Repeater {
                model: Math.max(1, Math.ceil(shapes.height / (skel.cardSize + 110)))
                Column {
                    x: Theme.space6
                    spacing: Theme.space3
                    Rectangle { width: 140; height: 18; radius: Theme.radiusSmall; color: skel.block }
                    Row {
                        spacing: skel.cardGap
                        Repeater {
                            model: Math.max(1, Math.ceil((shapes.width - Theme.space6) / (skel.cardSize + skel.cardGap)))
                            Column {
                                objectName: "skeletonCard"
                                spacing: Theme.space2
                                Rectangle { width: skel.cardSize; height: skel.cardSize; radius: Theme.radiusLarge; color: skel.block }
                                Rectangle { width: skel.cardSize * 0.7; height: 11; radius: height / 2; color: skel.block }
                                Rectangle { width: skel.cardSize * 0.45; height: 9; radius: height / 2; color: skel.block }
                            }
                        }
                    }
                }
            }
        }

        // ── grid: Collection's cells ──────────────────────────────────────
        Grid {
            id: cardGrid
            visible: skel.kind === "grid"
            anchors.fill: parent
            anchors.margins: Theme.space6
            columns: Math.max(1, Math.floor((width + skel.cardGap) / (skel.cardSize + skel.cardGap)))
            columnSpacing: skel.cardGap
            rowSpacing: Theme.space6
            Repeater {
                model: cardGrid.columns * Math.max(1, Math.ceil(shapes.height / (skel.cardSize + 60)))
                Column {
                    objectName: "skeletonCard"
                    spacing: Theme.space2
                    Rectangle { width: skel.cardSize; height: skel.cardSize; radius: Theme.radiusLarge; color: skel.block }
                    Rectangle { width: skel.cardSize * 0.7; height: 11; radius: height / 2; color: skel.block }
                    Rectangle { width: skel.cardSize * 0.45; height: 9; radius: height / 2; color: skel.block }
                }
            }
        }
    }
}
