import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import TidalWave

// The column headings over a list of TrackRows, laid out from the rows' own
// column metrics so each heading sits over its column at every width. A click
// sorts by that column: ascending, then descending, then the list's own order.
Item {
    id: root
    implicitHeight: 36
    implicitWidth: 404

    // The order the list is shown in. Declared by the page, which reads it
    // for its model, and handed to the header, which only changes it.
    property Sort sort: null
    // The same switches the rows below are given.
    property bool showAlbum: true
    property bool showAdded: false
    property bool showCover: true
    // As on TrackRow, for pages that gate a column against the sidebar.
    readonly property int albumBreakpoint: cols.albumBreakpoint
    readonly property int addedBreakpoint: cols.addedBreakpoint

    // In a list's header item: the list, and how much of its top a bar
    // covers. Once the hero is gone the headings stop under that bar and
    // the rows pass beneath them.
    property Flickable pinIn: null
    property real pinBelow: 0
    readonly property real pinReach: !pinIn || !parent ? -1
        : pinIn.contentY + pinBelow - (parent.y + y)
    readonly property real pinShift: Math.max(0, pinReach)
    // From the moment they reach the bar, so a list left exactly there is
    // pinned too.
    readonly property bool pinned: pinReach > -0.5
    transform: Translate { y: root.pinShift }

    // A sort hands the list a new model, which sends it back to the top.
    // Sorted from the pinned headings, it shows the first rows under them,
    // once the view has reset.
    function sortBy(k) {
        var keep = root.pinned
        root.sort.cycle(k)
        if (keep) Qt.callLater(root.repin)
    }
    function repin() {
        if (pinIn && parent) pinIn.contentY = parent.y + y - pinBelow
    }

    // ── the order a track list is shown in ──────────────────────────────
    // key "" is the list's own order. order() gives each shown row's index
    // in the list: a list from C++ hands out a new object on every read, so
    // indexOf() cannot find a row in it. A filter goes after the sort.
    component Sort : QtObject {
        id: sortState
        property string key: ""
        property bool descending: false

        // Ascending, descending, back to the list's own order.
        function cycle(k) {
            if (key !== k)        { key = k; descending = false }
            else if (!descending) { descending = true }
            else                  { key = ""; descending = false }
        }

        function keyOf(t, k) {
            if (!t) return k === "added" || k === "duration" ? 0 : ""
            switch (k) {
            case "title":    return String(t.title || "").toLowerCase()
            case "album":    return String(t.albumTitle || "").toLowerCase()
            case "added":    return Number(t.addedAt) || 0
            case "duration": return Number(t.duration) || 0
            }
            return ""
        }

        // Stable: equal keys keep the list's order. A row with no date added
        // goes last either way, since it says nothing about when.
        function order(list) {
            var k = sortState.key, desc = sortState.descending
            var n = list ? list.length : 0
            var rows = []
            for (var i = 0; i < n; ++i) {
                var t = list[i]
                rows.push({ t: t, i: i, v: k === "" ? 0 : keyOf(t, k) })
            }
            if (k === "") return rows.map(function (r) { return r.i })
            rows.sort(function (a, b) {
                var c = 0
                if (k === "added" && (a.v === 0) !== (b.v === 0)) return a.v === 0 ? 1 : -1
                if (typeof a.v === "string") c = a.v.localeCompare(b.v)
                else c = a.v - b.v
                if (c === 0 && k === "album")
                    c = (Number(a.t.volumeNumber) || 1) - (Number(b.t.volumeNumber) || 1)
                        || (Number(a.t.trackNumber) || 0) - (Number(b.t.trackNumber) || 0)
                if (desc) c = -c
                return c !== 0 ? c : a.i - b.i
            })
            return rows.map(function (r) { return r.i })
        }
        // The rows in that order; the list itself while unsorted.
        function sorted(list) {
            if (!list || sortState.key === "" || list.length < 2) return list || []
            var rows = []
            for (var i = 0; i < list.length; ++i) rows.push(list[i])
            return order(rows).map(function (j) { return rows[j] })
        }
    }

    TrackRow.Columns {
        id: cols
        rowWidth: root.width
        showAlbum: root.showAlbum
        showAdded: root.showAdded
        showCover: root.showCover
    }

    // One heading. `key` "" is a label only.
    component Heading : Item {
        id: cell
        property string label: ""
        property string key: ""
        property string iconName: ""
        property bool alignRight: false
        property bool centred: false
        readonly property bool sortable: key !== "" && root.sort !== null
        readonly property bool active: sortable && root.sort.key === key
        readonly property string stateText: !active ? ""
            : root.sort.descending ? qsTr("sorted descending", "column heading state for a screen reader")
                                   : qsTr("sorted ascending", "column heading state for a screen reader")

        Layout.fillHeight: true
        implicitWidth: inner.implicitWidth

        activeFocusOnTab: sortable
        Keys.onReturnPressed: root.sortBy(key)
        Keys.onEnterPressed:  root.sortBy(key)
        Keys.onSpacePressed:  root.sortBy(key)
        Accessible.role: Accessible.ColumnHeader
        Accessible.name: label
        Accessible.description: stateText
        Accessible.onPressAction: if (sortable) root.sortBy(key)

        Rectangle {
            anchors.fill: inner
            anchors.margins: -Theme.space1
            radius: Theme.radiusButton
            color: "transparent"
            border.width: cell.activeFocus ? 2 : 0
            border.color: Theme.accent
        }

        Row {
            id: inner
            objectName: "trackListHeadingContent"
            anchors.verticalCenter: parent.verticalCenter
            anchors.left:  cell.alignRight || cell.centred ? undefined : parent.left
            anchors.right: cell.alignRight ? parent.right : undefined
            anchors.horizontalCenter: cell.centred ? parent.horizontalCenter : undefined
            spacing: Theme.space1
            // Before the label on a right-aligned heading, so the label keeps
            // its edge over the column's figures.
            VectorIcon {
                visible: cell.active && cell.alignRight
                anchors.verticalCenter: parent.verticalCenter
                name: root.sort && root.sort.descending ? "chevron-down" : "chevron-up"
                color: Theme.accentText
                width: 12; height: 12
            }
            Text {
                objectName: "trackListHeadingLabel"
                visible: cell.iconName === ""
                anchors.verticalCenter: parent.verticalCenter
                text: cell.label
                color: cell.active || hov.hovered ? Theme.textPrimary : Theme.textSec
                font.pixelSize: Theme.fontMeta
                font.bold: cell.active
                elide: Text.ElideRight
                width: Math.min(implicitWidth, Math.max(0, cell.width - (cell.active ? 16 : 0)))
            }
            VectorIcon {
                visible: cell.iconName !== ""
                anchors.verticalCenter: parent.verticalCenter
                name: cell.iconName
                color: cell.active || hov.hovered ? Theme.textPrimary : Theme.textSec
                width: 14; height: 14
            }
            VectorIcon {
                objectName: "trackListSortArrow"
                visible: cell.active && !cell.alignRight
                anchors.verticalCenter: parent.verticalCenter
                name: root.sort && root.sort.descending ? "chevron-down" : "chevron-up"
                color: Theme.accentText
                width: 12; height: 12
            }
        }

        HoverHandler {
            id: hov
            enabled: cell.sortable
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            enabled: cell.sortable
            onTapped: root.sortBy(cell.key)
        }
        ToolTip.visible: hov.hovered && cell.iconName !== ""
        ToolTip.text: cell.label
        ToolTip.delay: Theme.tooltipDelay
    }

    // Pinned, a ground across the list's width, which takes the pointer so
    // no row under it is hovered or clicked through it.
    Rectangle {
        objectName: "trackListHeaderGround"
        visible: root.pinned
        x: -root.x
        width: root.pinIn ? root.pinIn.width : root.width
        height: root.height
        color: Theme.bg
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
        }
    }

    // The row's own insets: its ground is inset by spaceHalf and its columns
    // by cols.leftInset and cols.rightInset inside that. See TrackRow.
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin:  Theme.spaceHalf + cols.leftInset
        anchors.rightMargin: Theme.spaceHalf + cols.rightInset
        spacing: Theme.space3

        Heading {
            objectName: "trackListHeadingNumber"
            Layout.preferredWidth: cols.numberWidth
            label: qsTr("#", "column heading over the track numbers")
            // Centred, as the numbers are.
            centred: true
        }
        // Over the cover and the title, which read as one column.
        Heading {
            objectName: "trackListHeadingTitle"
            Layout.fillWidth: true
            Layout.preferredWidth: 0
            label: qsTr("Title", "column heading")
            key: "title"
        }
        Heading {
            objectName: "trackListHeadingAlbum"
            visible: cols.albumShown
            Layout.preferredWidth: cols.albumWidth
            label: qsTr("Album", "column heading")
            key: "album"
        }
        Heading {
            objectName: "trackListHeadingAdded"
            visible: cols.addedShown
            Layout.preferredWidth: cols.addedWidth
            label: qsTr("Date added", "column heading")
            key: "added"
        }
        // The heart's, download's and menu's slots have no heading.
        Item { Layout.preferredWidth: cols.heartWidth }
        Item { Layout.preferredWidth: cols.buttonWidth }
        Item { Layout.preferredWidth: cols.buttonWidth }
        Heading {
            objectName: "trackListHeadingLength"
            Layout.preferredWidth: cols.durationWidth
            label: qsTr("Length", "column heading over the track lengths")
            iconName: "clock"
            alignRight: true
            key: "duration"
        }
    }

    Rectangle {
        objectName: "trackListHeaderRule"
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spaceHalf
        anchors.rightMargin: Theme.spaceHalf
        height: 1
        color: Theme.border
    }
}
