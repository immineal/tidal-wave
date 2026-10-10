import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property var track: player.currentTrack  // QVariantMap
    property bool hasTrack: track && track.id > 0
    property bool isLiked: false
    property bool showLyrics: false
    // The other thing the hero slot can be. The two are tabs over one slot:
    // opening either closes the other.
    property bool showCredits: false
    // Whichever of them is open, if either. Questions about the shape of the
    // slot ask this; questions about the words ask showLyrics.
    readonly property bool showPanel: showLyrics || showCredits
    // Download state for the current track: "idle" | "busy" | "done" | "error"
    property string dlState: "idle"

    // ─── Responsive layout ─────────────────────────────
    // The page margin and the gap between the cover and the text column, named
    // because all the width arithmetic below leans on them.
    readonly property int pageMargin: 48
    readonly property int columnGap:  64

    readonly property real contentWidth: Math.max(0, width - 2 * pageMargin)

    // The transport row needs 344px (248 of buttons and six 16px gaps), and
    // side by side the text column gets too little of the content width for
    // that. Below this page width the cover moves above the text.
    readonly property int  stackBreakpoint: 1000
    readonly property bool stacked: width < stackBreakpoint

    // The vertical gap between the two blocks once they are stacked, which is
    // also what stackedCoverRoom has to leave room for.
    readonly property int stackGap: 32

    // ─── Crossing the breakpoint ───────────────────────
    // How stacked the page is: 0 with the cover beside the text, 1 with it
    // above. Everything that moves in the rearrangement is lerped off this one
    // clock. An open panel is the stacked arrangement at every width.
    readonly property bool stackedLayout: stacked || showPanel
    property real stackness: stackedLayout ? 1 : 0

    Behavior on stackness {
        NumberAnimation { duration: Theme.dur(170); easing.type: Easing.OutCubic }
    }

    // ─── Artwork or lyrics ─────────────────────────────
    // How far the hero slot is towards being a page of lyrics: 0 artwork, 1
    // lyrics. The second clock, at the same duration as `stackness`, so the two
    // move as one when opening the lyrics also stacks the page.
    property real lyricsness: showLyrics ? 1 : 0

    Behavior on lyricsness {
        NumberAnimation { duration: Theme.dur(170); easing.type: Easing.OutCubic }
    }

    // The same for the credits, and read the same way: 0 artwork, 1 credits.
    property real creditsness: showCredits ? 1 : 0

    Behavior on creditsness {
        NumberAnimation { duration: Theme.dur(170); easing.type: Easing.OutCubic }
    }

    // How far the slot is towards being a panel, whichever one. The max, not
    // the sum: a swap runs both clocks in opposite directions, and with the
    // same easing this never dips below 0.5, so the slot keeps its panel shape.
    readonly property real panelness: Math.max(lyricsness, creditsness)

    // A quantity on its way from the side-by-side value to the stacked one. All
    // geometry below is written this way, so at rest it is one of the two.
    function blend(side, stackedValue) {
        return side + (stackedValue - side) * root.stackness
    }

    // The same, between the artwork's shape and a panel's.
    function lblend(art, panel) {
        return art + (panel - art) * root.panelness
    }

    // ─── The reading view ──────────────────────────────────────────────
    // Fullscreen with a panel open. It has no control of its own: it is what
    // fullscreen shows once a panel is open. The chrome row and the transport
    // stay where they are and never fade.
    readonly property bool readingView: fullScreen && showPanel

    // The third clock, at the same duration: entering fullscreen with a panel
    // already open moves neither stackness nor lyricsness.
    property real readingness: readingView ? 1 : 0

    Behavior on readingness {
        NumberAnimation { duration: Theme.dur(170); easing.type: Easing.OutCubic }
    }

    // The same, between the windowed panel's value and the reading view's.
    function rblend(panelValue, reading) {
        return panelValue + (reading - panelValue) * root.readingness
    }

    // Stacked, the cover takes the height the rest of the page leaves it,
    // capped at 420 and at the content width and floored at 180. Side by side
    // it keeps 45% of the content width.
    readonly property real sideCoverSize:    Math.min(contentWidth * 0.45, 420)
    readonly property real stackedCoverSize: Math.min(contentWidth, 420,
                                                      Math.max(180, stackedCoverRoom))
    readonly property real coverSize: blend(sideCoverSize, stackedCoverSize)

    // ─── What a panel asks for instead ─────────────────
    // The size the lines are set in: 14 docked, twice that in the reading view,
    // where they are read from further back. Lerped, so it grows with the slot.
    readonly property int  lyricsSize:  14
    readonly property int  readingSize: 28
    readonly property real lyricLineSize: rblend(lyricsSize, readingSize)

    // A measure, not a square: 640px is about 90 characters at 14px, past the
    // longest lyric line, and wider is not more readable. Held in characters,
    // so the reading size gets twice the width.
    readonly property real lyricsMeasure: 640 * lyricLineSize / lyricsSize
    readonly property real lyricsWidth: Math.min(contentWidth, lyricsMeasure)

    // The height cap: 560 docked, so a very tall window does not hand the panel
    // more column than the eye can follow. Reading, the room is the limit.
    readonly property real lyricsCap: rblend(560, Math.max(560, stackedCoverRoom))

    // The height the page can spare, floored at 280. Never shorter than the
    // artwork it replaces, so opening a panel only makes the slot bigger and
    // the crossfade can leave the cover at its own size.
    readonly property real lyricsHeight:
        Math.max(coverSize, 280, Math.min(lyricsCap, stackedCoverRoom))

    // The slot both live in: square for the artwork, a column for a panel.
    readonly property real slotWidth:  lblend(coverSize, lyricsWidth)
    readonly property real slotHeight: lblend(coverSize, lyricsHeight)

    // What is left once the margins, the header row, the two 32px gaps and the
    // text column have taken their height. The settled stacked height: a
    // moving cover would feed the animation back into itself.
    readonly property real stackedCoverRoom:
        height - 2 * pageMargin - headerRow.height - 32 - stackGap
        - infoColumn.implicitHeight

    // What the title and transport column gets. infoX + infoWidth is the
    // content width at every value of stackness, so the column's right edge
    // stays on the page margin throughout the move.
    readonly property real sideInfoWidth:
        Math.max(0, contentWidth - sideCoverSize - columnGap)
    readonly property real infoWidth: blend(sideInfoWidth, contentWidth)

    // ─── Where the two blocks are ──────────────────────
    // The text column's height is set by its content and not by the layout,
    // which keeps the arithmetic below closed-form.
    readonly property real infoHeight: infoColumn.implicitHeight
    // The settled height the pair takes side by side, and the centre line both
    // are held on there. `lblend` and not `slotHeight`: this must not be one of
    // the things the stack animation is moving.
    readonly property real sideBodyHeight:
        Math.max(lblend(sideCoverSize, lyricsHeight), infoHeight)

    readonly property real coverX: Math.round(blend(0, (contentWidth - slotWidth) / 2))
    readonly property real coverY: Math.round(blend((sideBodyHeight - slotHeight) / 2, 0))
    readonly property real infoX:  Math.round(blend(contentWidth - sideInfoWidth, 0))
    readonly property real infoY:  Math.round(blend((sideBodyHeight - infoHeight) / 2,
                                                    slotHeight + stackGap))

    // What the two blocks reach, which is what the page reserves and can be
    // scrolled by. Derived from the positions above: halfway through the move
    // the page is taller than the average of the two end heights.
    readonly property real bodyHeight:
        Math.max(coverY + slotHeight, infoY + infoHeight)

    // 248px of buttons and six gaps. Where 344 will not fit, the gaps are 8.
    readonly property int transportFixedWidth: 248
    readonly property int transportGaps: 6
    readonly property int transportSpacing:
        gapFor(infoWidth)
    readonly property int transportMinWidth:
        transportFixedWidth + transportGaps * transportSpacing

    // The row's own gap, asked of a width. `transportSpacing` asks it of the
    // width the row has this frame. The volume's arithmetic below asks it of
    // the settled width, so its threshold holds still during a restack.
    function gapFor(w) {
        return w >= transportFixedWidth + transportGaps * 16 ? 16 : 8
    }

    // ─── Where the volume lives ────────────────────────
    // A short cluster with two homes: the end of the transport row or a row of
    // its own. The speaker sits over the percentage and the slider is a flyout
    // over both. The picker stays beside them: three high outgrows the row.
    readonly property int volumeIconSize:       18
    readonly property int volumePercentWidth:   36
    readonly property int volumeOutputWidth:    32
    readonly property int volumeClusterSpacing: 10
    // The gap between speaker and readout, paid as the readout's top padding so
    // the hover target has no dead strip. The bar's extra lift on the same 4 is
    // deliberate: tst_output_picker.qml requires both to render alike.
    readonly property int volumeStackGap:        4
    // As wide as the wider of the two it holds, which is the readout. The
    // speaker is centred in it, and so is the flyout above it.
    readonly property int volumeStackWidth:
        Math.max(volumeIconSize, volumePercentWidth)
    readonly property int volumeClusterWidth:
        volumeStackWidth + volumeOutputWidth + volumeClusterSpacing

    // The slider the speaker reveals. It is drawn in a popup, never in the
    // layout, and upright, so these are a length and a thickness.
    readonly property int volumeSliderLength:    110
    readonly property int volumeSliderThickness: 20

    // What the transport row needs to carry the cluster: the buttons, the
    // cluster twice (a counterweight after shuffle keeps play centred) and
    // eight gaps. A narrower column gives the volume a row of its own.
    readonly property int transportWithVolumeWidth:
        transportFixedWidth + 2 * volumeClusterWidth
        + (transportGaps + 2) * gapFor(settledInfoWidth)

    // Asked of the width the column will settle at. infoWidth is lerped across
    // the breakpoint, so reading it here would change the volume's home, and
    // with it the column's height, in the middle of the move.
    readonly property real settledInfoWidth:
        stackedLayout ? contentWidth : sideInfoWidth
    readonly property bool volumeInTransport:
        settledInfoWidth >= transportWithVolumeWidth

    // Whether the row can hold it this frame. The lerp passes through widths
    // narrower than either end, and a Layout will not shrink below what its
    // children ask for, so the cluster waits for the width before it draws.
    readonly property bool volumeClusterFits:
        volumeInTransport && infoWidth >= transportWithVolumeWidth

    // ─── Fullscreen ────────────────────────────────────
    // The window owns its own visibility, so this page can only ask. Both reads
    // survive a test host that has neither: missing reads as not fullscreen.
    readonly property bool fullScreen:
        Window.window ? Window.window.fullScreen === true : false

    function toggleFullScreen() {
        if (Window.window && Window.window.toggleFullScreen)
            Window.window.toggleFullScreen()
    }

    // ─── The cover-derived background ──────────────────
    // On by default, and fullscreen only. Read defensively: a test host may
    // install no `prefs` and an older settings file lacks the key: both are on.
    readonly property bool coverGradient:
        (typeof prefs === "undefined" || prefs === null
         || prefs.coverGradient === undefined) ? true
                                               : prefs.coverGradient === true

    // Sleep Timer Delegation (mapping properties to Window.window to persist in background)
    readonly property bool   sleepTimerActive:      Window.window ? Window.window.sleepTimerActive : false
    readonly property bool   sleepStopAtEndOfTrack: Window.window ? Window.window.sleepStopAtEndOfTrack : false
    readonly property int    sleepTimeLeft:         Window.window ? Window.window.sleepTimeLeft : 0
    readonly property bool   sleepIsFading:         Window.window ? Window.window.sleepIsFading : false
    property bool            sleepFadeOut:          Window.window ? Window.window.sleepFadeOut : true

    function startSleepTimer(minutes, stopAtEnd) {
        if (Window.window) Window.window.startSleepTimer(minutes, stopAtEnd)
    }
    function cancelSleepTimer() {
        if (Window.window) Window.window.cancelSleepTimer()
    }
    function formatSleepTime(seconds) {
        return Window.window ? Window.window.formatSleepTime(seconds) : ""
    }

    // Lyrics state: "none", "loading", "ready", "unavailable"
    property string lyricsState: "none"
    property var    lyricsData:  []   // [{ms, text}] for timed; [{ms: 0, text}] for plain
    property bool   lyricsIsTimed: false
    property int    currentLyricLine: -1
    property bool   userScrolled: false
    property bool   ignoreLyricsSync: false

    // The band at the bottom of the open panel that belongs to the chips.
    // Nothing scrolls through it, so a tap on a chip cannot also hit a lyric.
    readonly property int lyricsFooterRoom: 48
    // The same at the top. A ListView will not scroll past -topMargin, so
    // without this band line 0 could only sit flush against the top.
    readonly property int lyricsHeaderRoom: 56

    // Puts the line being sung back in the middle. Called on every resize of
    // the list as well as from the sync timer: a ListView keeps its scroll
    // offset, not its centred item.
    function recentreLyrics() {
        if (!root.showLyrics || root.userScrolled) return
        if (root.currentLyricLine < 0 || root.lyricsData.length === 0) return
        // Instant: a re-wrap is a correction, and a correction that travels
        // reads as the words drifting on their own.
        centreLyricLine(root.currentLyricLine, false)
    }

    // Puts one line in the middle of the panel, animated when the song moved
    // on. Lines wrap to different heights, so the target is read back from
    // positionViewAtIndex and then travelled to.
    NumberAnimation {
        id: lyricsScroll
        target: lyricsView
        property: "contentY"
        duration: Theme.dur(260)
        easing.type: Easing.OutCubic
    }

    function centreLyricLine(line, animated) {
        if (line < 0 || line >= root.lyricsData.length) return
        lyricsScroll.stop()
        var was = lyricsView.contentY
        lyricsView.positionViewAtIndex(line, ListView.Center)
        if (!animated) return
        var want = lyricsView.contentY
        if (want === was) return
        lyricsView.contentY = was
        lyricsScroll.from = was
        lyricsScroll.to   = want
        lyricsScroll.start()
    }

    // Opening the panel resizes before there is a list to position, so it asks
    // again once there is. The one-slot rule is held here and not in the chips,
    // so every way of opening a panel gets it.
    onShowLyricsChanged: {
        if (showLyrics) {
            showCredits = false
            Qt.callLater(root.recentreLyrics)
        }
    }
    onShowCreditsChanged: if (showCredits) showLyrics = false

    // The lyrics chip hides itself when there are none, which would leave an
    // open panel with nothing to close it, so the slot follows the words. It
    // does not re-open on the next track that has some.
    onLyricsStateChanged: if (lyricsState === "unavailable") showLyrics = false

    Timer {
        id: ignoreSyncTimer
        interval: 1000
        running: false
        repeat: false
        onTriggered: root.ignoreLyricsSync = false
    }

    function parseLrc(text) {
        var lines = []
        var re = /\[(\d{2}):(\d{2})[\.\:](\d{2,3})\](.*)/
        var raw = text.split('\n')
        for (var i = 0; i < raw.length; i++) {
            var m = raw[i].match(re)
            if (m) {
                var mins = parseInt(m[1])
                var secs = parseInt(m[2])
                var sub  = parseInt(m[3])
                var ms   = (mins * 60 + secs) * 1000 + (m[3].length === 2 ? sub * 10 : sub)
                var txt  = (m[4] || "").trim()
                if (txt.length > 0) lines.push({ ms: ms, text: txt })
            }
        }
        lines.sort(function(a, b) { return a.ms - b.ms })
        return lines
    }

    function loadLyrics() {
        if (!hasTrack || track.id <= 0) return
        lyricsState = "loading"
        bridge.fetchLyrics(track.id, function(result, err) {
            if (err) { lyricsState = "unavailable"; return }
            var rawText = result.text || ""
            var timed   = result.timed || false
            if (rawText.length === 0) { lyricsState = "unavailable"; return }
            lyricsIsTimed = timed
            if (timed) {
                lyricsData = parseLrc(rawText)
            } else {
                var plain = rawText.split('\n')
                var arr = []
                for (var i = 0; i < plain.length; i++) {
                    var t = plain[i].trim()
                    if (t.length > 0) arr.push({ ms: 0, text: t })
                }
                lyricsData = arr
            }
            lyricsState = lyricsData.length > 0 ? "ready" : "unavailable"
            currentLyricLine = 0
        })
    }

    // ─── Credits ───────────────────────────────────────
    // The same four states the lyrics have: "none", "loading", "ready",
    // "unavailable". A failed fetch lands on "unavailable" as well.
    property string creditsState: "none"
    // [{type, contributors: [{id, name}]}] exactly as the bridge hands it over.
    property var    creditsGroups: []
    property string creditsCopyright:   ""
    property string creditsIsrc:        ""
    property string creditsReleaseDate: ""   // "2017-09-22", the album's
    property string creditsUpc:         ""

    // Per track id, so flipping between the two tabs or coming back to a track
    // does not refetch. Written into in place: nothing binds to it, and
    // reassigning would copy the whole cache on every write.
    property var creditsCache: ({})

    function applyCredits(entry) {
        root.creditsGroups      = entry.groups
        root.creditsCopyright   = entry.copyright
        root.creditsIsrc        = entry.isrc
        root.creditsReleaseDate = entry.releaseDate
        root.creditsUpc         = entry.upc
        root.creditsState       = entry.state
    }

    function clearCredits() {
        root.creditsGroups      = []
        root.creditsCopyright   = ""
        root.creditsIsrc        = ""
        root.creditsReleaseDate = ""
        root.creditsUpc         = ""
        root.creditsState       = "none"
    }

    // Asked for when the tab is opened, not when the track changes. Lyrics are
    // prefetched because their chip hides when there are none; the credits chip
    // is always offered and the fetch is three requests.
    function loadCredits() {
        if (!hasTrack || track.id <= 0) return
        if (root.creditsState === "loading") return
        var key = "" + track.id
        var hit = root.creditsCache[key]
        if (hit) { root.applyCredits(hit); return }

        root.creditsState = "loading"
        bridge.fetchTrackCredits(track.id, function (result, err) {
            var groups = (!err && result && result.groups) ? result.groups : []
            var entry = {
                groups:      groups,
                copyright:   (!err && result) ? (result.copyright   || "") : "",
                isrc:        (!err && result) ? (result.isrc        || "") : "",
                releaseDate: (!err && result) ? (result.releaseDate || "") : "",
                upc:         (!err && result) ? (result.upc         || "") : ""
            }
            // "Ready" means there is something on the panel, which a track with
            // no contributor groups can have: a release date or a rights line.
            entry.state = (!err && (groups.length > 0 || entry.copyright.length > 0
                                    || entry.releaseDate.length > 0))
                          ? "ready" : "unavailable"

            // A failure is not cached, so reopening the tab asks again. An
            // empty answer is kept: asking twice will not change it.
            if (!err) root.creditsCache[key] = entry

            // The answer can arrive after the user has moved on, and then it
            // belongs to the track it was asked about and not to this one.
            if (root.hasTrack && ("" + root.track.id) === key)
                root.applyCredits(entry)
        })
    }

    // "2017-09-22" in the reader's own date order and language: the locale's
    // long format without the weekday. Anything that is not a full ISO date
    // comes back untouched. AlbumPage.qml has the same function.
    function releaseDateText(iso) {
        if (!iso) return ""
        if (!/^\d{4}-\d{2}-\d{2}$/.test(iso)) return iso
        var d = Date.fromLocaleDateString(Qt.locale(), iso, "yyyy-MM-dd")
        if (isNaN(d.getTime())) return iso
        var fmt = Qt.locale().dateFormat(Locale.LongFormat)
                             .replace(/^dddd[,.]?\s*/, "")
                             .replace(/[,.]?\s*dddd$/, "")
        return d.toLocaleDateString(Qt.locale(), fmt)
    }

    Timer {
        id: lyricsSyncTimer
        interval: 400
        running: root.showLyrics && root.lyricsIsTimed && root.lyricsData.length > 0
        repeat: true
        onTriggered: {
            if (root.ignoreLyricsSync) return
            var pos = player.position
            var found = 0
            for (var i = 0; i < root.lyricsData.length; i++) {
                if (root.lyricsData[i].ms <= pos) found = i
                else break
            }
            if (found !== root.currentLyricLine) {
                root.currentLyricLine = found
                if (!root.userScrolled)
                    root.centreLyricLine(found, true)
            }
        }
    }

    Connections {
        target: player
        function onCurrentTrackChanged() {
            root.lyricsData   = []
            root.lyricsState  = "none"
            root.currentLyricLine = -1
            root.userScrolled = false
            root.ignoreLyricsSync = false
            ignoreSyncTimer.stop()
            root.updateLikedState()
            root.loadLyrics()
            // The displayed credits belong to the track that was playing; the
            // cache does not, and is left alone. Refetched here only if the tab
            // is actually open, which is the same bargain loadCredits() makes.
            root.clearCredits()
            if (root.showCredits) root.loadCredits()
            var t = player.currentTrack
            root.dlState = (t && t.id > 0 && downloader.isDownloading(t.id)) ? "busy" : "idle"
        }
    }

    Connections {
        target: bridge
        function onFavoriteTracksChanged() { root.updateLikedState() }
    }

    // Reflect download progress for the currently-playing track.
    Connections {
        target: downloader
        function onDownloadStarted(id)         { if (root.hasTrack && id === root.track.id) root.dlState = "busy" }
        function onDownloadFinished(id, path)  { if (root.hasTrack && id === root.track.id) { root.dlState = "done";  npDlReset.restart() } }
        function onDownloadError(id, msg)      { if (root.hasTrack && id === root.track.id) { root.dlState = "error"; npDlReset.restart() } }
    }
    Timer { id: npDlReset; interval: 3000; onTriggered: root.dlState = "idle" }
    function updateLikedState() {
        isLiked = (hasTrack && track.id > 0)
            ? bridge.isTrackFavorite(track.id)
            : false
    }

    // See PlayerBar: the same heart, the same read-back state, the same one
    // shared action behind it.
    readonly property alias favoriteAction: npFav
    ContextMenu.FavoriteAction { id: npFav }

    Component.onCompleted: {
        updateLikedState()
        loadLyrics()
        if (hasTrack && downloader.isDownloading(track.id)) dlState = "busy"
    }

    // ─── The background ────────────────────────────────
    // A soft accent wash fading into the page ground. Fullscreen with the
    // preference on, the top stop comes from the artwork instead: extracted in
    // C++ (src/ui/CoverColor.h), and until hasColor the accent wash paints.
    CoverTint {
        id: coverTint
        objectName: "nowPlayingCoverTint"
        active:  root.fullScreen && root.coverGradient
        coverId: root.hasTrack && root.track.coverUrl ? root.track.coverUrl : ""
        // The two grounds that bracket the band the tint is held inside. The
        // clamp is done in C++; the palette it is measured against is set here.
        bg:    Theme.bg
        limit: Theme.surfaceHigh
    }

    // The gradient's top stop as a property, so that a change to it can be
    // eased: a new track fades its colour in.
    property color gradientTop: coverTint.hasColor ? coverTint.color
                                                   : Theme.accentSoft
    Behavior on gradientTop { ColorAnimation { duration: Theme.dur(420) } }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0; color: root.gradientTop }
            GradientStop { position: 1; color: Theme.bg }
        }
    }

    // The page scrolls when it cannot fit, which stacking makes likely at the
    // 600px window minimum. Non-interactive while everything fits.
    Flickable {
        id: pageFlick
        objectName: "nowPlayingScroll"
        anchors.fill: parent
        contentWidth: width
        contentHeight: Math.max(height, pageColumn.implicitHeight + 2 * root.pageMargin)
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        ScrollBar.vertical: ScrollBar {
            policy: pageFlick.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        }

        ColumnLayout {
            id: pageColumn
            x: root.pageMargin
            y: root.pageMargin
            width:  root.contentWidth
            height: Math.max(0, pageFlick.contentHeight - 2 * root.pageMargin)
            spacing: 32

            // The way out, and the way to make the page the whole screen. The
            // down-arrow mirrors the player bar's up-arrow.
            RowLayout {
                id: headerRow
                Layout.fillWidth: true
                spacing: 12

                ChromeButton {
                    objectName: "nowPlayingCollapse"
                    icon: "chevron-down"
                    tip: qsTr("Close Now Playing", "returns to the page you came from")
                    onActivated: Window.window.goBack()
                }

                Item { Layout.fillWidth: true }

                ChromeButton {
                    objectName: "nowPlayingFullscreen"
                    icon: root.fullScreen ? "fullscreen-exit" : "fullscreen"
                    tip: root.fullScreen
                         ? qsTr("Leave fullscreen", "button, restores the window")
                         : qsTr("Fullscreen", "button, fills the screen with this page")
                    onActivated: root.toggleFullScreen()
                }
            }

            // Side by side above the breakpoint, stacked below. Placed by hand
            // off `stackness`, since a layout cannot animate its children's
            // positions. No fillHeight: the pair is as tall as its content.
            Item {
                id: body
                Layout.fillWidth: true
                Layout.preferredHeight: root.bodyHeight

                Item {
                    id: coverBox
                    objectName: "nowPlayingCoverBox"
                    x: root.coverX
                    y: root.coverY
                    width:  root.slotWidth
                    height: root.slotHeight
                    // Mid-move the two blocks pass through each other and no
                    // path keeps them apart. The opaque artwork goes on top, so
                    // the text slides behind it.
                    z: 1

                    // Album art. A square of its own size centred in the slot:
                    // the slot stops being square when a panel opens, and
                    // stretched artwork would show in the crossfade.
                    Rectangle {
                        objectName: "nowPlayingArt"
                        anchors.centerIn: parent
                        width:  root.coverSize
                        height: root.coverSize
                        radius: Theme.radiusArt; color: Theme.surfaceHigh; clip: true
                        opacity: 1 - root.panelness
                        visible: opacity > 0.01
                        Image {
                            anchors.fill: parent
                            source: hasTrack ? "image://tidal/" + track.coverUrl : ""
                            fillMode: Image.PreserveAspectCrop; smooth: true; mipmap: true
                        }
                    }

                    // Lyrics panel. This one does take the whole slot, which is
                    // the point: the measure and the height it gets are the
                    // slot's, worked out above.
                    Rectangle {
                        id: lyricsPanel
                        objectName: "nowPlayingLyricsPanel"
                        anchors.fill: parent
                        // Takes the cover's slot, so it takes the cover's corner too
                        radius: Theme.radiusArt
                        // A box in a window. In the reading view the fill and
                        // the border fade out on the same clock, leaving the
                        // lines on the cover gradient.
                        color: Qt.rgba(Theme.surface.r, Theme.surface.g,
                                       Theme.surface.b,
                                       Theme.surface.a * (1 - root.readingness))
                        border.color: Qt.rgba(Theme.border.r, Theme.border.g,
                                              Theme.border.b,
                                              Theme.border.a * (1 - root.readingness))
                        opacity: root.lyricsness
                        visible: opacity > 0.01
                        clip: true

                        ListView {
                            id: lyricsView
                            objectName: "nowPlayingLyricsView"
                            anchors.fill: parent
                            anchors.margins: 16
                            // Content margins, not a smaller viewport: a line
                            // can be drawn anywhere in the box and still be
                            // scrolled clear of the chips.
                            topMargin: root.lyricsHeaderRoom
                            bottomMargin: root.lyricsFooterRoom
                            clip: true
                            model: root.lyricsData
                            // The gap between lines rides the type size.
                            spacing: Math.round(8 * root.lyricLineSize / root.lyricsSize)
                            cacheBuffer: 200

                            onMovingChanged: if (moving) root.userScrolled = true

                            // Every resize is a re-wrap, which moves the
                            // centred line. Deferred so the delegates are laid
                            // out first, and coalesced to once a frame.
                            onWidthChanged:  Qt.callLater(root.recentreLyrics)
                            onHeightChanged: Qt.callLater(root.recentreLyrics)

                            delegate: Text {
                                id: lyricText
                                required property var  modelData
                                required property int  index
                                readonly property bool active: root.lyricsIsTimed && index === root.currentLyricLine
                                readonly property bool hovered: root.lyricsIsTimed && hoverHandler.hovered
                                width: lyricsView.width
                                text: modelData.text
                                // Theme.textPrimary, the brightest ink, and not
                                // the accent. Bold and full opacity tell the
                                // active line from a hovered one.
                                color: (active || hovered) ? Theme.textPrimary
                                                           : Theme.textSec
                                font.pixelSize: root.lyricLineSize
                                font.bold: active
                                // Left in a panel, centred in the reading view.
                                // Alignment cannot be lerped, so it flips at the
                                // halfway point of the move.
                                horizontalAlignment: root.readingness >= 0.5
                                                     ? Text.AlignHCenter
                                                     : Text.AlignLeft
                                opacity: active ? 1.0 : (hovered ? 0.85 : 0.55)
                                lineHeight: 1.6
                                wrapMode: Text.WordWrap
                                Behavior on opacity { NumberAnimation { duration: Theme.dur(180); easing.type: Easing.OutCubic } }
                                Behavior on color   { ColorAnimation  { duration: Theme.dur(180) } }

                                HoverHandler {
                                    id: hoverHandler
                                    enabled: root.lyricsIsTimed
                                    cursorShape: root.lyricsIsTimed ? Qt.PointingHandCursor : Qt.ArrowCursor
                                }

                                TapHandler {
                                    enabled: root.lyricsIsTimed
                                    onTapped: {
                                        root.ignoreLyricsSync = true
                                        ignoreSyncTimer.restart()
                                        player.seek(modelData.ms)
                                        root.userScrolled = false
                                        root.currentLyricLine = index
                                        root.centreLyricLine(index, true)
                                    }
                                }
                            }

                            // Loading / empty states
                            Text {
                                anchors.centerIn: parent
                                visible: root.lyricsState === "loading"
                                text: qsTr("Loading lyrics…")
                                color: Theme.textDim; font.pixelSize: 14
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: root.lyricsState === "unavailable"
                                text: qsTr("No lyrics available")
                                color: Theme.textDim; font.pixelSize: 14
                            }
                        }

                        // Resync button
                        Rectangle {
                            objectName: "nowPlayingLyricsResync"
                            visible: root.userScrolled && root.lyricsIsTimed && root.currentLyricLine >= 0
                            anchors.bottom: parent.bottom
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottomMargin: 10
                            width: rsText.implicitWidth + 20; height: 28; radius: Theme.radiusChip
                            color: Theme.artScrimStrong
                            border.color: Theme.artBorder
                            Text {
                                id: rsText
                                anchors.centerIn: parent
                                text: qsTr("Resync")
                                color: Theme.artInk; font.pixelSize: 12
                            }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            // ReleaseWithinBounds: the default DragThreshold
                            // policy takes only a passive grab, and the lyric
                            // line under this chip would answer the same tap.
                            TapHandler {
                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: {
                                    root.userScrolled = false
                                    if (root.currentLyricLine >= 0)
                                        root.centreLyricLine(root.currentLyricLine, true)
                                }
                            }
                        }
                    }

                    // Credits panel. The other tab over the same slot, built
                    // like the lyrics panel: same walls, clock, content margins
                    // and reading view.
                    Rectangle {
                        id: creditsPanel
                        objectName: "nowPlayingCreditsPanel"
                        anchors.fill: parent
                        radius: Theme.radiusArt
                        color: Qt.rgba(Theme.surface.r, Theme.surface.g,
                                       Theme.surface.b,
                                       Theme.surface.a * (1 - root.readingness))
                        border.color: Qt.rgba(Theme.border.r, Theme.border.g,
                                              Theme.border.b,
                                              Theme.border.a * (1 - root.readingness))
                        opacity: root.creditsness
                        visible: opacity > 0.01
                        clip: true

                        // How much bigger everything in here is than docked:
                        // every size below is its docked size times this.
                        readonly property real typeScale:
                            root.lyricLineSize / root.lyricsSize
                        readonly property int  labelSize: Math.round(11 * typeScale)
                        readonly property int  nameSize:  Math.round(14 * typeScale)
                        readonly property int  factSize:  Math.round(12 * typeScale)
                        // Same flip, same reason, as the lyric line's.
                        readonly property int  align: root.readingness >= 0.5
                                                      ? Text.AlignHCenter
                                                      : Text.AlignLeft

                        Flickable {
                            id: creditsFlick
                            objectName: "nowPlayingCreditsView"
                            anchors.fill: parent
                            anchors.margins: 16
                            visible: root.creditsState === "ready"
                            // Content margins, not a smaller viewport, as on
                            // the lyric list.
                            bottomMargin: root.lyricsFooterRoom
                            contentWidth: width
                            contentHeight: creditsColumn.implicitHeight
                            interactive: contentHeight + bottomMargin > height
                            boundsBehavior: Flickable.StopAtBounds
                            clip: true
                            ScrollBar.vertical: ScrollBar {
                                policy: creditsFlick.interactive ? ScrollBar.AsNeeded
                                                                 : ScrollBar.AlwaysOff
                            }

                            ColumnLayout {
                                id: creditsColumn
                                width: creditsFlick.width
                                spacing: Math.round(16 * creditsPanel.typeScale)

                                // Who played what. The group's type is the
                                // label's own word for the role, so it is data
                                // and is not translated.
                                Repeater {
                                    model: root.creditsGroups
                                    delegate: ColumnLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 2

                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.type || ""
                                            color: Theme.textDim
                                            font.pixelSize: creditsPanel.labelSize
                                            font.bold: true
                                            font.letterSpacing: 1
                                            horizontalAlignment: creditsPanel.align
                                            wrapMode: Text.WordWrap
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: {
                                                var names = []
                                                var cs = modelData.contributors || []
                                                for (var i = 0; i < cs.length; i++)
                                                    if (cs[i].name) names.push(cs[i].name)
                                                return names.join(", ")
                                            }
                                            color: Theme.textPrimary
                                            font.pixelSize: creditsPanel.nameSize
                                            horizontalAlignment: creditsPanel.align
                                            wrapMode: Text.WordWrap
                                        }
                                    }
                                }

                                // The small print, under a rule. Each line hides
                                // when the API did not carry it.
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Math.round(8 * creditsPanel.typeScale)
                                    height: 1
                                    color: Theme.border
                                    visible: root.creditsReleaseDate.length > 0
                                             || root.creditsCopyright.length > 0
                                             || root.creditsIsrc.length > 0
                                             || root.creditsUpc.length > 0
                                }

                                // The date the record came out, in full.
                                Text {
                                    Layout.fillWidth: true
                                    visible: root.creditsReleaseDate.length > 0
                                    text: qsTr("Released %1",
                                               "label and date, when the record came out")
                                          .arg(root.releaseDateText(root.creditsReleaseDate))
                                    color: Theme.textSec
                                    font.pixelSize: creditsPanel.factSize
                                    horizontalAlignment: creditsPanel.align
                                    wrapMode: Text.WordWrap
                                }

                                // The rights line as worded: a legal notice, so
                                // not translated or reformatted.
                                Text {
                                    Layout.fillWidth: true
                                    visible: root.creditsCopyright.length > 0
                                    text: root.creditsCopyright
                                    color: Theme.textSec
                                    font.pixelSize: creditsPanel.factSize
                                    horizontalAlignment: creditsPanel.align
                                    wrapMode: Text.WordWrap
                                }

                                // The two identifiers, one dim line at the foot.
                                Text {
                                    Layout.fillWidth: true
                                    visible: root.creditsIsrc.length > 0
                                             || root.creditsUpc.length > 0
                                    text: {
                                        var ids = []
                                        if (root.creditsIsrc.length > 0)
                                            ids.push(qsTr("ISRC %1",
                                                     "label and code, identifies the recording")
                                                     .arg(root.creditsIsrc))
                                        if (root.creditsUpc.length > 0)
                                            ids.push(qsTr("UPC %1",
                                                     "label and barcode, identifies the release")
                                                     .arg(root.creditsUpc))
                                        return ids.join("  \u00b7  ")
                                    }
                                    color: Theme.textDim
                                    font.pixelSize: creditsPanel.labelSize
                                    horizontalAlignment: creditsPanel.align
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }

                        // In flight, and nothing to show: the same two messages
                        // in the same place as the lyrics.
                        Text {
                            anchors.centerIn: parent
                            visible: root.creditsState === "loading"
                            text: qsTr("Loading credits…")
                            color: Theme.textDim
                            font.pixelSize: creditsPanel.nameSize
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: root.creditsState === "unavailable"
                            text: qsTr("No credits available")
                            color: Theme.textDim
                            font.pixelSize: creditsPanel.nameSize
                        }
                    }

                    // The two tabs for the slot, at its foot: Credits, then
                    // Lyrics in the corner. The Row skips a hidden chip, so
                    // with no lyrics Credits takes the corner.
                    Row {
                        objectName: "nowPlayingPanelChips"
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        anchors.margins: 10
                        spacing: 8

                        PanelChip {
                            objectName: "nowPlayingCreditsToggle"
                            // Offered for every track: only the fetch that
                            // opening it pays for can say there is nothing.
                            visible: root.hasTrack
                            on: root.showCredits
                            // The same comment-free "Loading…" as the lyrics
                            // chip: a disambiguation comment is part of the key
                            // and would add a second catalogue entry.
                            label: root.creditsState === "loading"
                                   ? qsTr("Loading…")
                                   : qsTr("Credits", "chip, opens the song credits")
                            onToggled: {
                                root.showCredits = !root.showCredits
                                if (root.showCredits) root.loadCredits()
                            }
                        }

                        PanelChip {
                            objectName: "nowPlayingLyricsToggle"
                            visible: root.lyricsState !== "unavailable"
                            on: root.showLyrics
                            label: root.lyricsState === "loading"
                                   ? qsTr("Loading…") : qsTr("Lyrics")
                            onToggled: {
                                root.showLyrics = !root.showLyrics
                                if (root.showLyrics && root.lyricsState === "none")
                                    root.loadLyrics()
                            }
                        }
                    }
                }

                ColumnLayout {
                    id: infoColumn
                    objectName: "nowPlayingInfoColumn"
                    x: root.infoX
                    y: root.infoY
                    width: root.infoWidth
                    spacing: 24

                    RowLayout {
                        id: npTransportRow
                        Layout.fillWidth: true
                        spacing: 16

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            // "Playing from" link: back to the playlist, album,
                            // mix or liked songs it started from.
                            Text {
                                id: sourceLink
                                visible: hasTrack && player.sourceName.length > 0
                                text: qsTr("Playing from: %1").arg(player.sourceName)
                                color: sourceLinkHov.hovered ? Theme.textPrimary : Theme.textDim
                                font.pixelSize: 12
                                font.letterSpacing: 0.5
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                                HoverHandler { id: sourceLinkHov; cursorShape: Qt.PointingHandCursor }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: goToSource()
                                }
                            }
                            // The title opens the album the track is on, as the
                            // album line below does. The hit target and the
                            // focus ring follow the words, not the column.
                            Text {
                                id: titleLink
                                objectName: "nowPlayingTitle"
                                text: hasTrack ? track.title : "–"; color: Theme.textPrimary
                                font.pixelSize: 32; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true
                                font.underline: titleHit.containsMouse && hasTrack && Number(track.albumId) > 0
                                activeFocusOnTab: hasTrack && Number(track.albumId) > 0
                                Keys.onReturnPressed: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                Keys.onSpacePressed:  if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                Rectangle {
                                    x: -4; y: -4
                                    width:  Math.min(parent.width, parent.contentWidth) + 8
                                    height: parent.height + 8
                                    radius: Theme.radiusButton; color: "transparent"
                                    border.width: titleLink.activeFocus ? 2 : 0
                                    border.color: Theme.accent
                                }
                                MouseArea {
                                    id: titleHit
                                    width:  Math.min(parent.width, parent.contentWidth)
                                    height: parent.height
                                    hoverEnabled: true
                                    cursorShape: hasTrack && Number(track.albumId) > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                }
                            }
                            // One focus stop and hover target per artist. Fills
                            // and elides: without Layout.fillWidth the names'
                            // own width is the column's minimum width.
                            ArtistLinks {
                                Layout.fillWidth: true
                                namePrefix: "nowPlaying"
                                fontPixelSize: 18
                                artistList: root.artistList
                                joinedText: hasTrack ? track.artists : ""
                                fallbackArtistId: hasTrack ? Number(track.artistId) : 0
                            }
                            Text {
                                id: albumLink
                                text: hasTrack ? track.albumTitle : ""; color: Theme.textSec; font.pixelSize: 15
                                // Same reason as the artist line above.
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font.underline: albumHit.containsMouse && hasTrack && Number(track.albumId) > 0
                                activeFocusOnTab: hasTrack && Number(track.albumId) > 0
                                Keys.onReturnPressed: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                Keys.onSpacePressed:  if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                Rectangle {
                                    x: -4; y: -4
                                    width:  Math.min(parent.width, parent.contentWidth) + 8
                                    height: parent.height + 8
                                    radius: Theme.radiusButton; color: "transparent"
                                    border.width: albumLink.activeFocus ? 2 : 0
                                    border.color: Theme.accent
                                }
                                MouseArea {
                                    id: albumHit
                                    width:  Math.min(parent.width, parent.contentWidth)
                                    height: parent.height
                                    hoverEnabled: true
                                    cursorShape: hasTrack && Number(track.albumId) > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                }
                            }
                        }

                        // Download button, shown while a track is playing.
                        Item {
                            id: npDownloadBtn
                            visible: root.hasTrack
                            Layout.preferredWidth: 44
                            Layout.preferredHeight: 44
                            activeFocusOnTab: root.dlState !== "busy"
                            Keys.onReturnPressed: if (root.hasTrack && root.dlState !== "busy") downloader.downloadTrack(root.track)
                            Keys.onSpacePressed:  if (root.hasTrack && root.dlState !== "busy") downloader.downloadTrack(root.track)
                            Rectangle {
                                anchors.fill: parent; radius: width / 2; color: "transparent"
                                border.width: npDownloadBtn.activeFocus ? 2 : 0
                                border.color: Theme.accent
                            }
                            VectorIcon {
                                anchors.centerIn: parent
                                visible: root.dlState === "idle" || root.dlState === "error"
                                name: "download"
                                color: root.dlState === "error" ? Theme.red
                                       : (npDlHov.hovered ? Theme.textPrimary : Theme.textSec)
                                width: 24; height: 24; strokeWidth: 1.5
                            }
                            VectorIcon {
                                anchors.centerIn: parent
                                visible: root.dlState === "done"
                                name: "check"; color: Theme.green
                                width: 24; height: 24; strokeWidth: 2
                            }
                            Item {
                                id: npSpinner
                                anchors.centerIn: parent
                                width: 22; height: 22
                                visible: root.dlState === "busy"
                                Rectangle {
                                    width: 3.5; height: 9; radius: 1.75
                                    anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
                                    color: Theme.accent
                                }
                                RotationAnimator {
                                    target: npSpinner; from: 0; to: 360; duration: Theme.dur(800)
                                    loops: Theme.reduceMotion ? 1 : Animation.Infinite
                                    running: root.dlState === "busy"
                                }
                            }
                            HoverHandler { id: npDlHov; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: if (root.hasTrack && root.dlState !== "busy") downloader.downloadTrack(root.track) }
                            ToolTip.visible: npDlHov.hovered && root.dlState === "error"
                            ToolTip.text: qsTr("Download failed. Click to retry.")
                            ToolTip.delay: 300
                        }

                        CtrlBtn {
                            id: npLikeBtn
                            objectName: "nowPlayingLikeButton"
                            visible: root.hasTrack
                            icon: root.isLiked ? "heart-filled" : "heart"
                            size: 24
                            active: root.isLiked
                            // On the row: CtrlBtn has its own hover tool tip,
                            // and two uses of the shared one fight.
                            onClicked: root.favoriteAction.toggleTrack(root.track.id, root.isLiked,
                                                                      npTransportRow)
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12

                        // Quality badge
                        Rectangle {
                            objectName: "qualityBadge"
                            visible: player.audioQuality.length > 0
                            height: 24; width: qlbl.implicitWidth + 12; radius: Theme.radiusBadge
                            color: player.audioQuality === "HI_RES_LOSSLESS" ? Theme.accentWash :
                                   player.audioQuality === "LOSSLESS" ? Theme.greenWash : Theme.surfaceHigh
                            Text {
                                id: qlbl; objectName: "qualityBadgeText"
                                anchors.centerIn: parent
                                text: player.qualityLabel(player.audioQuality)
                                color: Theme.textPrimary; font.pixelSize: 11; font.bold: true
                            }
                        }

                        Item { Layout.fillWidth: true } // Pusher

                        // Sleep Timer button. The clock is concentric with the
                        // pill's left cap, so the ring of air around it is
                        // even. The text end keeps the corner radius.
                        Rectangle {
                            id: sleepTimerBtn
                            objectName: "nowPlayingSleepTimerButton"
                            // height minus glyphSize has to stay even, so the
                            // ring round the glyph is a whole number of pixels:
                            // anchor centring rounds.
                            height: 30
                            // What the pill actually draws: Theme.radiusChip is
                            // a "round it all the way" sentinel, and Qt clamps
                            // it to half the shorter side.
                            readonly property real cornerRadius:
                                Math.min(Theme.radiusChip, height / 2)
                            // The clock's box. Everything below is derived from
                            // it and the height. VectorIcon paints its glyph at
                            // 85% of the box.
                            readonly property real glyphSize: 20
                            // Concentric with the left cap: the glyph's centre
                            // on the centre of the cap's arc, so the gap beside
                            // the glyph equals the gap above it.
                            readonly property real leadInset:
                                cornerRadius - glyphSize / 2
                            // The text end, which has no circle to align with.
                            readonly property real trailPad: cornerRadius

                            // implicitWidth, not width: a Layout owns its
                            // children's width and would re-impose the size it
                            // captured on every change.
                            implicitWidth: leadInset + sleepTimerRow.implicitWidth
                                           + trailPad
                            radius: cornerRadius

                            // Rest and hover as a pair, as on ChromeButton.
                            // Counting, the hover is the accent at 0.36:
                            // accentTint to accentWash is too small a step.
                            readonly property color restFill:
                                root.sleepTimerActive ? Theme.accentTint : Theme.surfaceHigh
                            readonly property color hoverFill:
                                root.sleepTimerActive
                                    ? Qt.rgba(Theme.accent.r, Theme.accent.g,
                                              Theme.accent.b, 0.36)
                                    : Theme.surfaceHov
                            readonly property color restBorder:
                                root.sleepTimerActive ? Theme.accent : Theme.border
                            // The counting pill's border is already the accent
                            // at full strength; there is nowhere brighter for it
                            // to go, and its fill is carrying the hover.
                            readonly property color hoverBorder:
                                root.sleepTimerActive ? Theme.accent : Theme.textSec

                            color: sleepMa.containsMouse ? hoverFill : restFill
                            border.color: sleepMa.containsMouse ? hoverBorder : restBorder
                            border.width: 1
                            Behavior on color        { ColorAnimation { duration: Theme.dur(100) } }
                            Behavior on border.color { ColorAnimation { duration: Theme.dur(100) } }

                            // Measures the widest clock the countdown can show,
                            // in the font it shows it in.
                            FontMetrics { id: sleepFm; font.pixelSize: 11; font.bold: true }

                            RowLayout {
                                id: sleepTimerRow
                                objectName: "nowPlayingSleepTimerRow"
                                // Anchored to the left edge, not centred: the
                                // two ends are padded differently.
                                anchors.left: parent.left
                                anchors.leftMargin: sleepTimerBtn.leadInset
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6

                                VectorIcon {
                                    objectName: "nowPlayingSleepTimerIcon"
                                    name: "clock"
                                    color: root.sleepTimerActive ? Theme.accent : Theme.textSec

                                    // Heavier than VectorIcon's 1.8 default, which
                                    // draws too thin a line at this size.
                                    strokeWidth: 2.4

                                    // Layout.preferredWidth/Height: a layout imposes
                                    // VectorIcon's implicit 24 over a plain
                                    // width/height. Both, so the clock stays square.
                                    Layout.preferredWidth:  sleepTimerBtn.glyphSize
                                    Layout.preferredHeight: sleepTimerBtn.glyphSize
                                }

                                Text {
                                    objectName: "nowPlayingSleepTimerLabel"
                                    text: root.sleepTimerActive ?
                                          (root.sleepStopAtEndOfTrack ? qsTr("End of Track") : root.formatSleepTime(root.sleepTimeLeft)) :
                                          qsTr("Sleep Timer")
                                    // The pill is sized from this label. While
                                    // counting it holds the widest clock of its
                                    // shape, "mm:ss" or "h:mm:ss".
                                    readonly property string widestClock:
                                        text.indexOf(":") !== text.lastIndexOf(":")
                                            ? "0:00:00" : "00:00"
                                    Layout.preferredWidth:
                                        (root.sleepTimerActive && !root.sleepStopAtEndOfTrack)
                                            ? Math.max(implicitWidth,
                                                       sleepFm.advanceWidth(widestClock))
                                            : implicitWidth
                                    horizontalAlignment: Text.AlignHCenter
                                    color: root.sleepTimerActive ? Theme.accent : Theme.textSec
                                    font.pixelSize: 11
                                    font.bold: root.sleepTimerActive
                                }
                            }

                            // One MouseArea for hover, cursor and click: with a
                            // cursorShape it accepts hover events, so a
                            // HoverHandler behind it would never report.
                            MouseArea {
                                id: sleepMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: sleepTimerPopup.open()
                            }
                        }
                    }

                    Popup {
                        id: sleepTimerPopup
                        objectName: "nowPlayingSleepTimerPopup"
                        parent: sleepTimerBtn
                        x: sleepTimerBtn.width - width
                        width: 260
                        padding: 12

                        // ── how tall it is, and which side of the pill it opens on ──
                        // Both come from the content's implicit height. Binding
                        // `y` to this popup's own `height` is a polish loop on
                        // Qt 6.4, where the positioner sets that height.
                        readonly property real popupHeight:
                            contentCol.implicitHeight + topPadding + bottomPadding
                        height: popupHeight

                        // The gap to the pill, whichever side it lands on.
                        readonly property real pillGap: 6

                        // The pill's top in window coordinates and the room
                        // under it. Summed along the parent chain so every term
                        // is a property read, which mapToItem() is not.
                        function pillFrame() {
                            var top = 0
                            var it = sleepTimerBtn
                            while (it.parent) { top += it.y; it = it.parent }
                            return { top: top, windowHeight: it.height }
                        }
                        readonly property real pillTopInWindow: pillFrame().top
                        readonly property real roomBelowPill: {
                            var f = pillFrame()
                            return f.windowHeight - (f.top + sleepTimerBtn.height)
                                   - pillGap
                        }

                        // Below the pill where the window has room, above it
                        // where it does not. Where neither fits, the gap gives
                        // way before the top edge, so the title stays visible.
                        y: popupHeight <= roomBelowPill
                           ? sleepTimerBtn.height + pillGap
                           : Math.max(-pillTopInWindow, -(popupHeight + pillGap))
                        modal: true
                        focus: true
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                    
                        background: Rectangle {
                            color: Theme.surfaceHigh
                            border.color: Theme.border
                            border.width: 1
                            radius: Theme.radiusPopup
                        
                            MouseArea {
                                anchors.fill: parent
                                // Capture and accept all mouse events to prevent propagating to items below the popup
                                onClicked: (mouse) => mouse.accepted = true
                                onPressed: (mouse) => mouse.accepted = true
                                onReleased: (mouse) => mouse.accepted = true
                            }
                        }

                        ColumnLayout {
                            id: contentCol
                            anchors.fill: parent
                            spacing: 12

                            Text {
                                text: qsTr("Sleep Timer")
                                color: Theme.textPrimary
                                font.pixelSize: 14
                                font.bold: true
                                Layout.alignment: Qt.AlignLeft
                            }

                            // Options container when timer is INACTIVE
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                visible: !root.sleepTimerActive

                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 3
                                    columnSpacing: 8
                                    rowSpacing: 8
                                
                                    SleepOptionBtn { minutes: 5 }
                                    SleepOptionBtn { minutes: 15 }
                                    SleepOptionBtn { minutes: 30 }
                                    SleepOptionBtn { minutes: 45 }
                                    SleepOptionBtn { minutes: 60 }
                                    SleepOptionBtn { minutes: 90 }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 32
                                    radius: Theme.radiusButton
                                    color: maEndOfTrack.containsMouse ? Theme.surfaceHov : Theme.surface
                                    border.color: Theme.border
                                    border.width: 1
                                
                                    RowLayout {
                                        anchors.centerIn: parent
                                        spacing: 6
                                        VectorIcon {
                                            name: "track"
                                            color: Theme.accent
                                            width: 12
                                            height: 12
                                        }
                                        Text {
                                            text: qsTr("Stop at End of Track")
                                            color: Theme.textPrimary
                                            font.pixelSize: 12
                                            font.bold: true
                                        }
                                    }
                                
                                    MouseArea {
                                        id: maEndOfTrack
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        hoverEnabled: true
                                        onClicked: {
                                            root.startSleepTimer(0, true)
                                            sleepTimerPopup.close()
                                        }
                                    }
                                }

                                // Divider
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 1
                                    color: Theme.border
                                }

                                // Custom Slider (using the project's native slider styling)
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    Text {
                                        text: qsTr("Custom: %1 min").arg(customSlider.value)
                                        color: Theme.textSec
                                        font.pixelSize: 12
                                    }
                                
                                    Item {
                                        id: customSlider
                                        property int value: 20
                                        Layout.fillWidth: true
                                        height: 20
                                    
                                        Rectangle {
                                            id: customTrack
                                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                                            // A 3px bar, so the chip radius clamps to a capsule
                                            height: 3; radius: Theme.radiusChip
                                            color: Theme.border

                                            Rectangle {
                                                width: ((customSlider.value - 1) / 119.0) * customTrack.width
                                                height: parent.height; radius: parent.radius
                                                color: Theme.accent
                                            }

                                            Rectangle {
                                                x: Math.max(0, Math.min(customTrack.width - width, ((customSlider.value - 1) / 119.0) * customTrack.width - width / 2))
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 10; height: 10; radius: 5
                                                color: Theme.textPrimary
                                            }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            preventStealing: true
                                            onPressed: (mouse) => {
                                                var pct = Math.max(0, Math.min(1, mouse.x / width))
                                                customSlider.value = Math.round(1 + pct * 119)
                                            }
                                            onPositionChanged: (mouse) => {
                                                if (pressed) {
                                                    var pct = Math.max(0, Math.min(1, mouse.x / width))
                                                    customSlider.value = Math.round(1 + pct * 119)
                                                }
                                            }
                                            cursorShape: Qt.PointingHandCursor
                                        }
                                    }

                                    // The popup's primary action, the PillButton
                                    // other pages use for Play. Under the slider
                                    // because it commits what the slider says.
                                    PillButton {
                                        objectName: "nowPlayingSleepTimerStart"
                                        Layout.fillWidth: true
                                        Layout.topMargin: 8
                                        text: qsTr("Start", "verb, begins the sleep timer")
                                        icon: "play"
                                        accent: true
                                        onClicked: {
                                            root.startSleepTimer(customSlider.value, false)
                                            sleepTimerPopup.close()
                                        }
                                    }
                                }
                            }

                            // Options container when timer is ACTIVE
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                visible: root.sleepTimerActive

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 50
                                    color: Theme.accentSoft
                                    border.color: Theme.accentDim
                                    border.width: 1
                                    radius: Theme.radiusCard
                                
                                    ColumnLayout {
                                        anchors.centerIn: parent
                                        spacing: 2
                                        Text {
                                            text: root.sleepStopAtEndOfTrack ? qsTr("Stopping at end of track") : 
                                                  root.sleepIsFading ? qsTr("Fading out audio…") : 
                                                  qsTr("Remaining: %1").arg(root.formatSleepTime(root.sleepTimeLeft))
                                            color: Theme.textPrimary
                                            font.pixelSize: 13
                                            font.bold: true
                                            Layout.alignment: Qt.AlignHCenter
                                        }
                                        Text {
                                            text: root.sleepStopAtEndOfTrack ? qsTr("Fades out last 15s") : qsTr("Fades out last 30s")
                                            color: Theme.textDim
                                            font.pixelSize: 10
                                            visible: root.sleepFadeOut
                                            Layout.alignment: Qt.AlignHCenter
                                        }
                                    }
                                }
                            
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 32
                                    radius: Theme.radiusButton
                                    color: Theme.redSoft
                                    border.color: Theme.red
                                    border.width: 1
                                
                                    Text {
                                        anchors.centerIn: parent
                                        text: qsTr("Cancel Sleep Timer")
                                        color: Theme.red
                                        font.pixelSize: 12
                                        font.bold: true
                                    }
                                
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.cancelSleepTimer()
                                            sleepTimerPopup.close()
                                        }
                                    }
                                }
                            }

                            // Divider
                            Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: Theme.border
                            }

                            // Robust Options Toggle (Custom Row Switch)
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 12
                            
                                Text {
                                    text: qsTr("Fade out audio")
                                    color: Theme.textSec
                                    font.pixelSize: 12
                                    Layout.fillWidth: true
                                }
                            
                                Rectangle {
                                    width: 34
                                    height: 18
                                    radius: Theme.radiusChip
                                    color: root.sleepFadeOut ? Theme.accent : Theme.surface
                                    border.color: Theme.border
                                    border.width: 1
                                
                                    Rectangle {
                                        x: root.sleepFadeOut ? 17 : 1
                                        y: 1
                                        width: 16
                                        height: 16
                                        radius: 8
                                        color: root.sleepFadeOut ? Theme.accentInk : Theme.textPrimary
                                        Behavior on x { NumberAnimation { duration: Theme.dur(150) } }
                                    }
                                }
                            
                                // Handlers, not a MouseArea: the whole row is
                                // the hit target, and an anchored MouseArea
                                // inside a layout is undefined behaviour.
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    onTapped: {
                                        if (Window.window) Window.window.sleepFadeOut = !Window.window.sleepFadeOut
                                    }
                                }
                            }
                        }
                    }

                    SeekBar {
                        // Stays visible and fully opaque in the reading view,
                        // as does the transport row below.
                        objectName: "nowPlayingSeekBar"
                        Layout.fillWidth: true
                        position: player.position; duration: player.duration
                        onSeeked: (ms) => player.seek(ms)
                    }

                    // A plain parent makes the row a top-level layout, which
                    // polishes itself. Nested, Qt 6.4 skips a layout that kept
                    // its size, as this one does when the volume joins it.
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: npTransportButtons.implicitHeight
                        RowLayout {
                            id: npTransportButtons
                            objectName: "nowPlayingTransportRow"
                            anchors.fill: parent
                            spacing: root.transportSpacing
                            CtrlBtn { objectName: "nowPlayingShuffle"; icon: "shuffle"; size: 24; active: player.shuffle; onClicked: player.setShuffle(!player.shuffle) }
                            // The cluster's counterweight, which keeps play in
                            // the middle. Invisible, not zero-width: a RowLayout
                            // keeps the spacing of a zero-width child.
                            Item {
                                objectName: "nowPlayingTransportWeight"
                                visible: root.volumeClusterFits
                                Layout.preferredWidth: root.volumeClusterWidth
                            }
                            Item { Layout.fillWidth: true }
                            CtrlBtn { objectName: "nowPlayingPrevious"; icon: "previous"; size: 28; onClicked: player.previous() }
                            Rectangle {
                                id: npPlayPause
                                objectName: "nowPlayingPlayButton"
                                width: 64; height: 64; radius: 32; color: Theme.textPrimary
                                border.width: activeFocus ? 2 : 0
                                border.color: Theme.accent
                                activeFocusOnTab: true
                                Keys.onReturnPressed: player.playPause()
                                Keys.onSpacePressed:  player.playPause()
                                VectorIcon {
                                    anchors.centerIn: parent
                                    name: player.playing ? "pause" : "play"
                                    color: Theme.bg
                                    width: 32
                                    height: 32
                                    strokeWidth: 1.5
                                }
                                scale: pHov.hovered ? 0.95 : 1; Behavior on scale { NumberAnimation { duration: Theme.dur(100) } }
                                HoverHandler { id: pHov; cursorShape: Qt.PointingHandCursor }
                                TapHandler   { onTapped: player.playPause() }
                            }
                            CtrlBtn { objectName: "nowPlayingNext"; icon: "next"; size: 28; onClicked: player.next() }
                            Item { Layout.fillWidth: true }
                            CtrlBtn { objectName: "nowPlayingRepeat"; icon: player.repeatMode === 2 ? "repeat-one" : "repeat"; size: 24; active: player.repeatMode > 0; onClicked: player.setRepeatMode((player.repeatMode + 1) % 3) }

                            // The volume, where the row can hold it. Invisible,
                            // not folded: a Layout drops an invisible child and
                            // its spacing outright.
                            VolumeControls {
                                objectName: "nowPlayingVolumeCluster"
                                visible: root.volumeClusterFits
                                Layout.alignment: Qt.AlignVCenter
                            }
                        }
                    }

                    // The volume's other home, when the transport row cannot
                    // carry the cluster: a line to itself, right-aligned at the
                    // same short width. Kept in the reading view too.
                    RowLayout {
                        objectName: "nowPlayingVolumeRow"
                        visible: !root.volumeInTransport
                        Layout.fillWidth: true
                        spacing: 0
                        Item { Layout.fillWidth: true }
                        VolumeControls { objectName: "nowPlayingVolumeOwnCluster" }
                    }

                    // Up Next preview
                    ColumnLayout {
                        id: upNextCol
                        objectName: "nowPlayingUpNextColumn"
                        Layout.fillWidth: true

                        // ─── The one block the reading view folds ──────
                        // The reading view takes its height from this list, the
                        // one block that is neither chrome nor a control.
                        // Lerped, so the panel grows into the space.
                        readonly property real foldAway: 1 - root.readingness
                        Layout.preferredHeight: implicitHeight * foldAway
                        // A nested Layout reports a minimum height off its
                        // children's, and the parent will not take it below
                        // that, so the fold would stop short.
                        Layout.minimumHeight: 0
                        opacity: foldAway
                        // The fold leaves the column's 24px gap: a ColumnLayout
                        // drops spacing only for an invisible child, and going
                        // invisible would be a step at the end.
                        clip: true
                        spacing: 12
                        // The true play order, shuffle included. queueCount is
                        // read for the dependency, not queueTracks, which
                        // copies the whole queue into JS.
                        property var upNext: (player.queueCount, player.queueIndex,
                                              player.shuffle, player.upcomingTracks(3))
                        visible: upNext.length > 0

                        Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true }

                        Text {
                            text: qsTr("Up Next")
                            color: Theme.textDim
                            font.pixelSize: 11
                            font.bold: true
                            font.letterSpacing: 1
                        }

                        Repeater {
                            model: upNextCol.upNext
                            delegate: RowLayout {
                                required property int index
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.topMargin: 4
                                Layout.bottomMargin: 4
                                spacing: 12
                                property var upTrack: modelData
                                Rectangle {
                                    width: 44; height: 44; radius: Theme.radiusArt; color: Theme.surfaceHigh; clip: true
                                    Image {
                                        anchors.fill: parent
                                        source: upTrack && upTrack.coverUrl80 ? "image://tidal/" + upTrack.coverUrl80 : ""
                                        fillMode: Image.PreserveAspectCrop; smooth: true; mipmap: true
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 4
                                    Text { Layout.fillWidth: true; text: upTrack ? upTrack.title : ""; color: Theme.textPrimary; font.pixelSize: 14; elide: Text.ElideRight }
                                    ArtistLinks {
                                        Layout.fillWidth: true
                                        namePrefix: "nowPlayingUpNext"
                                        fontPixelSize: 12
                                        artistList: upTrack && upTrack.artistList ? upTrack.artistList : []
                                        joinedText: upTrack ? upTrack.artists : ""
                                        fallbackArtistId: upTrack ? Number(upTrack.artistId) : 0
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // One of the chips at the foot of the hero slot, which decide what the slot
    // is showing. Lyrics and Credits are the same control.
    component PanelChip : Rectangle {
        id: chip
        property string label
        property bool   on: false
        signal toggled()

        width: chipLabel.implicitWidth + 16
        height: 26; radius: Theme.radiusChip
        color: chip.on ? Theme.accent : Theme.artScrimStrong
        border.color: chip.on ? "transparent" : Theme.artBorder

        Text {
            id: chipLabel
            anchors.centerIn: parent
            text: chip.label
            color: chip.on ? Theme.accentInk : Theme.artInk
            font.pixelSize: 11; font.bold: true
        }

        HoverHandler { cursorShape: Qt.PointingHandCursor }

        // ReleaseWithinBounds: the default DragThreshold policy takes only a
        // passive grab, so a lyric line under the chip would also seek.
        TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: chip.toggled()
        }
    }

    // A disc-backed icon button for the page's own chrome, as
    // components/BackButton.qml: stacked, on a short window this row scrolls
    // over the artwork, where a bare glyph loses its edge.
    component ChromeButton : Rectangle {
        id: cb
        property string icon
        property string tip
        signal activated()

        implicitWidth: 36
        implicitHeight: 36
        radius: width / 2
        readonly property color restFill:
            Qt.rgba(Theme.surfaceHigh.r, Theme.surfaceHigh.g, Theme.surfaceHigh.b, 0.55)
        readonly property color hoveredFill:
            Qt.rgba(Theme.surfaceHigh.r, Theme.surfaceHigh.g, Theme.surfaceHigh.b, 0.90)
        color: cbHov.hovered ? cb.hoveredFill : cb.restFill

        // The focus ring takes over the border entirely, so a focused button
        // is never ambiguous against a merely hovered one.
        border.width: cb.activeFocus ? 2 : 1
        border.color: cb.activeFocus ? Theme.accent
                    : (cbHov.hovered ? Theme.textSec : Theme.border)

        activeFocusOnTab: true
        Keys.onReturnPressed: cb.activated()
        Keys.onSpacePressed:  cb.activated()

        Behavior on color        { ColorAnimation { duration: Theme.dur(100) } }
        Behavior on border.color { ColorAnimation { duration: Theme.dur(100) } }

        VectorIcon {
            anchors.centerIn: parent
            name: cb.icon
            color: Theme.textPrimary
            width: 18; height: 18
            strokeWidth: 2
        }

        ToolTip.visible: cbHov.hovered && cb.tip.length > 0
        ToolTip.text: cb.tip
        ToolTip.delay: 600

        HoverHandler { id: cbHov; cursorShape: Qt.PointingHandCursor }
        // ReleaseWithinBounds: a DragThreshold TapHandler takes only a passive
        // grab, so anything underneath answers the same tap.
        TapHandler   { gesturePolicy: TapHandler.ReleaseWithinBounds
                       onTapped: cb.activated() }
    }

    component SleepOptionBtn : Rectangle {
        id: optBtn
        objectName: "nowPlayingSleepOption"
        property int minutes
        // Derived, so the unit suffix is one translatable string instead of six
        property string label: qsTr("%1m", "compact duration in minutes").arg(optBtn.minutes)
        Layout.fillWidth: true
        height: 28
        radius: Theme.radiusButton
        color: ma.containsMouse ? Theme.surfaceHov : Theme.surface
        border.color: Theme.border
        border.width: 1
        
        Text {
            anchors.centerIn: parent
            text: optBtn.label
            color: Theme.textPrimary
            font.pixelSize: 12
        }
        
        MouseArea {
            id: ma
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: {
                root.startSleepTimer(optBtn.minutes, false)
                sleepTimerPopup.close()
            }
        }
    }

    // ─── The volume cluster, written once and placed twice ─────────────
    // Two instances, one per home: an item cannot be handed from one Layout to
    // another. The one off screen is invisible, so it is out of the tab chain
    // too. The slider is the bar's PlayerBar.VolumeFlyout.
    component VolumeControls : RowLayout {
        id: vol
        spacing: root.volumeClusterSpacing

        // The speaker and the percentage are one hover target for the flyout,
        // with no dead strip between them. The flyout stands back while the
        // output picker's menu is open, as in the player bar.
        readonly property bool wantFlyout:
            !outPicker.menuVisible && (muteHov.hovered || pctHov.hovered)

        // A Popup is not an Item, so a tree walk cannot find it. Tests reach it
        // through here, which also tells the live one from the offstage copy.
        readonly property alias flyout: volFlyout
        // The two-row half of the cluster, which is what the flyout is
        // parented to and what the suites measure the stack by.
        readonly property alias stack: volStack

        ColumnLayout {
            id: volStack
            objectName: vol.visible ? "nowPlayingVolumeStack"
                                    : "nowPlayingVolumeStackOffstage"
            Layout.alignment: Qt.AlignVCenter
            // Zero: the gap is the readout's own top padding (volumeStackGap),
            // so the two rows are one unbroken hover target.
            spacing: 0

            Item {
                id: muteBtn
                // Named like the picker below, and for the same reason: two of
                // these exist and the name belongs to the one on screen.
                objectName: vol.visible ? "nowPlayingMuteButton"
                                        : "nowPlayingMuteButtonOffstage"
                Layout.preferredWidth:  root.volumeIconSize
                Layout.preferredHeight: root.volumeIconSize
                // Centred in the stack, which is as wide as the readout under
                // it rather than as wide as this.
                Layout.alignment: Qt.AlignHCenter
                activeFocusOnTab: true
                Keys.onReturnPressed: player.setMuted(!player.muted)
                Keys.onSpacePressed:  player.setMuted(!player.muted)
                Rectangle {
                    anchors.fill: parent; anchors.margins: -4; radius: Theme.radiusButton; color: "transparent"
                    border.width: muteBtn.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                VectorIcon {
                    anchors.fill: parent
                    name: player.muted ? "volume-mute" : (player.volume < 0.3 ? "volume-low" : player.volume < 0.7 ? "volume-mid" : "volume-high")
                    color: muteHov.hovered ? Theme.textPrimary : Theme.textSec
                    strokeWidth: 1.5
                }
                // A click still mutes, and the hover is what the flyout reads.
                // A HoverHandler, because the flyout is not a child of this
                // item and cannot see a MouseArea's containsMouse.
                HoverHandler { id: muteHov; cursorShape: Qt.PointingHandCursor }
                MouseArea { anchors.fill: parent; onClicked: player.setMuted(!player.muted); cursorShape: Qt.PointingHandCursor }
            }

            Text {
                objectName: vol.visible ? "nowPlayingVolumePercent"
                                        : "nowPlayingVolumePercentOffstage"
                // Fixed, so a label running from "0%" to "100%" cannot move the
                // buttons or the speaker. Layout.preferredWidth: a layout
                // overwrites a plain width with the Text's implicit one.
                Layout.preferredWidth: root.volumePercentWidth
                Layout.alignment: Qt.AlignHCenter
                topPadding: root.volumeStackGap
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("%1%").arg(Math.round((player.muted ? 0 : player.volume) * 100)
                                          .toLocaleString(Qt.locale(), 'f', 0))
                color: Theme.textDim; font.pixelSize: 12
                HoverHandler { id: pctHov }
            }
        }

        // The output picker, the same PlayerBar component the bar puts next to
        // its volume readout: local outputs and cast targets in one list.
        PlayerBar.OutputPicker {
            id: outPicker
            // Two of these exist and one of them is on screen. The name the
            // other suites look the page's picker up by belongs to that one.
            objectName: vol.visible ? "nowPlayingOutputButton"
                                    : "nowPlayingOutputButtonOffstage"
            Layout.alignment: Qt.AlignVCenter
            size: 20
        }

        // The slider, over the page. Parented to the stack so it comes up
        // centred on both rows, and upward, over the seek bar. `vol.visible &&`
        // keeps the offstage copy from ever opening one.
        PlayerBar.VolumeFlyout {
            id: volFlyout
            objectName: vol.visible ? "nowPlayingVolumeFlyout"
                                    : "nowPlayingVolumeFlyoutOffstage"
            parent: volStack
            pointedAt: vol.visible && vol.wantFlyout
            sliderLength:    root.volumeSliderLength
            sliderThickness: root.volumeSliderThickness
        }
    }

    component CtrlBtn : Item {
        id: ctrlBtn
        property string icon; property int size: 24; property bool active: false
        signal clicked()
        width: size+20; height: size+20
        activeFocusOnTab: true
        Keys.onReturnPressed: clicked()
        Keys.onSpacePressed:  clicked()
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: ctrlBtn.activeFocus ? 2 : 0
            border.color: Theme.accent
        }
        VectorIcon {
            anchors.centerIn: parent
            name: parent.icon
            color: parent.active ? Theme.accent : hov.hovered ? Theme.textPrimary : Theme.textSec
            width: parent.size
            height: parent.size
            strokeWidth: 1.5
        }
        HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: parent.clicked() }
    }

    // ─── Artist links ──────────────────────────────────────────────────
    // TidalBridge::trackToMap() carries the whole artist list as [{id, name}]. A
    // track map without it, such as a recently-played entry saved to disk, has
    // only the joined `artists` string and one `artistId` for ArtistLinks.
    readonly property var artistList:
        (hasTrack && track.artistList && track.artistList.length > 0) ? track.artistList : []

    function navigateTo(page, params) {
        Window.window.navigate(page, params || {})
    }

    // Maps the current "playing from" source to a navigation target, or null if
    // the source can't be navigated to. Param names match each detail page.
    function sourceNav() {
        var t = player.sourceType
        if (t === "album")      return { page: "album",      params: { albumId: Number(player.sourceId) } }
        if (t === "artist")     return { page: "artist",     params: { artistId: Number(player.sourceId) } }
        if (t === "playlist")   return { page: "playlist",   params: { playlistUuid: player.sourceId, playlistTitle: player.sourceName, coverUrl: "", playlistType: "" } }
        if (t === "mix")        return { page: "mix",        params: { mixId: player.sourceId } }
        if (t === "radio")      return { page: "radio",      params: { radioTitle: player.sourceName, trackId: Number(player.sourceId) } }
        if (t === "collection") return { page: "collection", params: { activeTab: 0 } }
        return null
    }
    function goToSource() {
        var n = sourceNav()
        if (n) navigateTo(n.page, n.params)
    }
}
