import QtQuick
import TidalWave

// Edits.duplicateQuestion, put to the user: a track to add is in the playlist
// already. One track: add it anyway or not. Several: all of them, only the
// new ones, or none. Main.qml holds the one instance.
ConfirmDialog {
    id: root
    objectName: "duplicateAddDialog"

    readonly property var question: Edits.duplicateQuestion
    readonly property bool several: !!question && question.total > 1
    // Some of several are new, so there are two ways to add.
    readonly property bool mixed: !!question && !!question.fresh

    // Answered, so closing afterwards is no cancel.
    property bool answered: false

    danger: false
    heading: !question ? ""
           : mixed ? qsTr("Some are already in “%1”", "dialog heading, some of the tracks to add are in the playlist").arg(question.title)
                   : qsTr("Already in “%1”", "dialog heading, the track to add is in the playlist").arg(question.title)
    text: !question ? ""
        : mixed ? qsTr("%Ln of these %1 tracks are in it already.", "", question.dupes).arg(question.total)
        : several ? qsTr("All %Ln tracks are in it already. Add them anyway?", "", question.total)
                  : qsTr("Add anyway?", "the track is in the playlist already")
    confirmLabel: mixed ? qsTr("Add all", "adds every track, the ones in the playlist again too")
                        : qsTr("Add anyway", "adds a track the playlist holds already")
    altLabel: mixed ? qsTr("Add new ones", "adds only the tracks the playlist does not hold") : ""

    onQuestionChanged: {
        if (question) { root.answered = false; root.ask() }
        else if (root.opened) { root.answered = true; root.close() }
    }
    onConfirmed:    { root.answered = true; root.close(); Edits.answerDuplicates("all") }
    onAltConfirmed: { root.answered = true; root.close(); Edits.answerDuplicates("new") }
    onClosed: if (!root.answered) Edits.answerDuplicates("cancel")
}
