import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

// The Settings popup. SideBar owns the instance and exposes it as
// `settingsPanel`, which tests/qml/tst_layout_player.qml and tst_sidebar.qml
// measure. It is clamped to the overlay with 32px on every side so it fits the
// 640x600 window minimum, and the ScrollView takes what is left over.
Popup {
    id: root

    // ── what this panel drives ───────────────────────────────────────────
    // The three context properties are read through `typeof` and kept in
    // properties: a host may install none, and an unqualified name that is not
    // there is a ReferenceError. A test can also inject its own.
    property var langSource:   (typeof i18n        !== "undefined") ? i18n        : null
    property var deviceSource: (typeof player      !== "undefined") ? player      : null
    property var check:        (typeof updateCheck !== "undefined") ? updateCheck : null
    property var downloads:    (typeof downloader  !== "undefined") ? downloader  : null
    property var scrobble:     (typeof listenBrainz !== "undefined") ? listenBrainz : null
    property var lastfm:       (typeof lastFm !== "undefined") ? lastFm : null

    // The effective language, when there is something to ask. Both lists below
    // come back from C++ with translated labels, so they have to be rebuilt
    // when the language changes; a plain binding has nothing to notice.
    readonly property string currentLanguage:
        (langSource && typeof langSource.effectiveLanguage === "string")
            ? langSource.effectiveLanguage : ""

    readonly property var themes: {
        var retranslate = root.currentLanguage   // dependency, see above
        // And again when the colour switch moves: available() answers for the
        // grey ramp in force, and it is an invokable, so nothing else would
        // notice.
        var recolour = prefs.tintedGreys
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

    // Opens at the top every time: the panel is a list of settings, not a
    // document to come back to a place in.
    onAboutToShow: {
        root.reloadAudioDevices()
        scroller.contentItem.contentY = scroller.contentItem.originY
    }

    // And again whenever the set of devices changes while the panel is up.
    // ignoreUnknownSignals because `deviceSource` is injected: a test double
    // has no such signal.
    Connections {
        target: root.deviceSource
        ignoreUnknownSignals: true
        function onAudioDevicesChanged() {
            if (root.visible) root.reloadAudioDevices()
        }
    }

    // The device "System default" currently resolves to, so the sentinel is
    // not an opaque choice. Empty when nothing is flagged.
    readonly property string defaultDeviceLabel: {
        for (var i = 0; i < audioDevices.length; i++)
            if (audioDevices[i].isDefault === true) return audioDevices[i].label
        return ""
    }

    readonly property bool updatesOn: check ? check.enabled === true : false

    // ThemePalette::available() hands over the ground, border and accent
    // alongside {name, label, dark}, so no colour table is repeated here.
    function swatchFor(name) {
        for (var i = 0; i < themes.length; i++)
            if (themes[i].name === name) return themes[i]
        return { bg: Theme.bg, border: Theme.border, accent: Theme.accent }
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

    // Reparented to the window overlay. anchors.centerIn alone only positions
    // against it: `parent` would stay the SideBar, and the clamp below would
    // read the sidebar's width.
    parent: Overlay.overlay
    anchors.centerIn: parent
    width:  Math.min(480, (parent ? parent.width  : 480) - 64)
    height: Math.min(640, (parent ? parent.height : 640) - 64)
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    padding: 0
    // Dims the app behind, as the queue panel does. Fusion's own is faint.
    Overlay.modal: Rectangle { color: Theme.scrim }

    // The sheet the cards sit on, which has to be a step below them or a raised
    // card is invisible.
    background: Rectangle {
        color: Theme.surface
        border.color: Theme.border
        radius: Theme.radiusLarge
    }

    // Margins every section shares, so a section is one ColumnLayout and not a
    // set of four numbers copied six times.
    readonly property int sideMargin: Theme.space5
    // A notch scrolls the system's lines per notch, as other desktop apps do.
    readonly property real wheelStep: Qt.styleHints.wheelScrollLines * Theme.wheelLine

    // The panel's own ground at a given alpha. "transparent" is transparent
    // *black*, which greys a fade out on the two light themes.
    function fadeStop(a) {
        return Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, a)
    }

    // ── the header, which does not scroll ────────────────────────────────
    // Outside the ScrollView, so the heading and the close button stay on
    // screen and the content never passes under them. Anchored, as it is no
    // child of a layout.
    Item {
        id: headerBar
        objectName: "settingsHeader"
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: headerRow.implicitHeight + 32   // 20 above the row, 12 below

        RowLayout {
            id: headerRow
            anchors {
                top: parent.top; left: parent.left; right: parent.right
                topMargin: Theme.space5; leftMargin: root.sideMargin; rightMargin: Theme.space4
            }

            Text {
                text: qsTr("Settings")
                color: Theme.textPrimary
                font.pixelSize: Theme.fontTitle
                font.bold: true
                Layout.fillWidth: true
            }
            Item {
                id: settingsClose
                objectName: "settingsClose"
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                activeFocusOnTab: true
                Keys.onReturnPressed: root.close()
                Keys.onSpacePressed:  root.close()
                Accessible.role: Accessible.Button
                Accessible.name: qsTranslate("NewPlaylistDialog", "Close", "button, closes the dialog")
                Accessible.onPressAction: root.close()
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusMedium
                    color: "transparent"
                    border.width: settingsClose.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                VectorIcon {
                    anchors.centerIn: parent
                    name: "x"
                    color: closeHov.hovered || settingsClose.activeFocus ? Theme.textPrimary : Theme.textSec
                    width: 14; height: 14
                }
                HoverHandler { id: closeHov; cursorShape: Qt.PointingHandCursor }
                TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: root.close() }
            }
        }
    }

    // The content is far taller than the panel, and the default AsNeeded
    // scrollbar draws nothing at rest. Two signals that there is more: a bar
    // that is always there, and a fade at the bottom edge until the end.
    ScrollView {
        id: scroller
        objectName: "settingsScroll"
        anchors {
            top: headerBar.bottom
            left: parent.left; right: parent.right; bottom: parent.bottom
        }
        contentWidth: availableWidth
        // Stated, because a ScrollView on Qt 6.5 works its content height out
        // once, while the panel is built, and does not follow the column after.
        contentHeight: sectionsColumn.implicitHeight
        clip: true

        // The bar gets a gutter of its own rather than being laid over the
        // right edge of the content it describes.
        rightPadding: Theme.space3

        // parent, x, y and height are spelled out because ScrollView only lays
        // out the scrollbar it makes for itself. One handed to it is left at
        // 0,0 with its implicit size.
        ScrollBar.vertical: ScrollBar {
            id: vbar
            objectName: "settingsScrollBar"
            parent: scroller
            x: scroller.width - width
            // Held off the popup's rounded bottom corner, which the
            // ScrollView's rectangular clip does not follow. The top needs
            // none: it is the straight edge under the fixed header.
            y: scroller.topPadding
            height: scroller.availableHeight - Theme.radiusLarge
            policy: ScrollBar.AlwaysOn
            padding: Theme.space1

            contentItem: Rectangle {
                implicitWidth: 4
                radius: width / 2
                color: vbar.pressed || vbar.hovered ? Theme.textSec : Theme.textDim
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.motionFast) } }
            }

            // A groove the full height of the view, so the handle's length
            // says how much of the panel you are looking at.
            background: Rectangle {
                implicitWidth: 10
                color: "transparent"
                Rectangle {
                    anchors.centerIn: parent
                    width: 4
                    height: parent.height
                    radius: width / 2
                    color: Theme.hoverFill
                }
            }
        }

        ColumnLayout {
            id: sectionsColumn
            width: scroller.availableWidth
            spacing: 0

            // A notch moves the panel by wheelStep. Inside the content, so it
            // hears the wheel before the Flickable and after a slider.
            WheelHandler {
                target: null
                onWheel: (event) => {
                    var f = scroller.contentItem
                    var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y
                                                      : event.angleDelta.y / 120 * root.wheelStep
                    if (dy === 0) { event.accepted = false; return }
                    var top = f.originY
                    var end = top + Math.max(0, f.contentHeight - f.height)
                    f.contentY = Math.max(top, Math.min(end, f.contentY - dy))
                }
            }

            // ── account ──────────────────────────────────────────────────
            // Who is logged in, and the way out, which asks first.
            Section {
                heading: qsTr("Account")
                key: "account"

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        // The display name Auth reads with the session, never
                        // an email address; empty until that answer is in.
                        Text {
                            objectName: "settingsAccountName"
                            text: auth.username.length > 0 ? auth.username
                                                           : qsTr("Tidal account")
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontBody; font.bold: true
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                        Text {
                            text: qsTr("Logged in to Tidal")
                            color: Theme.textDim; font.pixelSize: Theme.fontMeta
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                    PillButton {
                        compact: true; accent: false
                        objectName: "settingsLogOut"
                        text: qsTr("Log out")
                        danger: true
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: logOutDialog.ask()
                    }
                }
            }


            // ── appearance ───────────────────────────────────────────────
            Section {
                heading: qsTr("Appearance")
                key: "appearance"

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space2
                    Text {
                        text: qsTr("Theme")
                        color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }

                    // Side by side, not stacked. kSpecs lists the dark palettes
                    // and the light ones in the same hue order, so the two
                    // columns line up row by row as three colour families.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space3
                        ThemeGroup { dark: true;  title: qsTr("Dark", "heading over the dark themes") }
                        ThemeGroup { dark: false; title: qsTr("Light", "heading over the light themes") }
                    }
                }

                // The colour switch, under the grid because it changes what the
                // grid shows. Off, the palettes share one grey ramp per mode
                // and differ only by accent. No theme makes it a no-op.
                RowLayout {
                    objectName: "settingsTintedBlock"
                    Layout.fillWidth: true
                    spacing: Theme.space3

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            objectName: "settingsTintedLabel"
                            text: qsTr("Let the colour in")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsTintedNote"
                            text: qsTr("Each theme tints its greys towards its own colour. Off, all six share one set of greys and differ only by the accent.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsTintedToggle"
                        label: qsTr("Let the colour in")
                        rainbow: true
                        Layout.alignment: Qt.AlignVCenter
                        checked: prefs.tintedGreys
                        onToggled: prefs.tintedGreys = !prefs.tintedGreys
                    }
                }

                // The pure-black switch. Kept but switched off on a light theme,
                // with a note, so a theme change never moves the rows below.
                // Full width, so it is not read as a seventh palette.
                RowLayout {
                    objectName: "settingsOledBlock"
                    Layout.fillWidth: true
                    spacing: Theme.space3

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            text: qsTr("Pure black")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsOledNote"
                            text: ThemePalette.isDark
                                  ? qsTr("Saves power on OLED screens.")
                                  : qsTr("For the dark themes. Saves power on OLED screens.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsOledToggle"
                        label: qsTr("Pure black")
                        Layout.alignment: Qt.AlignVCenter
                        enabled: ThemePalette.isDark
                        opacity: enabled ? 1 : 0.4
                        checked: prefs.oledBlack
                        onToggled: prefs.oledBlack = !prefs.oledBlack
                    }
                }

                // The fullscreen Now Playing background. Shown whether or not
                // the window is fullscreen: it is a preference about a mode you
                // are not in yet.
                RowLayout {
                    objectName: "settingsCoverGradientBlock"
                    Layout.fillWidth: true
                    spacing: Theme.space3

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            objectName: "settingsCoverGradientLabel"
                            text: qsTr("Colour fullscreen Now Playing from the cover")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsCoverGradientNote"
                            text: qsTr("The background takes its colour from the album art. Dimmed to keep the words on top of it readable.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsCoverGradientToggle"
                        label: qsTr("Colour fullscreen Now Playing from the cover")
                        Layout.alignment: Qt.AlignVCenter
                        checked: prefs.coverGradient
                        onToggled: prefs.coverGradient = !prefs.coverGradient
                    }
                }

                // Below Qt 6.8 there is no QAudioBufferOutput, so the row is
                // hidden, not shown disabled.
                RowLayout {
                    objectName: "settingsSpectrumBlock"
                    visible: Spectrum.available
                    Layout.fillWidth: true
                    spacing: Theme.space3

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            objectName: "settingsSpectrumLabel"
                            text: qsTr("Bars follow the music")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsSpectrumNote"
                            // The second sentence is a real limit: a tap
                            // attached while a track plays delivers nothing for
                            // it. tests/tst_spectrum.cpp pins the line.
                            text: qsTr("The little bars on the playing track show a spectrum of what you are hearing, instead of moving on their own. Starts with the next track.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsSpectrumToggle"
                        label: qsTr("Bars follow the music")
                        Layout.alignment: Qt.AlignVCenter
                        checked: prefs.spectrumBars
                        onToggled: prefs.spectrumBars = !prefs.spectrumBars
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    Text {
                        text: qsTr("Language")
                        color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    SettingSelect {
                        objectName: "settingsLanguage"
                        options: root.languageOptions()
                        value: prefs.language
                        onPicked: function (value) { prefs.language = value }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    Text {
                        text: qsTr("Reduce motion")
                        color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    SettingSelect {
                        objectName: "settingsReducedMotion"
                        options: [
                            { value: "system", label: qsTr("As the system says", "reduce motion: follow the desktop setting") },
                            { value: "on",     label: qsTr("On", "reduce motion: always animate less") },
                            { value: "off",    label: qsTr("Off", "reduce motion: always animate") }
                        ]
                        value: prefs.reducedMotion
                        onPicked: function (value) { prefs.reducedMotion = value }
                    }
                }
            }


            // ── window ─────────────────────────────────────────────────────
            Section {
                heading: qsTr("Window", "settings section about the application window")
                key: "window"

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            text: qsTr("Closing the window quits Tidal Wave")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsQuitOnCloseNote"
                            // Left visible with no tray icon, unlike the pure-black
                            // switch above: it starts working when a tray appears,
                            // and a StatusNotifier host can turn up long after login.
                            text: qsTr("While this is off, closing the window hides it and the tray icon brings it back. With no tray icon available, closing always quits.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsQuitOnCloseToggle"
                        label: qsTr("Closing the window quits Tidal Wave")
                        Layout.alignment: Qt.AlignVCenter
                        checked: prefs.quitOnClose
                        onToggled: prefs.quitOnClose = !prefs.quitOnClose
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            text: qsTr("Show a notification when a new track starts")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsTrackNotificationsNote"
                            text: qsTr("Not while the Tidal Wave window is in front.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsTrackNotificationsToggle"
                        Layout.alignment: Qt.AlignVCenter
                        checked: prefs.trackNotifications
                        onToggled: prefs.trackNotifications = !prefs.trackNotifications
                    }
                }
            }


            // ── playback ─────────────────────────────────────────────────
            Section {
                heading: qsTr("Playback")
                key: "playback"

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    Text {
                        text: qsTr("Streaming quality")
                        color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    SettingSelect {
                        objectName: "settingsQuality"
                        options: [
                            { value: "LOW",             label: qsTr("Normal (96 kbps)") },
                            { value: "HIGH",            label: qsTr("High (320 kbps)") },
                            // Tidal's lossless tier is CD quality, 16-bit/44.1kHz.
                            // Named by bit depth so it pairs with the hi-res row
                            // under it.
                            { value: "LOSSLESS",        label: qsTr("Lossless (16-bit)") },
                            { value: "HI_RES_LOSSLESS", label: qsTr("Hi-Res (24-bit)") }
                        ]
                        value: bridge.preferredQuality
                        onPicked: function (value) { bridge.preferredQuality = value }
                    }
                }

                // Where Tidal has a release explicit and clean, which one lists
                // show. Explicit by default, as in Tidal's own apps.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            text: qsTr("Version of records with explicit lyrics")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsPreferredVersionNote"
                            text: qsTr("Search and artist pages show this version where both exist. The album page still lists the other one, and what you saved is always shown.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    SettingSelect {
                        objectName: "settingsPreferredVersion"
                        Layout.alignment: Qt.AlignVCenter
                        options: [
                            { value: "explicit", label: qsTr("Explicit", "the version of a record with its lyrics as recorded") },
                            { value: "clean",    label: qsTr("Clean", "the version of a record with its lyrics edited") }
                        ]
                        value: bridge.preferExplicit ? "explicit" : "clean"
                        onPicked: function (value) { bridge.preferExplicit = value === "explicit" }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            text: qsTr("Normalize loudness")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsNormalizeNote"
                            text: qsTr("Plays every track about as loud as the others, by Tidal's own measure. An album played in its order keeps its own balance.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsNormalizeToggle"
                        Layout.alignment: Qt.AlignVCenter
                        checked: prefs.normalizeLoudness
                        onToggled: prefs.normalizeLoudness = !prefs.normalizeLoudness
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    visible: prefs.crossfadeAvailable
                    Text {
                        text: qsTr("Autoplay similar tracks when the queue ends")
                        color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    Toggle {
                        objectName: "settingsAutoplayToggle"
                        checked: prefs.autoplay
                        onToggled: prefs.autoplay = !prefs.autoplay
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    Text {
                        text: qsTr("Crossfade between tracks")
                        color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    Toggle {
                        objectName: "settingsCrossfadeToggle"
                        checked: prefs.crossfade
                        onToggled: prefs.crossfade = !prefs.crossfade
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    visible: prefs.crossfadeAvailable && prefs.crossfade
                    Text {
                        text: qsTr("Crossfade length")
                        color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    Text {
                        objectName: "settingsCrossfadeValue"
                        text: qsTr("%1 s").arg(prefs.crossfadeSeconds)
                        color: Theme.textSec; font.pixelSize: Theme.fontMeta
                    }
                    Slider {
                        objectName: "settingsCrossfadeSlider"
                        Layout.preferredWidth: 140
                        from: 1; to: 12; stepSize: 1
                        snapMode: Slider.SnapAlways
                        value: prefs.crossfadeSeconds
                        onMoved: prefs.crossfadeSeconds = Math.round(value)
                    }
                }

                // Hidden where there is nothing to choose between, which is
                // every box with no audio backend at all.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    visible: root.audioDevices.length > 0

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            text: qsTr("Audio output")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsAudioDefaultNote"
                            // Which real output the empty-id sentinel is pointing
                            // at right now, so "System default" is not a guess.
                            text: qsTr("The system default is currently %1.").arg(root.defaultDeviceLabel)
                            visible: root.defaultDeviceLabel.length > 0
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    SettingSelect {
                        objectName: "settingsAudioDevice"
                        Layout.alignment: Qt.AlignVCenter
                        options: root.deviceOptions()
                        value: prefs.audioDevice
                        onPicked: function (value) { prefs.audioDevice = value }
                    }
                }

                // Where the save dialog of a track download opens.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    visible: root.downloads !== null

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            text: qsTr("Download folder")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsDownloadFolder"
                            text: root.downloads ? root.downloads.folder : ""
                            color: Theme.textSec; font.pixelSize: Theme.fontMeta
                            elide: Text.ElideMiddle
                            Layout.fillWidth: true
                        }
                        Text {
                            text: qsTr("Each download asks for a file name and format, starting in this folder.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    PillButton {
                        compact: true; accent: false
                        objectName: "settingsDownloadFolderButton"
                        Layout.alignment: Qt.AlignVCenter
                        text: qsTr("Change…", "button that picks another download folder")
                        onClicked: if (root.downloads) root.downloads.chooseFolder()
                    }
                }
            }


            // ── scrobbling ───────────────────────────────────────────────
            // ListenBrainz and Last.fm, each off by default and with its own
            // account and queue; src/scrobble does the sending.
            Section {
                id: scrobbling
                heading: qsTr("Scrobbling")
                key: "scrobbling"

                readonly property var sink: root.scrobble
                readonly property bool on: sink ? sink.enabled === true : false
                readonly property bool linked: sink ? sink.connected === true : false
                readonly property bool refused: sink ? sink.authFailed === true : false
                property bool showToken: false

                function submitToken() {
                    if (root.scrobble && tokenField.text.trim().length > 0) root.scrobble.signIn(tokenField.text)
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            text: qsTr("Send what you play to ListenBrainz")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsScrobbleNote"
                            text: qsTr("A track counts once you have played half of it, or 4 minutes. Its title, artists, album, length and the time you played it go to listenbrainz.org.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsScrobbleToggle"
                        label: qsTr("Send what you play to ListenBrainz")
                        Layout.alignment: Qt.AlignVCenter
                        checked: scrobbling.on
                        onToggled: if (scrobbling.sink) scrobbling.sink.enabled = !scrobbling.on
                    }
                }

                // The account the token belongs to, and the way to let go of it.
                RowLayout {
                    objectName: "settingsScrobbleAccount"
                    visible: scrobbling.on && scrobbling.linked
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            objectName: "settingsScrobbleUser"
                            text: scrobbling.sink ? scrobbling.sink.userName : ""
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontBody; font.bold: true
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                        Text {
                            text: qsTr("Connected to ListenBrainz")
                            color: Theme.textDim; font.pixelSize: Theme.fontMeta
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                    PillButton {
                        compact: true; accent: false
                        objectName: "settingsScrobbleDisconnect"
                        text: qsTr("Disconnect", "button that forgets the ListenBrainz token")
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: if (root.scrobble) root.scrobble.disconnectAccount()
                    }
                }

                // The token, masked unless asked to show it. Again after a
                // refusal, so a new one can be pasted.
                ColumnLayout {
                    objectName: "settingsScrobbleTokenRow"
                    visible: scrobbling.on && (!scrobbling.linked || scrobbling.refused)
                    Layout.fillWidth: true
                    spacing: Theme.space2

                    // A token that was taken is not left in the field.
                    Connections {
                        target: scrobbling.sink
                        ignoreUnknownSignals: true
                        function onAccountChanged() { tokenField.text = "" }
                    }

                    Text {
                        text: qsTr("ListenBrainz user token")
                        color: Theme.textSec; font.pixelSize: Theme.fontMeta
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space2
                        // Drawn like the new-playlist name field, at the
                        // compact pills' height so the row lines up.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 32
                            radius: Theme.radiusLarge
                            color: Theme.surface
                            border.width: 1
                            border.color: tokenField.activeFocus ? Theme.accent : Theme.border
                            TextInput {
                                id: tokenField
                                objectName: "settingsScrobbleToken"
                                anchors.fill: parent
                                anchors.leftMargin: Theme.space3
                                anchors.rightMargin: Theme.space3
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontBody
                                clip: true
                                selectByMouse: true
                                selectionColor: Theme.accent
                                selectedTextColor: Theme.accentInk
                                verticalAlignment: TextInput.AlignVCenter
                                echoMode: scrobbling.showToken ? TextInput.Normal : TextInput.Password
                                readOnly: scrobbling.sink ? scrobbling.sink.checking === true : false
                                activeFocusOnTab: true
                                Accessible.role: Accessible.EditableText
                                Accessible.name: qsTr("ListenBrainz user token")
                                Keys.onReturnPressed: scrobbling.submitToken()
                                Keys.onEnterPressed:  scrobbling.submitToken()
                            }
                        }
                        PillButton {
                            compact: true; accent: false
                            objectName: "settingsScrobbleShowToken"
                            text: scrobbling.showToken
                                ? qsTr("Hide", "button that masks the token again")
                                : qsTr("Show", "button that shows the token in plain text")
                            onClicked: scrobbling.showToken = !scrobbling.showToken
                        }
                        PillButton {
                            compact: true; accent: false
                            objectName: "settingsScrobbleConnect"
                            text: qsTr("Connect", "button that checks the ListenBrainz token")
                            muted: tokenField.text.trim().length === 0
                                   || (scrobbling.sink ? scrobbling.sink.checking === true : false)
                            onClicked: scrobbling.submitToken()
                        }
                    }
                    LinkLine {
                        objectName: "settingsScrobbleTokenLink"
                        text: qsTr("Your token is on your ListenBrainz settings page")
                        onActivated: app.openUrl("https://listenbrainz.org/settings/")
                    }
                }

                // What waits to be sent, and the last thing that went wrong.
                // Listens kept for an account not connected can be let go.
                // Shown only with something in it, so an empty row adds no gap.
                RowLayout {
                    readonly property bool isNote: true
                    visible: scrobbling.on && scrobbling.sink
                             && (scrobbling.sink.statusText.length > 0 || scrobbling.sink.keptCount > 0)
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    Text {
                        objectName: "settingsScrobbleStatus"
                        visible: scrobbling.on && text.length > 0
                        text: scrobbling.sink ? scrobbling.sink.statusText : ""
                        color: scrobbling.refused ? Theme.redText : Theme.textDim
                        font.pixelSize: Theme.fontMeta
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    LinkLine {
                        objectName: "settingsScrobbleDiscard"
                        visible: scrobbling.on && scrobbling.sink ? scrobbling.sink.keptCount > 0 : false
                        text: qsTr("Discard", "link that deletes the listens kept for an account")
                        Layout.fillWidth: false
                        Layout.alignment: Qt.AlignTop
                        onActivated: if (scrobbling.sink) scrobbling.sink.discardKept()
                    }
                }

                // Signed in through the browser: Connect opens Last.fm's page,
                // and "I've allowed access" fetches the session once it is.
                QtObject {
                    id: lastfmBlock
                    readonly property var sink: root.lastfm
                    readonly property bool on: sink ? sink.enabled === true : false
                    readonly property bool linked: sink ? sink.connected === true : false
                    readonly property bool waiting: sink ? sink.awaitingBrowser === true : false
                    readonly property bool busy: sink ? sink.checking === true : false
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            text: qsTr("Send what you play to Last.fm")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsLastfmNote"
                            text: qsTr("A track counts once you have played half of it, or 4 minutes. Its title, first artist, album, length and the time you played it go to last.fm.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsLastfmToggle"
                        label: qsTr("Send what you play to Last.fm")
                        Layout.alignment: Qt.AlignVCenter
                        checked: lastfmBlock.on
                        onToggled: if (lastfmBlock.sink) lastfmBlock.sink.enabled = !lastfmBlock.on
                    }
                }

                RowLayout {
                    objectName: "settingsLastfmAccount"
                    visible: lastfmBlock.on && lastfmBlock.linked
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            objectName: "settingsLastfmUser"
                            text: lastfmBlock.sink ? lastfmBlock.sink.userName : ""
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontBody; font.bold: true
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                        Text {
                            text: qsTr("Connected to Last.fm")
                            color: Theme.textDim; font.pixelSize: Theme.fontMeta
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                    PillButton {
                        compact: true; accent: false
                        objectName: "settingsLastfmDisconnect"
                        text: qsTr("Disconnect", "button that forgets the Last.fm session")
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: if (root.lastfm) root.lastfm.disconnectAccount()
                    }
                }

                // Not connected: the first step, which opens the browser.
                ColumnLayout {
                    visible: lastfmBlock.on && !lastfmBlock.linked && !lastfmBlock.waiting
                    Layout.fillWidth: true
                    spacing: Theme.space2
                    PillButton {
                        compact: true; accent: false
                        objectName: "settingsLastfmConnect"
                        text: qsTr("Connect with Last.fm")
                        muted: lastfmBlock.busy
                        onClicked: if (root.lastfm && !lastfmBlock.busy) root.lastfm.startBrowserSignIn()
                    }
                    Text {
                        text: qsTr("Your browser opens Last.fm, where you allow Tidal Wave to scrobble for you.")
                        color: Theme.textDim; font.pixelSize: Theme.fontMicro
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                }

                // The browser step: back here once access is allowed.
                ColumnLayout {
                    visible: lastfmBlock.on && !lastfmBlock.linked && lastfmBlock.waiting
                    Layout.fillWidth: true
                    spacing: Theme.space2
                    Text {
                        text: qsTr("Allow access on the Last.fm page in your browser, then come back here.")
                        color: Theme.textSec; font.pixelSize: Theme.fontMeta
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    RowLayout {
                        spacing: Theme.space2
                        PillButton {
                            compact: true; accent: false
                            objectName: "settingsLastfmFinish"
                            text: qsTr("I've allowed access")
                            muted: lastfmBlock.busy
                            onClicked: if (root.lastfm && !lastfmBlock.busy) root.lastfm.finishBrowserSignIn()
                        }
                        PillButton {
                            compact: true; accent: false
                            objectName: "settingsLastfmCancel"
                            text: qsTr("Cancel", "button that stops connecting Last.fm")
                            onClicked: if (root.lastfm) root.lastfm.cancelBrowserSignIn()
                        }
                    }
                    LinkLine {
                        objectName: "settingsLastfmPageLink"
                        text: qsTr("Open the Last.fm page again")
                        onActivated: if (lastfmBlock.sink) app.openUrl(lastfmBlock.sink.signInPage)
                    }
                }

                RowLayout {
                    readonly property bool isNote: true
                    visible: lastfmBlock.on && lastfmBlock.sink
                             && (lastfmBlock.sink.statusText.length > 0 || lastfmBlock.sink.keptCount > 0)
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    Text {
                        objectName: "settingsLastfmStatus"
                        visible: lastfmBlock.on && text.length > 0
                        text: lastfmBlock.sink ? lastfmBlock.sink.statusText : ""
                        color: lastfmBlock.sink && lastfmBlock.sink.authFailed === true ? Theme.redText : Theme.textDim
                        font.pixelSize: Theme.fontMeta
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    LinkLine {
                        objectName: "settingsLastfmDiscard"
                        visible: lastfmBlock.on && lastfmBlock.sink ? lastfmBlock.sink.keptCount > 0 : false
                        text: qsTr("Discard", "link that deletes the listens kept for an account")
                        Layout.fillWidth: false
                        Layout.alignment: Qt.AlignTop
                        onActivated: if (lastfmBlock.sink) lastfmBlock.sink.discardKept()
                    }
                }
            }


            // ── performance ──────────────────────────────────────────────
            Section {
                heading: qsTr("Performance")
                key: "performance"

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    Text {
                        text: qsTr("Hardware acceleration")
                        color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    Toggle {
                        objectName: "settingsHwAccelToggle"
                        label: qsTr("Hardware acceleration")
                        // prefs.softwareRendering is the inverse: true means
                        // draw on the CPU.
                        checked: !prefs.softwareRendering
                        onToggled: prefs.softwareRendering = !prefs.softwareRendering
                    }
                }
                // Interface size. Above the restart note because the note
                // applies to this row too: Qt reads the scale factor before the
                // application object exists.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            text: qsTr("Interface size")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        // Only when the scale was worked out here and not taken
                        // from the desktop or the slider: the app is then sized
                        // differently from every other window, which needs a word.
                        Text {
                            objectName: "settingsUiScaleAutoNote"
                            visible: app.scaleWasChosenAutomatically()
                                     && !app.scaleIsEnvironmentOverridden()
                            text: qsTr("Your screen is dense and your desktop did not say so, so Tidal Wave is drawing at %1x on its own. Move the slider if that is not the size you want.").arg(app.activeScaleFactor().toLocaleString(Qt.locale(), 'f', 2))
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsUiScaleEnvNote"
                            visible: app.scaleIsEnvironmentOverridden()
                            text: qsTr("The interface size is being set outside Tidal Wave (QT_SCALE_FACTOR), so this slider does nothing. Unset it to choose the size here.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    // The number, always, so a size can be reported back.
                    Text {
                        objectName: "settingsUiScaleValue"
                        // In the app's own locale, 1,25x in German.
                        text: {
                            var relocalise = root.currentLanguage   // dependency, see above
                            return prefs.uiScale > 0
                                ? prefs.uiScale.toLocaleString(Qt.locale(), 'f', 2) + "x"
                                : qsTr("Automatic", "interface size, the default")
                        }
                        color: Theme.textSec; font.pixelSize: Theme.fontMeta
                        Layout.alignment: Qt.AlignVCenter
                    }
                    Slider {
                        objectName: "settingsUiScaleSlider"
                        Layout.alignment: Qt.AlignVCenter
                        Layout.preferredWidth: 140
                        // Disabled when something outside the process already
                        // set the factor, which the app leaves alone. Visibly
                        // so, with the note below saying why.
                        enabled: !app.scaleIsEnvironmentOverridden()
                        opacity: enabled ? 1.0 : 0.45
                        // One step below the minimum is Automatic, so Auto is a
                        // position on the slider and can be picked again.
                        from: app.minScaleFactor() - app.scaleFactorStep()
                        // Capped by what this screen can actually hold, so the
                        // slider cannot be dragged somewhere that leaves the
                        // window unreachable at next launch.
                        to: app.maxUsableScaleFactor()
                        stepSize: app.scaleFactorStep()
                        snapMode: Slider.SnapAlways
                        value: prefs.uiScale > 0 ? prefs.uiScale : from
                        onMoved: prefs.uiScale =
                            (value < app.minScaleFactor()) ? 0 : value
                    }
                }
                Note {
                    objectName: "settingsRestartNote"
                    // Qt picks the scene graph backend once, at startup, so
                    // this cannot take effect live. Said in the panel, not in a
                    // tooltip.
                    text: qsTr("Takes effect after you restart Tidal Wave.")
                }
            }


            // ── updates ──────────────────────────────────────────────────
            Section {
                heading: qsTr("Updates")
                key: "updates"

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space3
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            text: qsTr("Check for updates automatically")
                            color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            text: qsTr("At most once a day, using the GitHub releases page.")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsUpdateToggle"
                        label: qsTr("Check for updates automatically")
                        Layout.alignment: Qt.AlignVCenter
                        checked: root.updatesOn
                        onToggled: if (root.check) root.check.enabled = !root.check.enabled
                    }
                }
                PillButton {
                    compact: true; accent: false
                    objectName: "settingsCheckNowButton"
                    text: qsTr("Check now")
                    // checkNow() is a no-op while the switch is off, so the
                    // button says as much instead of silently doing nothing.
                    muted: !root.updatesOn
                    onClicked: if (root.check) root.check.checkNow()
                }
            }


            // ── feedback ─────────────────────────────────────────────────
            // Under Updates and above the shortcuts table; tst_settings pins
            // the order. Neither route sends anything: the app builds a URL and
            // hands it to the browser or the mail client.
            Section {
                heading: qsTr("Feedback")
                key: "feedback"

                Text {
                    objectName: "settingsFeedbackNote"
                    text: qsTr("Found a bug, or want to ask for something? Either way works.")
                    color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }

                RowLayout {
                    objectName: "settingsFeedbackRow"
                    readonly property bool isNote: true
                    Layout.fillWidth: true
                    spacing: Theme.space3

                    PillButton {
                        compact: true; accent: false
                        objectName: "settingsIssueButton"
                        // A globe, for the one that opens a web page.
                        // VectorIcon has no GitHub mark and no bug.
                        icon: "globe"
                        text: qsTr("Open a GitHub issue", "button that opens the browser at a new issue")
                        onClicked: app.openUrl(Feedback.issueUrl())
                    }
                    PillButton {
                        compact: true; accent: false
                        objectName: "settingsEmailButton"
                        // The pencil on a sheet: the glyph set has no envelope.
                        icon: "edit"
                        text: qsTr("Send an email", "button that opens the user's mail client")
                        onClicked: app.openUrl(Feedback.mailUrl())
                    }
                    // Keeps the two buttons at their own width, left-aligned,
                    // rather than stretching them across the card.
                    Item { Layout.fillWidth: true }
                }

                Note {
                    objectName: "settingsFeedbackPrefillNote"
                    // The address is printed so the user sees where the mail is
                    // going before the mail client opens. It comes from
                    // Feedback, the one copy of it in the project.
                    text: qsTr("The issue form opens with your version, your system and both Qt versions already in it. The email opens addressed to %1. Neither is sent until you send it.")
                              .arg(Feedback.mailAddress())
                }
            }


            // ── keyboard shortcuts ───────────────────────────────────────
            Section {
                heading: qsTr("Keyboard shortcuts")
                key: "shortcuts"
                spacing: Theme.space2

                // The keys are named by id. The sequences live in the Shortcuts
                // table in src/ui/Shortcuts.cpp, which Main.qml also binds
                // from, and QKeySequence names them for this platform.
                // Keys in one column and what they do in another, each as
                // wide as its widest entry, so the descriptions line up.
                GridLayout {
                    id: shortcutTable
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: Theme.space3
                    rowSpacing: Theme.space2
                    readonly property var rows: [
                        { ids: ["playPause"],                       d: qsTr("Play / pause") },
                        { ids: ["next", "previous"],                d: qsTr("Next / previous track") },
                        { ids: ["seekForward", "seekBack"],         d: qsTr("Seek forward / back 10s") },
                        { ids: ["volumeUp", "volumeDown"],          d: qsTr("Volume up / down") },
                        { ids: ["mute"],                            d: qsTr("Mute") },
                        { ids: ["shuffle"],                         d: qsTr("Toggle shuffle") },
                        { ids: ["repeat"],                          d: qsTr("Cycle repeat mode") },
                        { ids: ["like"],                            d: qsTr("Like or unlike the playing track") },
                        { ids: ["home", "search", "collection"],    d: qsTr("Home / Search / Collection") },
                        { ids: ["nowPlaying"],                      d: qsTr("Now Playing") },
                        { ids: ["find", "findAlt"],                 d: qsTr("Find", "shortcut, puts the keyboard in the search field") },
                        { ids: ["fullScreen"],                      d: qsTr("Fullscreen Now Playing") },
                        { ids: ["queue"],                           d: qsTr("Toggle queue") },
                        { ids: ["back", "escape"],                  d: qsTr("Go back") },
                        { ids: ["settings"],                        d: qsTr("Settings") },
                        { ids: ["undo"],                            d: qsTr("Undo the last change", "shortcut, takes back a like, a removal or a cleared queue") },
                        { ids: ["newPlaylist"],                     d: qsTr("New playlist") },
                        { ids: ["quit"],                            d: qsTr("Quit") }
                    ]

                    Repeater {
                        model: shortcutTable.rows
                        delegate: Item {
                            required property var modelData
                            required property int index
                            Layout.row: index; Layout.column: 0
                            Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                            implicitWidth: keyCap.implicitWidth
                            implicitHeight: keyCap.implicitHeight
                            Rectangle {
                                id: keyCap
                                objectName: "settingsShortcutKey"
                                color: Theme.surface; radius: Theme.radiusSmall
                                border.color: Theme.border
                                implicitWidth: shortcutLabel.implicitWidth + 14
                                implicitHeight: 22
                                width: implicitWidth; height: implicitHeight
                                Text {
                                    id: shortcutLabel; anchors.centerIn: parent
                                    text: modelData.ids.map(function (id) {
                                              return Shortcuts.display(id)
                                          }).join(" / ")
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontMicro
                                    font.family: Shortcuts.monospaceFamily()
                                }
                            }
                        }
                    }
                    Repeater {
                        model: shortcutTable.rows
                        delegate: Text {
                            required property var modelData
                            required property int index
                            Layout.row: index; Layout.column: 1
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            objectName: "settingsShortcutText"
                            text: modelData.d; color: Theme.textSec
                            font.pixelSize: Theme.fontMeta; wrapMode: Text.Wrap
                        }
                    }
                }
            }


            // ── experimental ─────────────────────────────────────────────
            Section {
                heading: qsTr("Experimental")
                key: "experimental"

                LyricsSwitch {
                    objectName: "settingsLrclibRow"
                    toggleName: "settingsLrclibToggle"
                    noteName: "settingsLrclibNote"
                    title: qsTr("Synced lyrics from LRCLIB")
                    note: qsTr("When Tidal has no synced lyrics for the playing track, lrclib.net is asked and gets its artist, title, album and length.")
                    checked: prefs.lyricsLrclib
                    onToggled: prefs.lyricsLrclib = !prefs.lyricsLrclib
                }
                LyricsSwitch {
                    objectName: "settingsOtherLyricsRow"
                    toggleName: "settingsOtherLyricsToggle"
                    noteName: "settingsOtherLyricsNote"
                    title: qsTr("Lyrics from more sites")
                    note: qsTr("Asked after lrclib.net, in this order: music.163.com gets the track's artist and title; lyrics.kugou.com its artist, title and length; genius.com its artist and title. music.163.com and lyrics.kugou.com are servers in China.")
                    checked: prefs.lyricsOtherSites
                    onToggled: prefs.lyricsOtherSites = !prefs.lyricsOtherSites
                }
                LyricsSwitch {
                    objectName: "settingsAutoSyncRow"
                    toggleName: "settingsAutoSyncToggle"
                    noteName: "settingsAutoSyncNote"
                    title: qsTr("Sync plain lyrics automatically")
                    note: qsTr("Lyrics without timings are timed against the track's audio, here on this machine; nothing is sent for it. Timings it is unsure of are not shown, and the ones shown are marked as made here.")
                    checked: prefs.lyricsAutoSync
                    onToggled: prefs.lyricsAutoSync = !prefs.lyricsAutoSync
                }
            }


            // ── privacy ──────────────────────────────────────────────────
            // The one-line summary, and the full notice behind Details. One
            // translatable string per paragraph, so a translator is never
            // handed half-sentences. tst_settings pins the order.
            Section {
                heading: qsTr("Privacy")
                key: "privacy"

                PrivacyLine {
                    text: qsTr("Tidal Wave has no analytics and no telemetry.")
                }
                DetailsToggle {
                    id: privacyDetails
                    objectName: "settingsPrivacyDetails"
                }
                PrivacyLine {
                    visible: privacyDetails.expanded
                    text: qsTr("What leaves this machine: Tidal (auth.tidal.com, api.tidal.com) gets your login, every search you make, and every page and track you open or play, with your access token. resources.tidal.com serves cover art, with no token attached. While casting only, your local network sees mDNS discovery and a short-lived HTTP server that serves the current track to the device; it is not authenticated, so anything on your network can read it while a track is casting. api.github.com gets the update check, at most once a day, with no account data; GitHub sees your IP address and which version you run. Lyrics sites get a track's details as set out below: lrclib.net unless you switch it off, the others only once you switch them on.")
                }
                PrivacyLine {
                    visible: privacyDetails.expanded
                    text: qsTr("What is kept here: your Tidal tokens as plain JSON readable only by you, deleted when you log out; your settings, pinned items and recently played; a cached index of your collection; lyrics found on other sites; and the timings made here for plain lyrics.")
                }
                PrivacyLine {
                    visible: privacyDetails.expanded
                    text: qsTr("Lyrics from other sites, for a track Tidal has no synced lyrics for, with the switches under Experimental. By default only lrclib.net is asked, and it gets the track's artist, title, album and length. With \"Lyrics from more sites\" on, these follow in this order: music.163.com (NetEase Cloud Music) gets the artist and title; lyrics.kugou.com (KuGou) the artist, title and length; genius.com the artist and title. music.163.com and lyrics.kugou.com are servers in China. The asking stops at the first site with synced lyrics. Each site asked sees your IP address and the app's name and version. Sites are asked only while Now Playing is open. What they find is kept on this machine: a track with synced lyrics is not looked up again, and one with plain lyrics or none is asked again after 30 days.")
                }
                PrivacyLine {
                    visible: privacyDetails.expanded
                    text: qsTr("Syncing plain lyrics, on by default, happens on this machine: the track's audio, which the app has downloaded to play it anyway, is analysed here, and nothing about it leaves the machine. The timings are kept next to the lyrics.")
                }
                PrivacyLine {
                    visible: privacyDetails.expanded
                    text: qsTr("Scrobbling, only once you switch it on and connect: api.listenbrainz.org gets the track you start playing and, once it counts, a listen with the time you played it. Both carry the title, artists, album, length, track number, ISRC and Tidal link, the app's name and version, and your ListenBrainz user token, and the site sees your IP address. The token is kept here as plain JSON readable only by you, with the listens not sent yet. Disconnecting, or logging out of Tidal, deletes the token; the listens stay until the same account connects again, and connecting another account or \"Discard\" deletes them.")
                }
                PrivacyLine {
                    visible: privacyDetails.expanded
                    text: qsTr("Last.fm, likewise only once you switch it on and connect: \"Connect with Last.fm\" opens last.fm in your browser, and ws.audioscrobbler.com is asked for a sign-in token and, once you have allowed it, for a session. After that it gets the track you start playing and, once it counts, a scrobble with the time you played it. Both carry the title, the first credited artist, album, length and track number, the app's own Last.fm key and your session key, and the site sees your IP address; the ISRC and the Tidal link do not go to Last.fm. The session key and your Last.fm user name are kept here as plain JSON readable only by you, with the scrobbles not sent yet, and disconnecting or logging out of Tidal deletes the key and keeps the scrobbles as for ListenBrainz.")
                }
                PrivacyLine {
                    visible: privacyDetails.expanded
                    text: qsTr("The update check can be switched off above. Tidal Wave never downloads or installs an update by itself. It only opens the release page in your browser.")
                }
                PrivacyLine {
                    visible: privacyDetails.expanded
                    text: qsTr("Feedback: the two buttons under Feedback above hand a URL to your browser or to your mail client and do nothing else. Tidal Wave opens no connection of its own for them and sends nothing. Nothing leaves this machine until you send it in that program, and then it goes to whichever of the two you picked: a GitHub issue, which is public, or the tidal-wave@linu.li mailbox. What is filled in for you is the app version, the operating system and the two Qt versions - no account data, and nothing about what you have played.")
                }
                PrivacyLine {
                    visible: privacyDetails.expanded
                    text: qsTr("The full version, with the source file behind every line, is at the bottom of the README.")
                }
                LinkLine {
                    objectName: "settingsReadmeLink"
                    readonly property bool isNote: true
                    visible: privacyDetails.expanded
                    text: qsTr("Open the README")
                    onActivated: app.openUrl(Feedback.privacyUrl())
                }
            }

            // ── about ────────────────────────────────────────────────────
            Section {
                heading: qsTr("About", "settings section with the app's name and version")
                key: "about"
                Layout.bottomMargin: Theme.space5

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spaceHalf
                    Text {
                        text: "Tidal Wave"; color: Theme.textPrimary
                        font.pixelSize: Theme.fontBody; font.bold: true
                        elide: Text.ElideRight; Layout.fillWidth: true
                    }
                    Text {
                        objectName: "settingsVersion"
                        // The "v" is written here and not in the
                        // translatable string: it belongs to the version
                        // number, and prefs.appVersion() is bare.
                        readonly property string ver: prefs.appVersion()
                        text: qsTr("Version %1").arg(ver.length > 0 ? "v" + ver : ver)
                        color: Theme.textDim; font.pixelSize: Theme.fontMeta
                        elide: Text.ElideRight; Layout.fillWidth: true
                    }
                }
            }
        }
    }

    // Logging out stops playback and clears the queue, so it is asked first.
    readonly property alias logOutConfirm: logOutDialog
    ConfirmDialog {
        id: logOutDialog
        objectName: "logOutDialog"
        heading: qsTr("Log out?")
        text: qsTr("Playback stops and the queue is cleared. To listen again, log in with your Tidal account.")
        confirmLabel: qsTr("Log out")
        onConfirmed: {
            logOutDialog.close()
            root.close()
            auth.logout()
        }
    }

    // The same fade at the top edge: the scroll area's clip cuts the first
    // visible line in half. It appears only once something has scrolled.
    // Shorter than the bottom fade, as the header already separates.
    Rectangle {
        id: topFade
        objectName: "settingsTopFade"
        anchors { left: parent.left; right: parent.right; top: scroller.top }
        height: 20
        readonly property var flick: scroller.contentItem
        readonly property bool moreAbove: flick ? flick.contentY > 1 : false
        opacity: moreAbove ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.motionFast) } }
        gradient: Gradient {
            GradientStop { position: 0;    color: root.fadeStop(1) }
            GradientStop { position: 0.5;  color: root.fadeStop(0.25) }
            GradientStop { position: 1;    color: root.fadeStop(0) }
        }
    }

    // The bottom edge, faded into the panel's own background, so text running
    // under it reads as cut off. It hides itself at the end of the travel, so
    // "nothing below" and "more below" look different.
    Rectangle {
        id: bottomFade
        objectName: "settingsBottomFade"
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 28
        readonly property var flick: scroller.contentItem
        readonly property bool moreBelow:
            flick ? flick.contentHeight - flick.contentY - flick.height > 1 : false
        opacity: moreBelow ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.motionFast) } }
        // Weighted to the last few pixels: a linear fade over 28px takes a
        // readable line and leaves it half there, which is worse than either
        // showing it or cutting it.
        gradient: Gradient {
            GradientStop { position: 0;    color: root.fadeStop(0) }
            GradientStop { position: 0.5;  color: root.fadeStop(0.25) }
            GradientStop { position: 1;    color: root.fadeStop(1) }
        }
    }

    // ── inline components ────────────────────────────────────────────────

    // A heading over a group of rows, as desktop settings lay them out: no
    // card, a thin rule between rows. A Note under a row belongs to it and
    // gets no rule. Children land in `body` through the default property.
    component Section : ColumnLayout {
        id: sec
        objectName: "settingsSection"
        property string heading: ""
        // A name that is not the heading, so tst_settings can assert the order
        // of the panel without the assertion turning into a translation test.
        property string key: ""
        default property alias cardData: body.data

        Layout.fillWidth: true
        Layout.leftMargin: root.sideMargin
        Layout.rightMargin: root.sideMargin
        // Twice the gap between rows, so groups read as groups, as in GNOME's
        // and macOS's settings. The heading sits nearer its own rows.
        Layout.topMargin: Theme.space8
        Layout.bottomMargin: 0
        spacing: Theme.space2

        data: [
            Text {
                objectName: "settingsSectionHeading"
                text: sec.heading
                color: Theme.textSec
                font.pixelSize: Theme.fontMeta; font.bold: true
                elide: Text.ElideRight
                Layout.fillWidth: true
            },
            Item {
                objectName: "settingsGroup"
                Layout.fillWidth: true
                // Told its height, as an anchored child's size does not reach
                // the layout. The column does not read this back.
                Layout.preferredHeight: body.implicitHeight

                ColumnLayout {
                    id: body
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    spacing: Theme.space4
                }

                // Midway in the gap above every visible row but the first.
                Repeater {
                    model: body.visibleChildren
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        objectName: "settingsRule"
                        visible: index > 0 && modelData.isNote !== true && modelData.height > 0
                        x: 0
                        y: modelData.y - Math.round(body.spacing / 2)
                        width: body.width
                        height: 1
                        color: Theme.border
                    }
                }
            }
        ]
    }

    // A line under a row about that row, or about the group as a whole. No
    // rule above it, so it reads as part of what it follows.
    component Note : Text {
        readonly property bool isNote: true
        color: Theme.textDim
        font.pixelSize: Theme.fontMicro
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }

    // One switch under Experimental: a title, a line on what it sends, a toggle.
    component LyricsSwitch : RowLayout {
        id: lyricsSwitch
        property string title
        property string note
        property string toggleName
        property string noteName
        property bool checked
        signal toggled()
        Layout.fillWidth: true
        spacing: Theme.space3
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.spaceHalf
            Text {
                text: lyricsSwitch.title
                color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                wrapMode: Text.Wrap; Layout.fillWidth: true
            }
            Text {
                objectName: lyricsSwitch.noteName
                text: lyricsSwitch.note
                color: Theme.textDim; font.pixelSize: Theme.fontMicro
                wrapMode: Text.Wrap; Layout.fillWidth: true
            }
        }
        Toggle {
            objectName: lyricsSwitch.toggleName
            label: lyricsSwitch.title
            Layout.alignment: Qt.AlignVCenter
            checked: lyricsSwitch.checked
            onToggled: lyricsSwitch.toggled()
        }
    }

    // One paragraph of the privacy notice. Wraps, never elides: a privacy
    // notice with its tail cut off is worse than none.
    component PrivacyLine : Text {
        objectName: "settingsPrivacyText"
        // One notice, so no rule between its paragraphs.
        readonly property bool isNote: true
        color: Theme.textSec
        font.pixelSize: Theme.fontMeta
        lineHeight: 1.25
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }

    // Shows and hides what follows it. A button that says whether it is
    // open, by its chevron and to a screen reader.
    component DetailsToggle : Item {
        id: dt
        readonly property bool isNote: true
        property bool expanded: false
        signal activated()
        onActivated: dt.expanded = !dt.expanded

        implicitWidth: dtRow.implicitWidth + 2 * Theme.space1
        implicitHeight: 28
        Layout.preferredWidth: implicitWidth
        activeFocusOnTab: true
        Keys.onReturnPressed: dt.activated()
        Keys.onSpacePressed:  dt.activated()
        Accessible.role: Accessible.Button
        Accessible.name: dtLabel.text
        Accessible.checkable: true
        Accessible.checked: dt.expanded
        Accessible.onPressAction: dt.activated()

        Rectangle {
            anchors.fill: parent
            radius: Theme.radiusMedium
            color: dtHov.hovered ? Theme.hoverFill : "transparent"
            border.width: dt.activeFocus ? 2 : 0
            border.color: Theme.accent
        }
        Row {
            id: dtRow
            anchors.verticalCenter: parent.verticalCenter
            x: Theme.space1
            spacing: Theme.space1
            Text {
                id: dtLabel
                text: qsTr("Details", "button that shows the full privacy notice")
                color: Theme.accentText
                font.pixelSize: Theme.fontMeta
                anchors.verticalCenter: parent.verticalCenter
            }
            VectorIcon {
                name: dt.expanded ? "chevron-up" : "chevron-down"
                color: dtLabel.color
                width: 12; height: 12
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        HoverHandler { id: dtHov; cursorShape: Qt.PointingHandCursor }
        TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: dt.activated() }
    }

    // A line of text that opens a page in the browser. An Item around the
    // Text, as PillButton is: a TapHandler declared on a Text itself is
    // never handed the tap inside a Popup.
    component LinkLine : Item {
        id: ll
        property alias text: llText.text
        signal activated()
        implicitHeight: llText.implicitHeight
        implicitWidth: llText.implicitWidth
        Layout.fillWidth: true
        activeFocusOnTab: true
        Keys.onReturnPressed: ll.activated()
        Keys.onSpacePressed:  ll.activated()
        Accessible.role: Accessible.Link
        Accessible.name: llText.text
        Accessible.onPressAction: ll.activated()
        Text {
            id: llText
            width: parent.width
            color: llHov.hovered || ll.activeFocus ? Theme.textPrimary : Theme.accentText
            font.pixelSize: Theme.fontMeta
            font.underline: true
            wrapMode: Text.Wrap
        }
        HoverHandler { id: llHov; cursorShape: Qt.PointingHandCursor }
        TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: ll.activated() }
    }

    // One column of the picker: the dark palettes or the light ones, in table
    // order, so the row a tile sits in is its hue family. Half the panel each:
    // six swatches in one strip would leave the labels nowhere to go.
    component ThemeGroup : ColumnLayout {
        id: group
        objectName: "settingsThemeGroup"
        property bool dark: true
        property string title: ""

        Layout.fillWidth: true
        // Exactly half the row each, whatever the labels measure. Without these
        // two each column takes its own implicit width and the hue rows stop
        // lining up.
        Layout.preferredWidth: 0
        Layout.minimumWidth: 0
        Layout.alignment: Qt.AlignTop
        spacing: Theme.space2

        Text {
            objectName: "settingsThemeGroupLabel"
            text: group.title
            color: Theme.textDim
            font.pixelSize: Theme.fontMicro
            elide: Text.ElideRight
            Layout.fillWidth: true
        }

        Repeater {
            model: root.themesWhere(group.dark)
            delegate: ThemeTile { }
        }

    }

    // One palette, as a swatch plus its name. The swatch is the point: the
    // names alone say nothing about what "Rust" looks like.
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
        Accessible.role: Accessible.RadioButton
        Accessible.name: tile.label
        Accessible.checkable: true
        Accessible.checked: tile.selected
        Accessible.onPressAction: prefs.theme = tile.themeName
        Accessible.onToggleAction: prefs.theme = tile.themeName

        Rectangle {
            anchors.fill: parent
            radius: Theme.radiusMedium
            color: tile.selected   ? Theme.accentSoft
                 : tileHov.hovered ? Theme.hoverFill
                                   : "transparent"
            border.width: tile.activeFocus ? 2 : (tile.selected ? 1 : 0)
            border.color: Theme.accent
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.space2
            anchors.rightMargin: Theme.space2
            spacing: Theme.space2

            // Ground, edge and accent, which is as much of a palette as fits
            // in 34x20 and enough to tell all six apart. Two of the six are
            // warm lights, so the accent dot is doing most of that work.
            Rectangle {
                objectName: "settingsThemeSwatch"
                Layout.preferredWidth: 34
                Layout.preferredHeight: 20
                radius: Theme.radiusSmall
                color: tile.swatch.bg
                border.width: 1
                border.color: tile.swatch.border

                Rectangle {
                    // Named because in the neutral state it is the only thing
                    // telling the six swatches apart, so a test has to be able
                    // to see that it differs while the grounds match.
                    objectName: "settingsThemeSwatchAccent"
                    width: 10; height: 10
                    radius: Theme.radiusFull
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.space1
                    color: tile.swatch.accent
                }
                Rectangle {
                    width: 10; height: 3
                    radius: Theme.radiusSmall
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.space1
                    color: tile.swatch.border
                }
            }

            Text {
                text: tile.label
                color: tile.selected ? Theme.textPrimary : Theme.textSec
                font.pixelSize: Theme.fontMeta
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            VectorIcon {
                name: "check"
                visible: tile.selected
                color: Theme.accentText
                // Layout.*, not width/height: the row would otherwise lay it
                // out at VectorIcon's 24px implicit size.
                Layout.preferredWidth: 14
                Layout.preferredHeight: 14
            }
        }

        HoverHandler { id: tileHov; cursorShape: Qt.PointingHandCursor }
        TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: prefs.theme = tile.themeName }
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
            // A stored value that is no longer offered, such as an unplugged
            // output, falls back to the first entry, as the backend does.
            return i >= 0 ? i : (sel.options.length > 0 ? 0 : -1)
        }
        function syncIndex() { sel.currentIndex = sel.wantedIndex }
        // Deferred, because ComboBox resets currentIndex to 0 from its own
        // handler for the same model change, which can run after this one.
        onWantedIndexChanged:  Qt.callLater(sel.syncIndex)
        onOptionsChanged:      Qt.callLater(sel.syncIndex)
        onCountChanged:        Qt.callLater(sel.syncIndex)
        Component.onCompleted: sel.syncIndex()

        // At the right end of its row, the label taking the rest.
        Layout.preferredWidth: 200
        Layout.minimumWidth: 120
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
                font.pixelSize: Theme.fontMeta
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                color: highlighted ? Qt.tint(Theme.surfaceHigh, Theme.hoverFill) : Theme.surfaceHigh
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
            leftPadding: Theme.space3
            rightPadding: sel.indicator.width + Theme.space4
            text: sel.displayText
            color: Theme.textPrimary
            font.pixelSize: Theme.fontMeta
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
        }

        background: Rectangle {
            implicitWidth: 160
            implicitHeight: 32
            border.color: sel.pressed ? Theme.accent : Theme.border
            border.width: 1
            color: Theme.surfaceHigh
            radius: Theme.radiusMedium
        }

        popup: Popup {
            y: sel.height + 2
            width: sel.width
            implicitHeight: contentItem.implicitHeight
            padding: Theme.spaceHalf
            background: Rectangle {
                border.color: Theme.border
                border.width: 1
                color: Theme.surfaceHigh
                radius: Theme.radiusLarge
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
