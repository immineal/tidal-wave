import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

// Says there is a newer release, once at launch and then not again.
// UpdateCheck (src/ui/UpdateCheck.h) decides whether there is anything to
// say. Not wired to `updateChanged`: a check that finishes mid-session must
// not throw a modal over whatever is playing, so showIfAvailable() reads the
// answer once and the next launch gets the new one.
Popup {
    id: root

    // The UpdateCheck instance, the `updateCheck` context property in the
    // app. Passed in so a test can hand it a double; nothing else swaps it.
    property var check: null

    // Exposed so tests can click them. Nothing else reads them.
    readonly property alias openButton:  openBtn
    readonly property alias laterButton: laterBtn
    readonly property alias skipButton:  skipBtn

    // One ask per launch, whatever happens afterwards.
    property bool _asked: false
    // Set by the three buttons, so the close that follows is not also read as
    // a dismissal. Every other close, Escape above all, means Later and never
    // Skip: a stray keypress must not throw a release away for good.
    property bool _handled: false

    // Called once, from Main.qml, after the window is up. Returns whether it
    // actually opened, which is what the tests assert on.
    function showIfAvailable() {
        if (_asked) return false
        if (!check || !check.enabled || !check.updateAvailable) return false
        _asked = true
        _handled = false
        open()
        return true
    }

    function openRelease() {
        _handled = true
        app.openUrl(check ? check.releaseUrl : "")
        close()
    }

    function postpone() {
        _handled = true
        if (check) check.remindLater()
        close()
    }

    function skipVersion() {
        _handled = true
        if (check) check.skipThisVersion()
        close()
    }

    onClosed: {
        if (_handled) return
        if (check) check.remindLater()
    }

    anchors.centerIn: Overlay.overlay
    // Clamped to the overlay with 32px on every side, as the Settings popup
    // is, so the dialog fits the 640x600 minimum window. `parent` here is
    // Overlay.overlay, courtesy of anchors.centerIn.
    width:  Math.min(440, (parent ? parent.width  : 440) - 64)
    height: Math.min(implicitHeight, (parent ? parent.height : 600) - 64)
    modal: true
    focus: true
    // No CloseOnPressOutside: there are three explicit answers and a click
    // beside the dialog is not one of them.
    closePolicy: Popup.CloseOnEscape
    padding: 20

    Overlay.modal: Rectangle { color: Theme.scrim }

    background: Rectangle {
        color: Theme.surfaceHigh
        border.color: Theme.border
        radius: Theme.radiusPopup
    }

    // A flat button, local to this dialog. PillButton is the hero-page pill and
    // is sized for that job; these are dialog-sized and need a focus ring.
    component ActionButton: Item {
        id: btn
        property string label: ""
        property bool   primary: false
        signal activated()

        implicitWidth:  Math.max(84, btnLabel.implicitWidth + 28)
        implicitHeight: 34
        activeFocusOnTab: true

        Rectangle {
            anchors.fill: parent
            radius: Theme.radiusButton
            color: btn.primary ? (btnHover.hovered ? Theme.accentDim : Theme.accent)
                               : (btnHover.hovered ? Theme.surfaceHov : Theme.surface)
            border.width: btn.activeFocus ? 2 : (btn.primary ? 0 : 1)
            border.color: btn.activeFocus ? Theme.accent : Theme.border
        }

        Text {
            id: btnLabel
            anchors.centerIn: parent
            text: btn.label
            color: btn.primary ? Theme.accentInk : Theme.textPrimary
            font.pixelSize: 13
            font.bold: btn.primary
        }

        HoverHandler { id: btnHover; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: btn.activated() }

        Keys.onReturnPressed: btn.activated()
        Keys.onEnterPressed:  btn.activated()
        Keys.onSpacePressed:  btn.activated()
    }

    contentItem: ColumnLayout {
        spacing: 12

        Text {
            text: qsTr("Update available")
            color: Theme.textPrimary
            font.pixelSize: 17
            font.bold: true
            Layout.fillWidth: true
            elide: Text.ElideRight
        }

        Text {
            // One sentence with both versions in it, not two concatenated
            // fragments: German puts them in a different order.
            text: qsTr("Version %1 is available. You are running %2.")
                      .arg(root.check ? root.check.latestVersion : "")
                      .arg(prefs.appVersion())
            color: Theme.textSec
            font.pixelSize: 13
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        Text {
            // The whole point of the feature's shape, so it is on the dialog
            // and not only in the privacy block.
            text: qsTr("This opens the release page in your browser. The app does not download or install anything.")
            color: Theme.textDim
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        // A Flow, not a Row: three labels that fit in English do not all fit
        // across 400px once they are German, and wrapping beats clipping.
        Flow {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 8

            ActionButton {
                id: openBtn
                label: qsTr("Open release")
                primary: true
                focus: true
                onActivated: root.openRelease()
            }
            ActionButton {
                id: laterBtn
                label: qsTr("Later")
                onActivated: root.postpone()
            }
            ActionButton {
                id: skipBtn
                label: qsTr("Skip this version")
                onActivated: root.skipVersion()
            }
        }
    }
}
