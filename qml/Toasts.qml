pragma Singleton
import QtQuick

// The one toast: what just happened, and Undo where it can be undone. Any
// component says it here; ToastHost draws it. A new message replaces the one
// on screen, so a late Undo never acts on something the user no longer sees.
QtObject {
    id: toasts

    property string text: ""
    // The action's label, empty for a plain confirmation.
    property string actionLabel: ""
    property var    action: null
    property bool   shown: false
    // Bumped by every show(), so the host restarts its clock for a repeat.
    property int    serial: 0

    // How long it stays: long enough to read, longer when it offers Undo.
    // Not Theme.dur(): a dwell is not an animation and must not drop to 0.
    // Writable so a test need not wait them out.
    property int plainMs: 4000
    property int actionMs: 8000

    function show(message, label, fn) {
        toasts.text = message || ""
        toasts.actionLabel = (fn && label) ? label : ""
        toasts.action = (fn && label) ? fn : null
        toasts.serial++
        toasts.shown = toasts.text.length > 0
    }

    // A confirmation whose action is Undo.
    function undoable(message, fn) {
        show(message, qsTr("Undo", "button on a confirmation, takes back what was just done"), fn)
    }

    function dismiss() {
        toasts.shown = false
        toasts.action = null
        toasts.actionLabel = ""
    }

    function runAction() {
        var fn = toasts.action
        dismiss()
        if (fn) fn()
    }
}
