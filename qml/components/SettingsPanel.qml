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
        // ...and again when the colour switch moves: available() answers for
        // whichever grey ramp is in force, and it is an invokable rather than a
        // bound property, so without this line the six swatches would keep
        // showing the ramp the panel was opened in. A stale grid is the obvious
        // bug here, and it looks like the switch not working.
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

    onAboutToShow: root.reloadAudioDevices()

    // The device "System default" currently resolves to, so the sentinel is
    // not an opaque choice. Empty when nothing is flagged.
    readonly property string defaultDeviceLabel: {
        for (var i = 0; i < audioDevices.length; i++)
            if (audioDevices[i].isDefault === true) return audioDevices[i].label
        return ""
    }

    readonly property bool updatesOn: check ? check.enabled === true : false

    // ThemePalette::available() now hands over the ground, border and accent
    // alongside {name, label, dark}, so there is nothing to copy. What stood
    // here was a six-row table repeated from kSpecs in ThemePalette.cpp, and
    // its own comment conceded the columns had drifted two accent revisions
    // behind without anyone noticing. tst_settings.qml caught the next drift
    // the day the light palettes were re-separated; this removes the class.
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

    // The sheet the cards sit on, which has to be a step below them or a
    // raised card is invisible. The panel was Theme.surfaceHigh when its
    // sections were separated by rules instead.
    background: Rectangle {
        color: Theme.surface
        border.color: Theme.border
        radius: Theme.radiusPopup
    }

    // Margins every section shares, so a section is one ColumnLayout and not a
    // set of four numbers copied six times.
    readonly property int sideMargin: 20

    // The panel's own ground at a given alpha. "transparent" is transparent
    // *black*, which greys a fade out on the two light themes.
    function fadeStop(a) {
        return Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, a)
    }

    // ── the header, which does not scroll ────────────────────────────────
    //
    // It used to be the first row of the scrolling column, so a few sections
    // down there was nothing saying what the panel was and no visible way out
    // of it: the close button had gone off the top. It sits outside the
    // ScrollView now rather than over it, so the content starts below it and
    // never passes under it. Laid out with anchors because it is no longer a
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
                topMargin: 20; leftMargin: root.sideMargin; rightMargin: 16
            }

            Text {
                text: qsTr("Settings")
                color: Theme.textPrimary
                font.pixelSize: 18
                font.bold: true
                Layout.fillWidth: true
            }
            Item {
                objectName: "settingsClose"
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
    }

    // Roughly 1400px of content in a 640px panel, and the default AsNeeded
    // scrollbar drew nothing at all: Updates, Privacy and Keyboard shortcuts
    // were below the fold with no sign they existed. Two signals now, because
    // one of them has to survive a glance: a bar that is always there, and a
    // fade at the bottom edge that goes away once you reach the end.
    ScrollView {
        id: scroller
        objectName: "settingsScroll"
        anchors {
            top: headerBar.bottom
            left: parent.left; right: parent.right; bottom: parent.bottom
        }
        contentWidth: availableWidth
        clip: true

        // The bar gets a gutter of its own rather than being laid over the
        // right edge of the content it describes.
        rightPadding: 10

        // parent, x, y and height are spelled out because ScrollView only
        // lays out the scrollbar it makes for itself. Hand it one and it is
        // left at 0,0 with its implicit 10x6 size: the first attempt at this
        // put a grey nub in the top-left corner of the panel and no bar.
        ScrollBar.vertical: ScrollBar {
            id: vbar
            objectName: "settingsScrollBar"
            parent: scroller
            x: scroller.width - width
            // Held off the popup's rounded bottom corner, which the
            // ScrollView's rectangular clip does not follow. Only the bottom
            // one now: the top of this gutter is the straight edge under the
            // fixed header, so the bar runs alongside the scrolling area and
            // stops where it stops.
            y: scroller.topPadding
            height: scroller.availableHeight - Theme.radiusPopup
            policy: ScrollBar.AlwaysOn
            padding: 3

            contentItem: Rectangle {
                implicitWidth: 4
                radius: width / 2
                color: vbar.pressed || vbar.hovered ? Theme.textSec : Theme.textDim
                Behavior on color { ColorAnimation { duration: Theme.dur(100) } }
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
            width: scroller.availableWidth
            spacing: 0

            // ── account ──────────────────────────────────────────────────
            Section {
                heading: qsTr("Account")
                key: "account"

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    // No avatar stand-in. It was an accent tile with a note
                    // in it, which stood for neither the account nor the
                    // app, and the sidebar footer has already dropped its
                    // own.
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
                            // The "v" is written here and not in the
                            // translatable string: it belongs to the version
                            // number, not to the sentence, and prefs
                            // .appVersion() is the bare "0.4.0".
                            readonly property string ver: prefs.appVersion()
                            text: qsTr("Version %1").arg(ver.length > 0 ? "v" + ver : ver)
                            color: Theme.textDim; font.pixelSize: 12
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                }
            }


            // ── appearance ───────────────────────────────────────────────
            Section {
                heading: qsTr("Appearance")
                key: "appearance"

                Text {
                    text: qsTr("Theme")
                    color: Theme.textSec; font.pixelSize: 13
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }

                // Side by side, not stacked. kSpecs lists the dark palettes
                // and the light ones in the same hue order, so the two
                // columns line up row by row - Sea beside Sky, Pine beside
                // Sand, Rust beside Clay - and the picker reads as a grid of
                // three colour families rather than as one long list and one
                // short one. The pure-black switch belongs to the left column
                // and lives inside it.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    ThemeGroup { dark: true;  title: qsTr("Dark", "heading over the dark themes") }
                    ThemeGroup { dark: false; title: qsTr("Light", "heading over the light themes") }
                }

                // The colour switch. By default the three dark palettes share
                // one neutral grey ramp and the three light ones share another,
                // so the accent is all that tells the six apart; this turns
                // each palette's own tinted grounds on. It sits directly under
                // the grid because it changes what the grid shows.
                //
                // Always there, unlike the pure-black row below: there is no
                // theme where it does nothing. And its track is a rainbow,
                // because it is the one row in a panel of hardware preferences
                // that is just for fun, and it should look like it.
                RowLayout {
                    objectName: "settingsTintedBlock"
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    spacing: 12

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Text {
                            objectName: "settingsTintedLabel"
                            text: qsTr("Let the colour in")
                            color: Theme.textPrimary; font.pixelSize: 14
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsTintedNote"
                            text: qsTr("Each theme tints its greys towards its own colour. Off, all six share one set of greys and differ only by the accent.")
                            color: Theme.textDim; font.pixelSize: 11
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsTintedToggle"
                        rainbow: true
                        Layout.alignment: Qt.AlignVCenter
                        checked: prefs.tintedGreys
                        onToggled: prefs.tintedGreys = !prefs.tintedGreys
                    }
                }

                // The pure-black switch. Gone rather than greyed out on a
                // light theme: a disabled control invites you to work out how
                // to enable it, and there is nothing to work out here.
                //
                // Across the whole card rather than tucked under the dark
                // column, which was half the width and made the switch look
                // like a seventh dark palette. The toggle is centred against
                // both lines of its label; aligned to the first line it sat
                // visibly high of the block it belongs to.
                RowLayout {
                    objectName: "settingsOledBlock"
                    visible: ThemePalette.isDark
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    spacing: 12

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Text {
                            text: qsTr("Pure black")
                            color: Theme.textPrimary; font.pixelSize: 14
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                        Text {
                            objectName: "settingsOledNote"
                            text: qsTr("Saves power on OLED screens.")
                            color: Theme.textDim; font.pixelSize: 11
                            wrapMode: Text.Wrap; Layout.fillWidth: true
                        }
                    }
                    Toggle {
                        objectName: "settingsOledToggle"
                        Layout.alignment: Qt.AlignVCenter
                        checked: prefs.oledBlack
                        onToggled: prefs.oledBlack = !prefs.oledBlack
                    }
                }

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


            // ── window ─────────────────────────────────────────────────────
            Section {
                heading: qsTr("Window", "settings section about the application window")
                key: "window"

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Text {
                        text: qsTr("Closing the window quits Tidal Wave")
                        color: Theme.textPrimary; font.pixelSize: 14
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    Toggle {
                        objectName: "settingsQuitOnCloseToggle"
                        checked: prefs.quitOnClose
                        onToggled: prefs.quitOnClose = !prefs.quitOnClose
                    }
                }
                Text {
                    objectName: "settingsQuitOnCloseNote"
                    // Left visible with no tray icon rather than hidden, which
                    // is the opposite of what the pure-black switch does above.
                    // That one is dead until the theme changes in this same
                    // panel; this one is remembered and starts working the
                    // moment a tray appears, and a StatusNotifier host can turn
                    // up long after login with no signal for it - so a row that
                    // came and went would be a row nobody could rely on
                    // finding. The sentence below is what the hiding would
                    // otherwise have had to explain.
                    text: qsTr("While this is off, closing the window hides it and the tray icon brings it back. With no tray icon available, closing always quits.")
                    color: Theme.textDim; font.pixelSize: 11
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }
            }


            // ── playback ─────────────────────────────────────────────────
            Section {
                heading: qsTr("Playback")
                key: "playback"

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
                        // Tidal's lossless tier is CD quality, 16-bit/44.1kHz.
                        // Named by its bit depth rather than by its container
                        // so it pairs with the hi-res row under it: the two
                        // differ in depth, not in being a FLAC.
                        { value: "LOSSLESS",        label: qsTr("Lossless (16-bit)") },
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


            // ── performance ──────────────────────────────────────────────
            Section {
                heading: qsTr("Performance")
                key: "performance"

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
                // Interface size. Sits above the restart note deliberately,
                // because the note applies to this row as well: Qt reads the
                // scale factor before the application object exists, so neither
                // of these two can take effect live.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Text {
                        text: qsTr("Interface size")
                        color: Theme.textPrimary; font.pixelSize: 14
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                    // The number, always. "A bit bigger" is not something a
                    // person can report back, and working that out by eye
                    // against a screen cost two wrong guesses already.
                    Text {
                        objectName: "settingsUiScaleValue"
                        text: prefs.uiScale > 0
                              ? prefs.uiScale.toFixed(2) + "x"
                              : qsTr("Automatic", "interface size, the default")
                        color: Theme.textSec; font.pixelSize: 13
                    }
                    Slider {
                        objectName: "settingsUiScaleSlider"
                        Layout.preferredWidth: 140
                        // One step below the minimum is Automatic, so Auto is a
                        // position on the slider rather than a missing value -
                        // somebody who picks 2.00 can still get back to it.
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


            // ── updates ──────────────────────────────────────────────────
            Section {
                heading: qsTr("Updates")
                key: "updates"

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


            // ── keyboard shortcuts ───────────────────────────────────────
            Section {
                heading: qsTr("Keyboard shortcuts")
                key: "shortcuts"
                spacing: 6

                // The keys are named by id, never spelled out here. The
                // sequences live in the Shortcuts table in
                // src/ui/Shortcuts.cpp, which is also where Main.qml binds
                // them from, and the text in the badge is whatever
                // QKeySequence says this platform calls that sequence. Written
                // out as literals - which is what this was - the rows drifted
                // from the bindings with nothing to notice, and they were
                // simply wrong on macOS, where Qt maps Ctrl onto Command and a
                // row reading "Ctrl+Q" was telling the user to press the wrong
                // key. One row may name several ids; they are joined with the
                // same " / " the descriptions use.
                //
                // Only the descriptions are translated now. The key names are
                // not, because QKeySequence::toString already returns them in
                // Qt's own translation of the key, which is better than this
                // app carrying a catalogue entry for every key on the keyboard.
                Repeater {
                    model: [
                        { ids: ["playPause"],                       d: qsTr("Play / Pause") },
                        { ids: ["next", "previous"],                d: qsTr("Next / Previous track") },
                        { ids: ["seekForward", "seekBack"],         d: qsTr("Seek forward / back 10s") },
                        { ids: ["volumeUp", "volumeDown"],          d: qsTr("Volume up / down") },
                        { ids: ["mute"],                            d: qsTr("Mute") },
                        { ids: ["shuffle"],                         d: qsTr("Toggle shuffle") },
                        { ids: ["repeat"],                          d: qsTr("Cycle repeat mode") },
                        { ids: ["home", "search", "collection"],    d: qsTr("Home / Search / Collection") },
                        { ids: ["nowPlaying"],                      d: qsTr("Now Playing") },
                        { ids: ["fullScreen"],                      d: qsTr("Fullscreen Now Playing") },
                        { ids: ["queue"],                           d: qsTr("Toggle queue") },
                        { ids: ["back", "escape"],                  d: qsTr("Go back") },
                        { ids: ["settings"],                        d: qsTr("Settings") }
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
                                text: modelData.ids.map(function (id) {
                                          return Shortcuts.display(id)
                                      }).join(" / ")
                                color: Theme.textPrimary
                                font.pixelSize: 11
                                font.family: Shortcuts.monospaceFamily()
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


            // ── privacy ──────────────────────────────────────────────────
            // Last on purpose. This is a wall of prose and reads as the end of
            // the panel, while the shortcuts above it are a reference table
            // people open Settings to look things up in; underneath this they
            // were not found. tst_settings pins the order.
            //
            // The text the user approved, one qsTr() per paragraph. Split any
            // finer and a translator would be handed half-sentences to join
            // back together in a language whose word order is not ours.
            Section {
                heading: qsTr("Privacy")
                key: "privacy"

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

            // ── signing out ────────────────────────────────────
            //
            // Not in the Account card, where it sat next to the version
            // number: signing out has nothing to do with which build is
            // installed, and a destructive action one line under a number
            // people lean in to read is the wrong place for it. It has no
            // heading and no card either, because it is not a setting; it is
            // the end of the panel, which is where a sign-out lives in every
            // other app. Full width and alone below the last section, so it
            // cannot be hit by accident on the way past.
            PanelButton {
                objectName: "settingsLogOut"
                label: qsTr("Log out")
                danger: true
                Layout.fillWidth: true
                Layout.leftMargin: root.sideMargin
                Layout.rightMargin: root.sideMargin
                Layout.topMargin: 28
                Layout.bottomMargin: 20
                onActivated: { root.close(); auth.logout() }
            }
        }
    }

    // The same treatment at the top edge, and for the same reason rather
    // than for symmetry: the scroll area's clip cuts the first visible line
    // in half, and a half line reads as a broken word, not as "there is more
    // above". A hairline under the header would have drawn a rule between
    // two things that are already a surface apart, and said nothing about
    // whether anything had scrolled; this appears only once something has.
    // Shorter than the bottom fade, because the header is doing half the
    // work of separating already.
    Rectangle {
        id: topFade
        objectName: "settingsTopFade"
        anchors { left: parent.left; right: parent.right; top: scroller.top }
        height: 20
        readonly property var flick: scroller.contentItem
        readonly property bool moreAbove: flick ? flick.contentY > 1 : false
        opacity: moreAbove ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(120) } }
        gradient: Gradient {
            GradientStop { position: 0;    color: root.fadeStop(1) }
            GradientStop { position: 0.5;  color: root.fadeStop(0.25) }
            GradientStop { position: 1;    color: root.fadeStop(0) }
        }
    }

    // The bottom edge of a scrollable panel, faded into the panel's own
    // background: text that runs under it reads as cut off rather than as the
    // end of the list. It hides itself at the end of the travel, so "nothing
    // below" and "more below" look different.
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
        Behavior on opacity { NumberAnimation { duration: Theme.dur(120) } }
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

    // A heading over a card of controls.
    //
    // The sections used to be separated by hairlines, which read as leftover
    // dividers rather than as structure and get lost in a 1400px scroll. The
    // controls are on their own raised panel now and the heading sits outside
    // it, so a section is a shape you can see at a glance from any scroll
    // position, and the gap between two of them does the separating.
    //
    // Children declared on an instance land inside the card. That needs the
    // default property redirected, which in turn is why the heading and the
    // card itself are assigned to `data` by hand: anything declared the
    // ordinary way here would go through the redirect and into its own card.
    component Section : ColumnLayout {
        id: sec
        objectName: "settingsSection"
        property string heading: ""
        // A name that is not the heading, so tst_settings can assert the order
        // of the panel without the assertion turning into a translation test.
        property string key: ""
        default property alias cardData: body.data

        // The card's own inset. Its children are already 20px in from the
        // panel edge, so this is air inside the card and not a second margin.
        readonly property int cardPad: 14

        Layout.fillWidth: true
        Layout.leftMargin: root.sideMargin
        Layout.rightMargin: root.sideMargin
        Layout.topMargin: 18
        Layout.bottomMargin: 0
        spacing: 8

        data: [
            Text {
                text: sec.heading
                color: Theme.textDim
                font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                elide: Text.ElideRight
                Layout.fillWidth: true
            },
            Rectangle {
                objectName: "settingsCard"
                Layout.fillWidth: true
                // A Layout gives an anchored child its own size, so the card
                // has to be told how tall its contents are. The inner column
                // measures its children without reference to its own height,
                // so this cannot feed back.
                Layout.preferredHeight: body.implicitHeight + 2 * sec.cardPad
                color: Theme.surfaceHigh
                radius: Theme.radiusCard
                border.width: 1
                border.color: Theme.border

                ColumnLayout {
                    id: body
                    anchors.fill: parent
                    anchors.margins: sec.cardPad
                    spacing: 10
                }
            }
        ]
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
            color: btn.danger ? (btnHov.hovered ? Theme.redInk : Theme.red)
                              : Theme.textPrimary
            font.pixelSize: 12
        }
        HoverHandler { id: btnHov; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: btn.activated() }
    }

    // An on/off switch. Qt Quick Controls' Switch brings its own style with
    // it, which is not this one.
    //
    // `rainbow` is for the colour switch above, the one row here that is not a
    // preference about hardware: with it set, a checked track is a turning
    // rainbow instead of a flat accent fill. Deliberately cheap - one animated
    // number feeding seven gradient stops on a 38x22 rectangle, with no shader,
    // no layer and no ShaderEffect - because this is a widget in a panel people
    // leave open, not a one-off flourish. Off, and on every other Toggle, there
    // is nothing animated and nothing extra painted.
    component Toggle : Item {
        id: tg
        property bool checked: false
        property bool rainbow: false
        signal toggled()

        // How far round the wheel the track has turned, 0 to 1. Properties
        // rather than locals so tests/qml/tst_settings.qml can read whether the
        // thing is moving instead of having to time it.
        property real rainbowPhase: 0
        readonly property bool rainbowRunning: rainbowTurn.running

        implicitWidth: 38
        implicitHeight: 22
        activeFocusOnTab: true
        Keys.onReturnPressed: tg.toggled()
        Keys.onSpacePressed:  tg.toggled()

        // Seven stops, a sixth of the wheel apart, so the first and the last
        // land on the same hue and one turn joins up with no seam. Lightness
        // 0.55 rather than 0.5 because the knob riding on top is accentInk,
        // which is white in all six palettes, and a darker yellow read as a
        // smudge under it.
        function rainbowStop(i) {
            return Qt.hsla((tg.rainbowPhase + i / 6) % 1, 0.9, 0.55, 1)
        }

        NumberAnimation on rainbowPhase {
            id: rainbowTurn
            from: 0; to: 1
            duration: Theme.dur(6000)
            // X6. A zero duration against Animation.Infinite is a spin loop, so
            // reduced motion takes one instant turn and leaves the rainbow
            // sitting still: the colour is what the switch is saying, the
            // motion is only how it says it, so the colour has to stay.
            loops: Theme.reduceMotion ? 1 : Animation.Infinite
            // Nothing turns while the panel is shut - a Popup's contents report
            // visible false - and nothing turns on a plain Toggle.
            running: tg.rainbow && tg.checked && tg.visible
        }

        Rectangle {
            id: track
            anchors.fill: parent
            radius: Theme.radiusChip
            color: tg.checked ? Theme.accent : Theme.surface
            border.width: tg.activeFocus ? 2 : 1
            border.color: tg.activeFocus ? Theme.accent
                        : tg.checked     ? Theme.accent : Theme.border

            // Inside the border rather than over it, so the focus ring is still
            // a ring and not a rainbow with a gap in it.
            Rectangle {
                objectName: "toggleRainbow"
                visible: tg.rainbow && tg.checked
                anchors.fill: parent
                anchors.margins: track.border.width
                radius: Theme.radiusChip
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0;       color: tg.rainbowStop(0) }
                    GradientStop { position: 1 / 6;   color: tg.rainbowStop(1) }
                    GradientStop { position: 2 / 6;   color: tg.rainbowStop(2) }
                    GradientStop { position: 3 / 6;   color: tg.rainbowStop(3) }
                    GradientStop { position: 4 / 6;   color: tg.rainbowStop(4) }
                    GradientStop { position: 5 / 6;   color: tg.rainbowStop(5) }
                    GradientStop { position: 1;       color: tg.rainbowStop(6) }
                }
            }

            Rectangle {
                width: parent.height - 6
                height: width
                radius: Theme.radiusChip
                y: 3
                x: tg.checked ? parent.width - width - 3 : 3
                color: tg.checked ? Theme.accentInk : Theme.textSec
                Behavior on x {
                    NumberAnimation { duration: Theme.dur(120); easing.type: Easing.OutCubic }
                }
            }
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: tg.toggled() }
    }

    // One column of the picker: the dark palettes or the light ones, in table
    // order, so the row a tile sits in is its hue family. Half the panel each,
    // because six swatches in one strip would be 50px apiece at 480px and the
    // labels would have nowhere to go. The pure-black switch used to live at
    // the foot of this column; it is a full-width row under both of them now.
    component ThemeGroup : ColumnLayout {
        id: group
        objectName: "settingsThemeGroup"
        property bool dark: true
        property string title: ""

        Layout.fillWidth: true
        // Exactly half the row each, whatever the labels measure. Without
        // these two the wrapping note under the switch sets a minimum width
        // for the left column, the right one gets what is left, and the hue
        // rows stop lining up.
        Layout.preferredWidth: 0
        Layout.minimumWidth: 0
        Layout.alignment: Qt.AlignTop
        spacing: 6

        Text {
            objectName: "settingsThemeGroupLabel"
            text: group.title
            color: Theme.textDim
            font.pixelSize: 11
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
            // in 34x20 and enough to tell all six apart. Two of the six are
            // warm lights, so the accent dot is doing most of that work.
            Rectangle {
                objectName: "settingsThemeSwatch"
                Layout.preferredWidth: 34
                Layout.preferredHeight: 20
                radius: Theme.radiusArt
                color: tile.swatch.bg
                border.width: 1
                border.color: tile.swatch.border

                Rectangle {
                    // Named because in the neutral state it is the only thing
                    // telling the six swatches apart, so a test has to be able
                    // to see that it differs while the grounds match.
                    objectName: "settingsThemeSwatchAccent"
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
                    color: tile.swatch.border
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
