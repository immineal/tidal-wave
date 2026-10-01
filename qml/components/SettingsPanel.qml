import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

// The Settings popup, lifted out of SideBar.qml (which was 1173 lines with it
// inside) now that it has a picker for every 0.4.0 feature that shipped
// without one.
//
// SideBar still owns the instance and still exposes it as `settingsPanel`, so
// tests/qml/tst_layout_player.qml and tst_sidebar.qml measure the same object
// they always did. The clamping below is theirs: a fixed 480x640 did not fit
// the 640x600 window minimum, so the popup is clamped to the overlay with 32px
// on every side (SPEC L10) and the ScrollView takes whatever is left over.
Popup {
    id: root

    // ── what this panel drives ───────────────────────────────────────────
    //
    // The three context properties below are read through `typeof` and kept in
    // a property rather than used inline. tests/TestStubs.h installs no `i18n`
    // at all, and an unqualified name that is not there is a ReferenceError,
    // not undefined - which tst_firstrun.cpp, failing on any QML warning,
    // would report. Main.qml guards UpdatePrompt's `check` for the same
    // reason. Holding them in properties also lets a test inject its own.
    property var langSource:   (typeof i18n        !== "undefined") ? i18n        : null
    property var deviceSource: (typeof player      !== "undefined") ? player      : null
    property var check:        (typeof updateCheck !== "undefined") ? updateCheck : null

    // The effective language, when there is something to ask. Both lists below
    // come back from C++ with translated labels, so they have to be rebuilt
    // when the language changes; a plain binding has nothing to notice.
    readonly property string currentLanguage:
        (langSource && typeof langSource.effectiveLanguage === "string")
            ? langSource.effectiveLanguage : ""

    readonly property var themes: {
        var retranslate = root.currentLanguage   // dependency, see above
        return ThemePalette.available()
    }

    readonly property var languages: {
        var retranslate = root.currentLanguage   // dependency, see above
        if (!langSource || typeof langSource.availableLanguages !== "function") return []
        return langSource.availableLanguages()
    }

    // Audio devices are hot-pluggable, so this is re-read every time the panel
    // opens rather than bound once. Player hands back "System default" first
    // with an empty id, then the real outputs.
    property var audioDevices: []

    function reloadAudioDevices() {
        root.audioDevices =
            (deviceSource && typeof deviceSource.availableAudioDevices === "function")
                ? deviceSource.availableAudioDevices() : []
    }

    onAboutToShow: root.reloadAudioDevices()

    // The device "System default" currently resolves to, so the sentinel is
    // not an opaque choice. Empty when nothing is flagged.
    readonly property string defaultDeviceLabel: {
        for (var i = 0; i < audioDevices.length; i++)
            if (audioDevices[i].isDefault === true) return audioDevices[i].label
        return ""
    }

    readonly property bool updatesOn: check ? check.enabled === true : false

    // ThemePalette::available() hands over {name, label, dark} and no colours,
    // and theme::palette() is not reachable from QML, so the three each swatch
    // draws are repeated from the kSpecs table in src/ui/ThemePalette.cpp:
    // ground, border, accent. tst_settings.qml asserts this table and
    // ThemePalette.available() cover the same six names, which is the drift
    // that can actually happen.
    readonly property var swatches: ({
        "midnight": { bg: "#0A0A0A", edge: "#2A2A2A", accent: "#00B2F8" },
        "forest":   { bg: "#0B0F0C", edge: "#29332B", accent: "#3DD68C" },
        "ember":    { bg: "#100D0C", edge: "#332C28", accent: "#FF7A45" },
        "deep":     { bg: "#000000", edge: "#24242B", accent: "#22D3EE" },
        "daylight": { bg: "#FFFFFF", edge: "#CFD9E2", accent: "#0A6FC4" },
        "paper":    { bg: "#FAF7F0", edge: "#CBC0A6", accent: "#2F6F4E" }
    })

    function swatchFor(name) {
        return swatches[name] || { bg: Theme.bg, edge: Theme.border, accent: Theme.accent }
    }

    function themesWhere(dark) {
        var out = []
        for (var i = 0; i < themes.length; i++)
            if ((themes[i].dark === true) === dark) out.push(themes[i])
        return out
    }

    function indexOfValue(options, value) {
        for (var i = 0; i < options.length; i++)
            if (options[i].value === value) return i
        return -1
    }

    function languageOptions() {
        var out = []
        for (var i = 0; i < languages.length; i++)
            out.push({ value: languages[i].code, label: languages[i].label })
        return out
    }

    function deviceOptions() {
        var out = []
        for (var i = 0; i < audioDevices.length; i++)
            out.push({ value: audioDevices[i].id, label: audioDevices[i].label })
        return out
    }

    // ── the popup itself ─────────────────────────────────────────────────

    // Reparented to the window overlay, not left on the sidebar that declares
    // it. anchors.centerIn alone only *positions* against the overlay: `parent`
    // stays the SideBar, and the clamp below was reading a 220px sidebar, so
    // the whole panel came up 156px wide.
    parent: Overlay.overlay
    anchors.centerIn: parent
    width:  Math.min(480, (parent ? parent.width  : 480) - 64)
    height: Math.min(640, (parent ? parent.height : 640) - 64)
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    padding: 0

    background: Rectangle {
        color: Theme.surfaceHigh
        border.color: Theme.border
        radius: Theme.radiusPopup
    }

    // Margins every section shares, so a section is one ColumnLayout and not a
    // set of four numbers copied six times.
    readonly property int sideMargin: 20

    ScrollView {
        id: scroller
        objectName: "settingsScroll"
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true

        ColumnLayout {
            width: scroller.availableWidth
            spacing: 0

            // ── header ───────────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: root.sideMargin
                Layout.rightMargin: 16
                Layout.topMargin: 20
                Layout.bottomMargin: 12

                Text {
                    text: qsTr("Settings")
                    color: Theme.textPrimary
                    font.pixelSize: 18
                    font.bold: true
                    Layout.fillWidth: true
                }
                Item {
                    // A 26px target around a 14px glyph. The MouseArea this
                    // replaces reached its size with anchors.margins: -6, so
                    // it hung outside its own parent.
                    Layout.preferredWidth: 26
                    Layout.preferredHeight: 26
                    VectorIcon {
                        anchors.centerIn: parent
                        name: "x"
                        color: closeHov.hovered ? Theme.textPrimary : Theme.textSec
                        width: 14; height: 14
                        strokeWidth: 1.8
                    }
                    HoverHandler { id: closeHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.close() }
                }
            }

            Separator {}

            // ── account ──────────────────────────────────────────────────
            Section {
                heading: qsTr("Account")

                RowLayout {
                    Layout.fillWidth: true
                    Rectangle {
                        width: 36; height: 36; radius: Theme.radiusChip; color: Theme.accent
                        Text {
                            anchors.centerIn: parent; text: "♪"
                            color: Theme.onAccent; font.pixelSize: 16
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            text: "Tidal Wave"; color: Theme.textPrimary
                            font.pixelSize: 14; font.bold: true
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsVersion"
                            text: qsTr("Version %1").arg(prefs.appVersion())
                            color: Theme.textDim; font.pixelSize: 12
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                    PanelButton {
                        label: qsTr("Log out")
                        danger: true
                        onActivated: { root.close(); auth.logout() }
                    }
                }
            }

            Separator { inset: true }

            // ── appearance ───────────────────────────────────────────────
            Section {
                heading: qsTr("Appearance")

                Text {
                    text: qsTr("Theme")
                    color: Theme.textSec; font.pixelSize: 13
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }

                ThemeGroup { dark: true;  title: qsTr("Dark", "heading over the dark themes") }
                ThemeGroup { dark: false; title: qsTr("Light", "heading over the light themes") }

                Text {
                    text: qsTr("Language")
                    color: Theme.textSec; font.pixelSize: 13
                    Layout.topMargin: 4
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }
                SettingSelect {
                    objectName: "settingsLanguage"
                    options: root.languageOptions()
                    value: prefs.language
                    onPicked: function (value) { prefs.language = value }
                }
            }

            Separator { inset: true }

            // ── playback ─────────────────────────────────────────────────
            Section {
                heading: qsTr("Playback")

                Text {
                    text: qsTr("Streaming quality")
                    color: Theme.textSec; font.pixelSize: 13
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }
                SettingSelect {
                    objectName: "settingsQuality"
                    options: [
                        { value: "LOW",             label: qsTr("Normal (96 kbps)") },
                        { value: "HIGH",            label: qsTr("High (320 kbps)") },
                        { value: "LOSSLESS",        label: qsTr("Lossless (FLAC)") },
                        { value: "HI_RES_LOSSLESS", label: qsTr("Hi-Res (24-bit)") }
                    ]
                    value: bridge.preferredQuality
                    onPicked: function (value) { bridge.preferredQuality = value }
                }

                // Hidden where there is nothing to choose between, which is
                // every box with no audio backend at all.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    spacing: 5
                    visible: root.audioDevices.length > 0

                    Text {
                        text: qsTr("Audio output")
                        color: Theme.textSec; font.pixelSize: 13
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    SettingSelect {
                        objectName: "settingsAudioDevice"
                        options: root.deviceOptions()
                        value: prefs.audioDevice
                        onPicked: function (value) { prefs.audioDevice = value }
                    }
                    Text {
                        objectName: "settingsAudioDefaultNote"
                        // Which real output the empty-id sentinel is pointing
                        // at right now, so "System default" is not a guess.
                        text: qsTr("The system default is currently %1.").arg(root.defaultDeviceLabel)
                        visible: root.defaultDeviceLabel.length > 0
                        color: Theme.textDim; font.pixelSize: 11
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                }
            }

            Separator { inset: true }

            // ── performance ──────────────────────────────────────────────
            Section {
                heading: qsTr("Performance")

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Text {
                        text: qsTr("Hardware acceleration")
                        color: Theme.textPrimary; font.pixelSize: 14
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    Toggle {
                        objectName: "settingsHwAccelToggle"
                        // prefs.softwareRendering is the inverse: true means
                        // draw on the CPU.
                        checked: !prefs.softwareRendering
                        onToggled: prefs.softwareRendering = !prefs.softwareRendering
                    }
                }
                Text {
                    objectName: "settingsRestartNote"
                    // Qt picks the scene graph backend once, at startup, so
                    // this one cannot take effect live. In the panel rather
                    // than in a tooltip: nobody hovers a setting to find out
                    // that it did nothing.
                    text: qsTr("Takes effect after you restart Tidal Wave.")
                    color: Theme.textDim; font.pixelSize: 11
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }
            }

            Separator { inset: true }

            // ── updates ──────────────────────────────────────────────────
            Section {
                heading: qsTr("Updates")

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Text {
                        text: qsTr("Check for updates automatically")
                        color: Theme.textPrimary; font.pixelSize: 14
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    Toggle {
                        objectName: "settingsUpdateToggle"
                        checked: root.updatesOn
                        onToggled: if (root.check) root.check.enabled = !root.check.enabled
                    }
                }
                Text {
                    text: qsTr("At most once a day, using the GitHub releases page.")
                    color: Theme.textDim; font.pixelSize: 11
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }
                PanelButton {
                    objectName: "settingsCheckNowButton"
                    label: qsTr("Check now")
                    // checkNow() is a no-op while the switch is off, so the
                    // button says as much instead of silently doing nothing.
                    muted: !root.updatesOn
                    onActivated: if (root.check) root.check.checkNow()
                }
            }

            Separator { inset: true }

            // ── privacy ──────────────────────────────────────────────────
            // The text the user approved, one qsTr() per paragraph. Split any
            // finer and a translator would be handed half-sentences to join
            // back together in a language whose word order is not ours.
            Section {
                heading: qsTr("Privacy")

                PrivacyLine {
                    text: qsTr("Tidal Wave has no analytics and no telemetry.")
                }
                PrivacyLine {
                    text: qsTr("What leaves this machine: Tidal (auth.tidal.com, api.tidal.com) gets your login, every search you make, and every page and track you open or play, with your access token. resources.tidal.com serves cover art, with no token attached. While casting only, your local network sees mDNS discovery and a short-lived HTTP server that serves the current track to the device; it is not authenticated, so anything on your network can read it while a track is casting. api.github.com gets the update check, at most once a day, with no account data; GitHub sees your IP address and which version you run.")
                }
                PrivacyLine {
                    text: qsTr("What is kept here: your Tidal tokens as plain JSON readable only by you, deleted when you log out; your settings, pinned items and recently played; and a cached index of your library.")
                }
                PrivacyLine {
                    text: qsTr("The update check can be switched off above. Tidal Wave never downloads or installs an update by itself. It only opens the release page in your browser.")
                }
                PrivacyLine {
                    text: qsTr("The full version, with the source file behind every line, is at the bottom of the README.")
                }
            }

            Separator { inset: true }

            // ── keyboard shortcuts ───────────────────────────────────────
            Section {
                heading: qsTr("Keyboard shortcuts")
                spacing: 6
                Layout.bottomMargin: 20

                Repeater {
                    model: [
                        { k: qsTr("Space", "keyboard key"),      d: qsTr("Play / Pause") },
                        { k: qsTr("Ctrl+Right / Left"),          d: qsTr("Next / Previous track") },
                        { k: qsTr("Right / Left", "arrow keys"), d: qsTr("Seek forward / back 10s") },
                        { k: qsTr("Up / Down", "arrow keys"),    d: qsTr("Volume up / down") },
                        { k: qsTr("Ctrl+M"),                     d: qsTr("Mute") },
                        { k: qsTr("Ctrl+S"),                     d: qsTr("Toggle shuffle") },
                        { k: qsTr("Ctrl+R"),                     d: qsTr("Cycle repeat mode") },
                        { k: qsTr("Ctrl+1 / 2 / 3"),             d: qsTr("Home / Search / Collection") },
                        { k: qsTr("Ctrl+N"),                     d: qsTr("Now Playing") },
                        { k: qsTr("Ctrl+Q"),                     d: qsTr("Toggle queue") },
                        { k: qsTr("Alt+Left / Esc"),             d: qsTr("Go back") },
                        { k: qsTr("Ctrl+,"),                     d: qsTr("Settings") }
                    ]
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 12
                        Rectangle {
                            color: Theme.surface; radius: Theme.radiusBadge
                            border.color: Theme.border
                            implicitWidth: shortcutLabel.implicitWidth + 14
                            implicitHeight: 22
                            Text {
                                id: shortcutLabel; anchors.centerIn: parent
                                text: modelData.k; color: Theme.textPrimary
                                font.pixelSize: 11; font.family: "monospace"
                            }
                        }
                        Text {
                            text: modelData.d; color: Theme.textSec
                            font.pixelSize: 12; wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                    }
                }
            }
        }
    }

    // ── inline components ────────────────────────────────────────────────

    // One hairline between sections. `inset` keeps it off the popup's own
    // edge, which only the one under the header wants to touch.
    component Separator : Rectangle {
        property bool inset: false
        color: Theme.border
        height: 1
        Layout.fillWidth: true
        Layout.leftMargin:  inset ? root.sideMargin : 0
        Layout.rightMargin: inset ? root.sideMargin : 0
    }

    // A titled block. Children declared on an instance land in the column
    // under the heading, because ColumnLayout's default property is its data.
    component Section : ColumnLayout {
        id: sec
        property string heading: ""
        Layout.fillWidth: true
        Layout.leftMargin: root.sideMargin
        Layout.rightMargin: root.sideMargin
        Layout.topMargin: 14
        Layout.bottomMargin: 4
        spacing: 10

        Text {
            text: sec.heading
            color: Theme.textDim
            font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
    }

    // One paragraph of the privacy notice. Wraps, never elides: a privacy
    // notice with its tail cut off is worse than none.
    component PrivacyLine : Text {
        objectName: "settingsPrivacyText"
        color: Theme.textSec
        font.pixelSize: 12
        lineHeight: 1.25
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }

    // A flat dialog-sized button with a focus ring. PillButton is the hero-page
    // pill and is sized for that job.
    component PanelButton : Item {
        id: btn
        property string label: ""
        property bool danger: false
        // Still clickable, drawn as "this will not do much right now".
        property bool muted: false
        signal activated()

        implicitWidth:  btnLabel.implicitWidth + 20
        implicitHeight: 30
        Layout.preferredWidth: implicitWidth
        activeFocusOnTab: true
        opacity: muted ? 0.5 : 1
        Keys.onReturnPressed: btn.activated()
        Keys.onSpacePressed:  btn.activated()

        Rectangle {
            anchors.fill: parent
            radius: Theme.radiusButton
            color: btn.danger && btnHov.hovered ? Theme.red
                 : btnHov.hovered               ? Theme.surfaceHov
                                                : Theme.surface
            border.width: btn.activeFocus ? 2 : 1
            border.color: btn.activeFocus ? Theme.accent
                        : btn.danger && btnHov.hovered ? Theme.red
                                                       : Theme.border
        }
        Text {
            id: btnLabel
            anchors.centerIn: parent
            text: btn.label
            color: btn.danger ? (btnHov.hovered ? Theme.onRed : Theme.red)
                              : Theme.textPrimary
            font.pixelSize: 12
        }
        HoverHandler { id: btnHov; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: btn.activated() }
    }

    // An on/off switch. Qt Quick Controls' Switch brings its own style with
    // it, which is not this one.
    component Toggle : Item {
        id: tg
        property bool checked: false
        signal toggled()

        implicitWidth: 38
        implicitHeight: 22
        activeFocusOnTab: true
        Keys.onReturnPressed: tg.toggled()
        Keys.onSpacePressed:  tg.toggled()

        Rectangle {
            anchors.fill: parent
            radius: Theme.radiusChip
            color: tg.checked ? Theme.accent : Theme.surface
            border.width: tg.activeFocus ? 2 : 1
            border.color: tg.activeFocus ? Theme.accent
                        : tg.checked     ? Theme.accent : Theme.border

            Rectangle {
                width: parent.height - 6
                height: width
                radius: Theme.radiusChip
                y: 3
                x: tg.checked ? parent.width - width - 3 : 3
                color: tg.checked ? Theme.onAccent : Theme.textSec
                Behavior on x {
                    NumberAnimation { duration: Theme.dur(120); easing.type: Easing.OutCubic }
                }
            }
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: tg.toggled() }
    }

    // The dark half or the light half of the palette list. Two columns, each
    // half the panel: six swatches in one strip would be 50px each at 480px,
    // and the labels would have nowhere to go.
    component ThemeGroup : ColumnLayout {
        id: group
        objectName: "settingsThemeGroup"
        property bool dark: true
        property string title: ""

        Layout.fillWidth: true
        spacing: 6

        Text {
            objectName: "settingsThemeGroupLabel"
            text: group.title
            color: Theme.textDim
            font.pixelSize: 11
            elide: Text.ElideRight
            Layout.fillWidth: true
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 8
            rowSpacing: 6

            Repeater {
                model: root.themesWhere(group.dark)
                delegate: ThemeTile { }
            }
        }
    }

    // One palette, as a swatch plus its name. The swatch is the point: the
    // names alone say nothing about what "Ember" looks like.
    component ThemeTile : Item {
        id: tile
        objectName: "settingsThemeOption"

        required property var modelData

        readonly property string themeName: modelData.name
        readonly property string label:     modelData.label
        readonly property bool   themeDark: modelData.dark === true
        readonly property bool   selected:  prefs.theme === tile.themeName
        readonly property var    swatch:    root.swatchFor(tile.themeName)

        Layout.fillWidth: true
        Layout.preferredHeight: 34
        activeFocusOnTab: true
        Keys.onReturnPressed: prefs.theme = tile.themeName
        Keys.onSpacePressed:  prefs.theme = tile.themeName

        Rectangle {
            anchors.fill: parent
            radius: Theme.radiusRow
            color: tile.selected   ? Theme.accentSoft
                 : tileHov.hovered ? Theme.hoverFill
                                   : "transparent"
            border.width: tile.activeFocus ? 2 : (tile.selected ? 1 : 0)
            border.color: Theme.accent
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            spacing: 8

            // Ground, edge and accent, which is as much of a palette as fits
            // in 34x20 and enough to tell all six apart.
            Rectangle {
                objectName: "settingsThemeSwatch"
                Layout.preferredWidth: 34
                Layout.preferredHeight: 20
                radius: Theme.radiusArt
                color: tile.swatch.bg
                border.width: 1
                border.color: tile.swatch.edge

                Rectangle {
                    width: 10; height: 10
                    radius: Theme.radiusChip
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    color: tile.swatch.accent
                }
                Rectangle {
                    width: 10; height: 3
                    radius: Theme.radiusBadge
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 4
                    color: tile.swatch.edge
                }
            }

            Text {
                text: tile.label
                color: tile.selected ? Theme.textPrimary : Theme.textSec
                font.pixelSize: 13
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            VectorIcon {
                name: "check"
                visible: tile.selected
                color: Theme.accent
                // Layout.*, not width/height: the row would otherwise lay it
                // out at VectorIcon's 24px implicit size.
                Layout.preferredWidth: 14
                Layout.preferredHeight: 14
                strokeWidth: 2
            }
        }

        HoverHandler { id: tileHov; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: prefs.theme = tile.themeName }
    }

    // The panel's one drop-down, styled once instead of per picker. `options`
    // is [{value, label}]; `picked` carries the value, because the index is
    // meaningless to everything that stores one of these.
    component SettingSelect : ComboBox {
        id: sel
        property var options: []
        // The value that should be showing. ComboBox assigns currentIndex
        // itself whenever the model changes, which destroys any binding put
        // on it, so the index is pushed back in from here instead.
        property string value: ""
        signal picked(string value)

        readonly property int wantedIndex: {
            var i = root.indexOfValue(sel.options, sel.value)
            // A stored value that is no longer offered - an output that was
            // unplugged - falls back to the first entry, which is what the
            // backend resolves it to anyway.
            return i >= 0 ? i : (sel.options.length > 0 ? 0 : -1)
        }
        function syncIndex() { sel.currentIndex = sel.wantedIndex }
        // Deferred, because ComboBox resets currentIndex to 0 from its own
        // handler for the same model change - after this one, if the index is
        // written straight away.
        onWantedIndexChanged:  Qt.callLater(sel.syncIndex)
        onOptionsChanged:      Qt.callLater(sel.syncIndex)
        onCountChanged:        Qt.callLater(sel.syncIndex)
        Component.onCompleted: sel.syncIndex()

        Layout.fillWidth: true
        model: options
        // Explicit rather than textRole, so the delegate and the field agree
        // whatever the model is made of.
        displayText: (currentIndex >= 0 && currentIndex < options.length)
                     ? options[currentIndex].label : ""
        onActivated: function (index) {
            if (index >= 0 && index < sel.options.length)
                sel.picked(sel.options[index].value)
        }

        delegate: ItemDelegate {
            required property var modelData
            required property int index
            width: sel.width
            highlighted: sel.highlightedIndex === index
            contentItem: Text {
                text: modelData.label
                color: highlighted ? Theme.textPrimary : Theme.textSec
                font.pixelSize: 13
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                color: highlighted ? Theme.surfaceHov : Theme.surfaceHigh
            }
        }

        indicator: Canvas {
            id: arrow
            x: sel.width - width - 10
            y: sel.topPadding + (sel.availableHeight - height) / 2
            width: 12
            height: 8
            contextType: "2d"

            // The arrow is painted, so it has to be repainted when the palette
            // changes under it.
            readonly property color ink: Theme.textSec
            onInkChanged: arrow.requestPaint()

            Connections {
                target: sel.popup
                function onVisibleChanged() { arrow.requestPaint() }
            }

            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.moveTo(0, 0)
                ctx.lineTo(width, 0)
                ctx.lineTo(width / 2, height)
                ctx.closePath()
                ctx.fillStyle = arrow.ink
                ctx.fill()
            }
        }

        contentItem: Text {
            leftPadding: 10
            rightPadding: sel.indicator.width + 15
            text: sel.displayText
            color: Theme.textPrimary
            font.pixelSize: 13
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
        }

        background: Rectangle {
            implicitWidth: 160
            implicitHeight: 32
            border.color: sel.pressed ? Theme.accent : Theme.border
            border.width: 1
            color: Theme.surfaceHigh
            radius: Theme.radiusButton
        }

        popup: Popup {
            y: sel.height + 2
            width: sel.width
            implicitHeight: contentItem.implicitHeight
            padding: 1
            background: Rectangle {
                border.color: Theme.border
                border.width: 1
                color: Theme.surfaceHigh
                radius: Theme.radiusPopup
            }
            contentItem: ListView {
                clip: true
                implicitHeight: contentHeight
                model: sel.popup.visible ? sel.delegateModel : null
                currentIndex: sel.highlightedIndex
                ScrollIndicator.vertical: ScrollIndicator { }
            }
        }
    }
}
