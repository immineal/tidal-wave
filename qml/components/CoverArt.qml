import QtQuick
import TidalWave

// A cover in its box, cropped to fill it, and a themed placeholder in the
// same box where there is no cover or it failed to load.
Rectangle {
    id: box

    // An id for the "tidal" image provider; empty means there is none.
    property string source: ""
    // What the placeholder draws: the kind of thing the cover stands for.
    property string glyph: "track"
    // Decode size; unset decodes at the image's own size. Both dimensions,
    // since a width alone reaches the provider with a height of zero.
    property var decodeSize: undefined
    readonly property alias status: img.status
    // So a test can reach the image by the name it always had.
    property alias imageName: img.objectName

    radius: Theme.radiusSmall
    color: Theme.surfaceHigh
    clip: true

    Image {
        id: img
        anchors.fill: parent
        source: box.source.length > 0 ? "image://tidal/" + box.source : ""
        sourceSize: box.decodeSize
        fillMode: Image.PreserveAspectCrop
        smooth: true
        mipmap: true
    }

    VectorIcon {
        objectName: "coverPlaceholder"
        visible: box.source.length === 0 || img.status === Image.Error
        anchors.centerIn: parent
        name: box.glyph
        color: Theme.textDim
        width: Math.round(Math.min(box.width, box.height) * 0.45)
        height: width
    }
}
