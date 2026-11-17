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
    readonly property int pageMargin: Theme.space12
    readonly property int columnGap:  Theme.space16

    readonly property real contentWidth: Math.max(0, width - 2 * pageMargin)

    // The transport row needs 344px (248 of buttons and six 16px gaps), and
    // side by side the text column gets too little of the content width for
    // that. Below this page width the cover moves above the text.
    readonly property int  stackBreakpoint: 1000
    readonly property bool stacked: width < stackBreakpoint

    // The vertical gap between the two blocks once they are stacked, which is
    // also what stackedCoverRoom has to leave room for.
    readonly property int stackGap: Theme.space8

    // ─── Crossing the breakpoint ───────────────────────
    // How stacked the page is: 0 with the cover beside the text, 1 with it
    // above. Everything that moves in the rearrangement is lerped off this one
    // clock. A docked panel takes the artwork's place and moves nothing; the
    // reading view is the stacked arrangement at every width.
    readonly property bool stackedLayout: stacked || readingView
    property real stackness: stackedLayout ? 1 : 0

    Behavior on stackness {
        NumberAnimation { duration: Theme.dur(Theme.motionMedium); easing.type: Easing.OutCubic }
    }

    // ─── Artwork or lyrics ─────────────────────────────
    // How far the hero slot is towards being a page of lyrics: 0 artwork, 1
    // lyrics. The second clock, at the same duration as `stackness`, so the two
    // move as one when opening the lyrics also stacks the page.
    property real lyricsness: showLyrics ? 1 : 0

    Behavior on lyricsness {
        NumberAnimation { duration: Theme.dur(Theme.motionMedium); easing.type: Easing.OutCubic }
    }

    // The same for the credits, and read the same way: 0 artwork, 1 credits.
    property real creditsness: showCredits ? 1 : 0

    Behavior on creditsness {
        NumberAnimation { duration: Theme.dur(Theme.motionMedium); easing.type: Easing.OutCubic }
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
        NumberAnimation { duration: Theme.dur(Theme.motionMedium); easing.type: Easing.OutCubic }
    }

    // The same, between the windowed panel's value and the reading view's.
    function rblend(panelValue, reading) {
        return panelValue + (reading - panelValue) * root.readingness
    }

    // Stacked, the cover takes the height the page leaves it, floored at 180;
    // side by side 45% of the content width. Both stop at coverCap: 420, or in
    // fullscreen the height the page has, so the art fills the screen.
    readonly property real sideRoom: height - 2 * pageMargin - headerRow.height - 32
    readonly property real coverCap: fullScreen ? Math.max(420, sideRoom) : 420
    readonly property real sideCoverSize:    Math.min(contentWidth * 0.45, coverCap)
    readonly property real stackedCoverSize: Math.min(contentWidth, coverCap,
                                                      Math.max(180, stackedCoverRoom))
    readonly property real coverSize: blend(sideCoverSize, stackedCoverSize)

    // ─── What a panel asks for instead ─────────────────
    // The size the lines are set in: 18 docked, 28 in the reading view, where
    // they are read from further back. Lerped, so it grows with the slot.
    readonly property int  lyricsSize:  Theme.fontSection
    readonly property int  readingSize: Theme.fontDisplay
    readonly property real lyricLineSize: rblend(lyricsSize, readingSize)

    // A measure, not a square: 640px is about 70 characters at 18px, past the
    // longest lyric line, and wider is not more readable. Held in characters,
    // so the reading size gets a wider one.
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

    // A docked panel's box. Side by side it is the artwork's column at the
    // height of the pair; stacked it is the measure wide and the artwork's
    // height tall. Neither moves the text column or Up Next.
    readonly property real dockedWidth:  blend(sideCoverSize, lyricsWidth)
    readonly property real dockedHeight: blend(sideBodyHeight, Math.max(stackedCoverSize, 280))

    // The slot both live in: square for the artwork, a column for a panel.
    readonly property real slotWidth:  lblend(coverSize, rblend(dockedWidth, lyricsWidth))
    readonly property real slotHeight: lblend(coverSize, rblend(dockedHeight, lyricsHeight))

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
    // are held on there. Not `slotHeight`: this must not be one of the things
    // the stack animation or a panel is moving.
    readonly property real sideBodyHeight: Math.max(sideCoverSize, infoHeight)

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
        return w >= transportFixedWidth + transportGaps * Theme.space4 ? Theme.space4 : Theme.space2
    }

    // ─── Where the volume lives ────────────────────────
    // A short cluster with two homes: the end of the transport row or a row of
    // its own. The speaker sits over the percentage and the slider is a flyout
    // over both. The picker stays beside them: three high outgrows the row.
    readonly property int volumeIconSize:       18
    readonly property int volumePercentWidth:   36
    readonly property int volumeOutputWidth:    32
    readonly property int volumeClusterSpacing: Theme.space3
    // The gap between speaker and readout, paid as the readout's top padding so
    // the hover target has no dead strip. The bar's extra lift on the same 4 is
    // deliberate: tst_output_picker.qml requires both to render alike.
    readonly property int volumeStackGap:        Theme.space1
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

    // Lyrics state: "none", "loading", "ready", "unavailable", and
    // "instrumental" when another site knows the track has no words.
    property string lyricsState: "none"
    property var    lyricsData:  []   // [{ms, text}] for timed; [{ms: 0, text}] for plain
    property bool   lyricsIsTimed: false
    // -1 before the first timed line starts: nothing is lit, and the view
    // holds line 0 (followLine).
    property int    currentLyricLine: -1
    property bool   userScrolled: false
    property bool   ignoreLyricsSync: false
    // Set when the words came from another site: its name and the page.
    property string lyricsSource: ""
    // The timings were made here from plain lyrics, and may be off.
    property bool   lyricsAutoSynced: false
    // Bumped by every loadLyrics(), so an answer for an earlier one is dropped.
    property int    lyricsSerial: 0
    property string lyricsSourceUrl: ""

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
        if (root.lyricsData.length === 0) return
        // Instant: a re-wrap is a correction, and a correction that travels
        // reads as the words drifting on their own.
        centreLyricLine(root.followLine(), false)
    }

    // The line the view keeps centred: the one being sung, or the first.
    function followLine() { return Math.max(root.currentLyricLine, 0) }

    // A scroll that ends with the followed line exactly where centring puts it
    // (in the intro: back at the top) is a resync. Near it is still a scroll.
    function resumeIfCentred() {
        if (!root.userScrolled || !root.lyricsIsTimed) return
        var line = root.followLine()
        var item = lyricsView.itemAtIndex(line)
        if (!item) return
        var was = lyricsView.contentY
        var want = root.lyricCentreY(line)
        lyricsView.contentY = was
        if (Math.abs(want - was) > 2) return
        root.userScrolled = false
        root.centreLyricLine(line, true)
    }

    // Puts one line in the middle of the panel, animated when the song moved
    // on. Lines wrap to different heights, so the target is read back from
    // positionViewAtIndex and then travelled to.
    NumberAnimation {
        id: lyricsScroll
        target: lyricsView
        property: "contentY"
        duration: Theme.dur(Theme.motionMedium)
        easing.type: Easing.OutCubic
        // Lines built on the way can move the target on Qt 6.4; land on it.
        onFinished: if (!root.userScrolled) lyricsView.contentY = root.lyricCentreY(root.followLine())
    }

    // positionViewAtIndex finds the line; Qt 6.4 then leaves it a few px off
    // the middle, so the offset is worked out from the line itself.
    function lyricCentreY(line) {
        lyricsView.positionViewAtIndex(line, ListView.Center)
        var item = lyricsView.itemAtIndex(line)
        if (!item) return lyricsView.contentY
        var top = lyricsView.originY - lyricsView.topMargin
        var bottom = Math.max(top, lyricsView.originY + lyricsView.contentHeight
                                   + lyricsView.bottomMargin - lyricsView.height)
        return Math.max(top, Math.min(bottom, item.y + item.height / 2 - lyricsView.height / 2))
    }

    function centreLyricLine(line, animated) {
        if (line < 0 || line >= root.lyricsData.length) return
        lyricsScroll.stop()
        var was = lyricsView.contentY
        var want = root.lyricCentreY(line)
        if (!animated) {
            lyricsView.contentY = want
            return
        }
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
        var serial = ++lyricsSerial
        lyricsState = "loading"
        lyricsSource = ""
        lyricsSourceUrl = ""
        lyricsAutoSynced = false
        var forId = track.id
        bridge.fetchLyrics(track.id, function(result, err) {
            if (!root.lyricsCurrent(forId, serial)) return
            var rawText = err ? "" : (result.text || "")
            if (rawText.length > 0 && result.timed) { root.showLyricsText(rawText, true); return }
            // Tidal's plain words show at once; the sites are still asked for synced ones.
            if (rawText.length > 0) {
                root.showLyricsText(rawText, false)
                root.autoSyncLyrics(forId, serial, rawText)
            }
            root.findLyricsElsewhere(forId, serial, rawText.length > 0)
        })
    }

    function lyricsCurrent(forId, serial) {
        return serial === root.lyricsSerial && root.hasTrack && root.track.id === forId
    }

    function lyricsSitesOn() { return prefs.lyricsLrclib || prefs.lyricsOtherSites }

    // Synced lyrics from a site beat Tidal's plain ones and auto-synced ones;
    // plain lyrics from a site are used only when Tidal has none.
    function findLyricsElsewhere(forId, serial, havePlain) {
        if (!lyricsSitesOn()) { if (!havePlain) lyricsState = "unavailable"; return }
        bridge.findLyrics(root.track, function(result, err) {
            if (!root.lyricsCurrent(forId, serial)) return
            var text = err ? "" : (result.text || "")
            if (text.length > 0 && result.timed) {
                // Real timings: the plain lyrics need no syncing any more.
                if (havePlain && prefs.lyricsAutoSync) bridge.cancelAutoSync()
                root.lyricsSource    = result.source || ""
                root.lyricsSourceUrl = result.url || ""
                root.lyricsAutoSynced = false
                root.showLyricsText(text, true)
                return
            }
            if (havePlain) return
            if (!err && result.instrumental) { root.lyricsState = "instrumental"; return }
            if (text.length === 0) { root.lyricsState = "unavailable"; return }
            root.lyricsSource    = result.source || ""
            root.lyricsSourceUrl = result.url || ""
            root.showLyricsText(text, false)
            root.autoSyncLyrics(forId, serial, text)
        })
    }

    // Plain lyrics timed against the audio, here. Shown only when the aligner
    // trusts its result, and never over real timings that came meanwhile.
    function autoSyncLyrics(forId, serial, text) {
        if (!prefs.lyricsAutoSync) return
        bridge.autoSyncLyrics(forId, text, function(result, err) {
            if (!root.lyricsCurrent(forId, serial)) return
            if (err || !result.kept || !result.lrc || root.lyricsIsTimed) return
            root.showLyricsText(result.lrc, true)
            root.lyricsAutoSynced = true
        })
    }

    function showLyricsText(rawText, timed) {
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
        currentLyricLine = -1
    }

    // A site switched on may have what is missing; auto-sync switched off
    // takes its timings away, switched on may add them.
    function lyricsSwitchChanged() {
        var plainShown = lyricsState === "ready" && (!lyricsIsTimed || lyricsAutoSynced)
        if (lyricsState === "unavailable" || plainShown) loadLyrics()
    }
    Connections {
        target: prefs
        function onLyricsLrclibChanged()     { if (prefs.lyricsLrclib) root.lyricsSwitchChanged() }
        function onLyricsOtherSitesChanged() { if (prefs.lyricsOtherSites) root.lyricsSwitchChanged() }
        function onLyricsAutoSyncChanged()   { root.lyricsSwitchChanged() }
    }

    // The next track's audio is analysed ahead only while lyrics are on screen.
    readonly property bool lyricsLookAhead: showLyrics && prefs.lyricsAutoSync
    onLyricsLookAheadChanged: bridge.setLyricsLookAhead(lyricsLookAhead)
    Component.onDestruction: bridge.setLyricsLookAhead(false)

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
    // comes back untouched. AlbumPage.releaseText() is the same.
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
            var found = -1
            for (var i = 0; i < root.lyricsData.length; i++) {
                if (root.lyricsData[i].ms <= pos) found = i
                else break
            }
            if (found !== root.currentLyricLine) {
                root.currentLyricLine = found
                if (!root.userScrolled)
                    root.centreLyricLine(root.followLine(), true)
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
        function onDownloadCancelled(id)       { if (root.hasTrack && id === root.track.id) root.dlState = "idle" }
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
    Behavior on gradientTop { ColorAnimation { duration: Theme.dur(Theme.motionSlow) } }

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
            spacing: Theme.space8

            // The way out, and the way to make the page the whole screen. The
            // down-arrow mirrors the player bar's up-arrow.
            RowLayout {
                id: headerRow
                Layout.fillWidth: true
                spacing: Theme.space3

                IconButton {
                    objectName: "nowPlayingCollapse"
                    icon: "chevron-down"
                    backed: true
                    pad: Theme.space5
                    iconColor: Theme.textPrimary
                    label: qsTr("Close now playing", "returns to the page you came from")
                    onClicked: Window.window.goBack()
                }

                Item { Layout.fillWidth: true }

                IconButton {
                    objectName: "nowPlayingFullscreen"
                    icon: root.fullScreen ? "fullscreen-exit" : "fullscreen"
                    backed: true
                    pad: Theme.space5
                    iconColor: Theme.textPrimary
                    label: root.fullScreen
                         ? qsTr("Leave fullscreen", "button, restores the window")
                         : qsTr("Fullscreen", "button, fills the screen with this page")
                    onClicked: root.toggleFullScreen()
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
                    CoverArt {
                        objectName: "nowPlayingArt"
                        anchors.centerIn: parent
                        width:  root.coverSize
                        height: root.coverSize
                        opacity: 1 - root.panelness
                        visible: opacity > 0.01
                        // The large rendition where the map has it: the
                        // 320px one goes soft at 420 and more.
                        source: hasTrack ? (track.coverUrl1280 || track.coverUrl || "") : ""
                    }

                    // Lyrics panel. This one does take the whole slot, which is
                    // the point: the measure and the height it gets are the
                    // slot's, worked out above.
                    Rectangle {
                        id: lyricsPanel
                        objectName: "nowPlayingLyricsPanel"
                        anchors.fill: parent
                        // Takes the cover's slot, so it takes the cover's corner too
                        radius: Theme.radiusSmall
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
                            anchors.margins: Theme.space4
                            // Content margins, not a smaller viewport: a line
                            // can be drawn anywhere in the box and still be
                            // scrolled clear of the chips.
                            topMargin: root.lyricsHeaderRoom
                            bottomMargin: root.lyricsFooterRoom
                            clip: true
                            model: root.lyricsData
                            // The gap between lines rides the type size.
                            spacing: Math.round(Theme.space2 * root.lyricLineSize / root.lyricsSize)
                            cacheBuffer: 200

                            onMovingChanged: if (moving) root.userScrolled = true
                            onMovementEnded: root.resumeIfCentred()

                            // Plain lyrics only: synced ones follow the song.
                            // In the right margin, from the top corner down to
                            // the chips' band, so it never sits over a chip.
                            ScrollBar.vertical: ScrollBar {
                                id: lyricsBar
                                objectName: "nowPlayingLyricsScrollBar"
                                parent: lyricsPanel
                                x: lyricsPanel.width - width - 3
                                y: 12
                                height: Math.max(0, lyricsPanel.height - y - root.lyricsFooterRoom)
                                policy: !root.lyricsIsTimed && root.lyricsState === "ready"
                                        && lyricsView.visibleArea.heightRatio < 1
                                        ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                                visible: policy === ScrollBar.AlwaysOn
                                padding: Theme.space1
                                // Set straight on contentY, which never starts
                                // the view moving, so say it here.
                                onPressedChanged: if (pressed) root.userScrolled = true

                                contentItem: Rectangle {
                                    implicitWidth: 4
                                    radius: width / 2
                                    color: lyricsBar.pressed || lyricsBar.hovered ? Theme.textSec : Theme.textDim
                                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.motionFast) } }
                                }
                                background: Rectangle { implicitWidth: 10; color: "transparent" }
                            }

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
                                Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.motionMedium); easing.type: Easing.OutCubic } }
                                Behavior on color   { ColorAnimation  { duration: Theme.dur(Theme.motionMedium) } }

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
                                color: Theme.textDim; font.pixelSize: Theme.fontBody
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: root.lyricsState === "unavailable"
                                text: qsTr("No lyrics available")
                                color: Theme.textDim; font.pixelSize: Theme.fontBody
                            }
                            Text {
                                objectName: "nowPlayingLyricsInstrumental"
                                anchors.centerIn: parent
                                visible: root.lyricsState === "instrumental"
                                text: qsTr("Instrumental", "a track with no words")
                                color: Theme.textDim; font.pixelSize: Theme.fontBody
                            }
                        }

                        // Resync button
                        Rectangle {
                            objectName: "nowPlayingLyricsResync"
                            visible: root.userScrolled && root.lyricsIsTimed && root.lyricsData.length > 0
                            anchors.bottom: parent.bottom
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottomMargin: Theme.space3
                            width: rsText.implicitWidth + 20; height: 28; radius: Theme.radiusFull
                            color: Theme.artScrimStrong
                            border.color: Theme.artBorder
                            Text {
                                id: rsText
                                anchors.centerIn: parent
                                text: qsTr("Resync")
                                color: Theme.artInk; font.pixelSize: Theme.fontMeta
                            }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            // ReleaseWithinBounds: the default DragThreshold
                            // policy takes only a passive grab, and the lyric
                            // line under this chip would answer the same tap.
                            TapHandler {
                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: {
                                    root.userScrolled = false
                                    root.centreLyricLine(root.followLine(), true)
                                }
                            }
                        }

                        // Where the words came from, when it was not Tidal.
                        // Bottom left, clear of the chips in the other corner.
                        Text {
                            id: lyricsSourceText
                            objectName: "nowPlayingLyricsSource"
                            readonly property string sourceUrl: root.lyricsSourceUrl
                            visible: root.lyricsState === "ready" && root.lyricsSource.length > 0
                                     && !(root.userScrolled && root.lyricsIsTimed)
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: Theme.space4
                            anchors.bottomMargin: Theme.space3
                            height: 26
                            width: Math.min(implicitWidth,
                                            Math.max(0, parent.width - panelChips.width - 46))
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            text: qsTr("Lyrics from %1", "%1 is a lyrics website").arg(root.lyricsSource)
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                            font.underline: sourceHover.hovered && sourceUrl.length > 0
                            HoverHandler {
                                id: sourceHover
                                cursorShape: parent.sourceUrl.length > 0 ? Qt.PointingHandCursor
                                                                         : Qt.ArrowCursor
                            }
                            TapHandler {
                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: if (parent.sourceUrl.length > 0) app.openUrl(parent.sourceUrl)
                            }
                        }

                        // Timings made here, from plain lyrics. Beside the source
                        // when there is one, and hidden with it during a scroll.
                        Text {
                            objectName: "nowPlayingLyricsAutoSynced"
                            visible: root.lyricsState === "ready" && root.lyricsAutoSynced
                                     && !root.userScrolled
                            anchors.left: lyricsSourceText.visible ? lyricsSourceText.right : parent.left
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: lyricsSourceText.visible ? Theme.space3 : Theme.space4
                            anchors.bottomMargin: Theme.space3
                            height: 26
                            width: Math.min(implicitWidth, Math.max(0, parent.width - panelChips.width - 46
                                       - (lyricsSourceText.visible ? lyricsSourceText.width + 10 : 0)))
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            text: qsTr("Synced automatically, may be off")
                            color: Theme.textDim; font.pixelSize: Theme.fontMicro
                        }
                    }

                    // Credits panel. The other tab over the same slot, built
                    // like the lyrics panel: same walls, clock, content margins
                    // and reading view.
                    Rectangle {
                        id: creditsPanel
                        objectName: "nowPlayingCreditsPanel"
                        anchors.fill: parent
                        radius: Theme.radiusSmall
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
                        readonly property int  labelSize: Math.round(Theme.fontMicro * typeScale)
                        readonly property int  nameSize:  Math.round(Theme.fontBody * typeScale)
                        readonly property int  factSize:  Math.round(Theme.fontMeta * typeScale)
                        // Same flip, same reason, as the lyric line's.
                        readonly property int  align: root.readingness >= 0.5
                                                      ? Text.AlignHCenter
                                                      : Text.AlignLeft

                        Flickable {
                            id: creditsFlick
                            objectName: "nowPlayingCreditsView"
                            anchors.fill: parent
                            anchors.margins: Theme.space4
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
                                spacing: Math.round(Theme.space4 * creditsPanel.typeScale)

                                // Who played what. The group's type is the
                                // label's own word for the role, so it is data
                                // and is not translated.
                                Repeater {
                                    model: root.creditsGroups
                                    delegate: ColumnLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: Theme.spaceHalf

                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.type || ""
                                            color: Theme.textDim
                                            font.pixelSize: creditsPanel.labelSize
                                            font.bold: true
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
                                    Layout.topMargin: Math.round(Theme.space2 * creditsPanel.typeScale)
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
                        id: panelChips
                        objectName: "nowPlayingPanelChips"
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        anchors.margins: Theme.space3
                        spacing: Theme.space2

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
                            visible: root.hasTrack && root.lyricsState !== "unavailable"
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

                // Places the text column. The layout itself is never moved: on
                // Qt 6.5 and 6.6 a moved layout publishes its implicit height
                // inside the move, which infoY is worked out from.
                Item {
                    id: infoBox
                    objectName: "nowPlayingInfoColumn"
                    x: root.infoX
                    y: root.infoY
                    width: root.infoWidth
                    height: root.infoHeight
                }

                ColumnLayout {
                    id: infoColumn
                    parent: infoBox
                    width: root.infoWidth
                    spacing: Theme.space6

                    RowLayout {
                        id: npTransportRow
                        Layout.fillWidth: true
                        spacing: Theme.space4

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space2
                            // "Playing from" link: back to the playlist, album,
                            // mix or liked songs it started from.
                            Text {
                                id: sourceLink
                                objectName: "nowPlayingSourceLink"
                                visible: hasTrack && player.sourceName.length > 0
                                activeFocusOnTab: visible
                                Keys.onReturnPressed: goToSource()
                                Keys.onSpacePressed:  goToSource()
                                Accessible.role: Accessible.Link
                                Accessible.name: text
                                Accessible.onPressAction: goToSource()
                                font.underline: activeFocus
                                // A search has only its query for a name, so it says so.
                                text: player.sourceType === "search"
                                      ? qsTr("Playing from: search “%1”",
                                             "the track was started from the search results").arg(player.sourceName)
                                      : qsTr("Playing from: %1").arg(player.sourceName)
                                color: sourceLinkHov.hovered || activeFocus ? Theme.textPrimary : Theme.textDim
                                font.pixelSize: Theme.fontMeta
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
                                text: hasTrack ? track.title : qsTranslate("PlayerBar", "No track playing")
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontDisplay; font.bold: true; Layout.fillWidth: true
                                // Two lines before it elides: a long title is
                                // most of what this page is for.
                                wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                                font.underline: titleHit.containsMouse && hasTrack && Number(track.albumId) > 0
                                activeFocusOnTab: hasTrack && Number(track.albumId) > 0
                                Keys.onReturnPressed: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                Keys.onSpacePressed:  if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                Rectangle {
                                    x: -4; y: -4
                                    width:  Math.min(parent.width, parent.contentWidth) + 8
                                    height: parent.height + 8
                                    radius: Theme.radiusMedium; color: "transparent"
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
                                visible: hasTrack
                                Layout.fillWidth: true
                                namePrefix: "nowPlaying"
                                fontPixelSize: Theme.fontSection
                                artistList: root.artistList
                                joinedText: hasTrack ? track.artists : ""
                                fallbackArtistId: hasTrack ? Number(track.artistId) : 0
                            }
                            Text {
                                id: albumLink
                                visible: hasTrack
                                text: hasTrack ? track.albumTitle : ""; color: Theme.textSec; font.pixelSize: Theme.fontBody
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
                                    radius: Theme.radiusMedium; color: "transparent"
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
                            objectName: "nowPlayingDownloadButton"
                            visible: root.hasTrack
                            Accessible.role: Accessible.Button
                            Accessible.name: qsTr("Download")
                            Accessible.onPressAction: if (root.hasTrack && root.dlState !== "busy") downloader.downloadTrack(root.track)
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
                                color: root.dlState === "error" ? Theme.redText
                                       : (npDlHov.hovered ? Theme.textPrimary : Theme.textSec)
                                width: 24; height: 24
                            }
                            VectorIcon {
                                anchors.centerIn: parent
                                visible: root.dlState === "done"
                                name: "check"; color: Theme.green
                                width: 24; height: 24
                            }
                            Item {
                                id: npSpinner
                                anchors.centerIn: parent
                                width: 22; height: 22
                                visible: root.dlState === "busy"
                                Rectangle {
                                    width: 3.5; height: 9; radius: width / 2
                                    anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
                                    color: Theme.accent
                                }
                                RotationAnimator {
                                    target: npSpinner; from: 0; to: 360; duration: Theme.dur(Theme.motionSlow * 2)
                                    loops: Theme.reduceMotion ? 1 : Animation.Infinite
                                    running: root.dlState === "busy"
                                }
                            }
                            HoverHandler { id: npDlHov; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: if (root.hasTrack && root.dlState !== "busy") downloader.downloadTrack(root.track) }
                            ToolTip.visible: npDlHov.hovered && root.dlState === "error"
                            ToolTip.text: qsTr("Download failed. Click to retry.")
                            ToolTip.delay: Theme.tooltipDelay
                        }

                        IconButton {
                            id: npLikeBtn
                            objectName: "nowPlayingLikeButton"
                            visible: root.hasTrack
                            icon: root.isLiked ? "heart-filled" : "heart"
                            size: 24; pad: Theme.space5
                            active: root.isLiked
                            label: root.isLiked ? qsTranslate("PlayerBar", "Unlike track")
                                                : qsTranslate("PlayerBar", "Like track")
                            // On the row: IconButton has its own hover tool
                            // tip, and two uses of the shared one fight.
                            onClicked: root.favoriteAction.toggleTrack(root.track.id, root.isLiked,
                                                                      npTransportRow)
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space3

                        QualityBadge { withTier: true }

                        Item { Layout.fillWidth: true } // Pusher

                        // Sleep Timer button. The clock is concentric with the
                        // pill's left cap, so the ring of air around it is
                        // even. The text end keeps the corner radius.
                        Rectangle {
                            id: sleepTimerBtn
                            objectName: "nowPlayingSleepTimerButton"
                            // A running timer stays reachable after the queue ends.
                            visible: root.hasTrack || root.sleepTimerActive
                            // height minus glyphSize has to stay even, so the
                            // ring round the glyph is a whole number of pixels:
                            // anchor centring rounds.
                            height: 30
                            // What the pill actually draws: Theme.radiusFull is
                            // a "round it all the way" sentinel, and Qt clamps
                            // it to half the shorter side.
                            readonly property real cornerRadius:
                                Math.min(Theme.radiusFull, height / 2)
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

                            // Rest and hover as a pair, as on a backed IconButton.
                            // Counting, the hover is the accent at 0.36:
                            // accentTint to accentWash is too small a step.
                            readonly property color restFill:
                                root.sleepTimerActive ? Theme.accentTint : Theme.surfaceHigh
                            readonly property color hoverFill:
                                root.sleepTimerActive
                                    ? Qt.rgba(Theme.accent.r, Theme.accent.g,
                                              Theme.accent.b, 0.36)
                                    : Qt.tint(Theme.surfaceHigh, Theme.hoverFill)
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
                            Behavior on color        { ColorAnimation { duration: Theme.dur(Theme.motionFast) } }
                            Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.motionFast) } }

                            // Never drawn. One clock per digit, a line each, so its
                            // width is the widest clock as a Text lays it out. A
                            // summed advance leaves out the last glyph's overhang.
                            Text {
                                id: sleepClockRuler
                                visible: false
                                font: sleepLabel.font
                                textFormat: Text.PlainText
                                text: {
                                    var lines = []
                                    for (var d = 0; d < 10; ++d)
                                        lines.push(sleepLabel.clockShape.replace(/0/g, d))
                                    return lines.join("\n")
                                }
                            }

                            RowLayout {
                                id: sleepTimerRow
                                objectName: "nowPlayingSleepTimerRow"
                                // Anchored to the left edge, not centred: the
                                // two ends are padded differently.
                                anchors.left: parent.left
                                anchors.leftMargin: sleepTimerBtn.leadInset
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.space2

                                VectorIcon {
                                    objectName: "nowPlayingSleepTimerIcon"
                                    name: "clock"
                                    color: root.sleepTimerActive ? Theme.accentText : Theme.textSec

                                    // Heavier than VectorIcon's 1.8 default, which
                                    // draws too thin a line at this size.

                                    // Layout.preferredWidth/Height: a layout imposes
                                    // VectorIcon's implicit 24 over a plain
                                    // width/height. Both, so the clock stays square.
                                    Layout.preferredWidth:  sleepTimerBtn.glyphSize
                                    Layout.preferredHeight: sleepTimerBtn.glyphSize
                                }

                                Text {
                                    id: sleepLabel
                                    objectName: "nowPlayingSleepTimerLabel"
                                    Component.onCompleted: Theme.tabularFigures(sleepLabel)
                                    text: root.sleepTimerActive ?
                                          (root.sleepStopAtEndOfTrack ? qsTr("End of track") : root.formatSleepTime(root.sleepTimeLeft)) :
                                          qsTr("Sleep timer")
                                    // The pill is sized from this label. While
                                    // counting it holds the widest clock of its
                                    // shape, "mm:ss" or "h:mm:ss".
                                    readonly property string clockShape:
                                        text.indexOf(":") !== text.lastIndexOf(":")
                                            ? "0:00:00" : "00:00"
                                    Layout.preferredWidth:
                                        (root.sleepTimerActive && !root.sleepStopAtEndOfTrack)
                                            ? Math.ceil(sleepClockRuler.implicitWidth)
                                            : implicitWidth
                                    horizontalAlignment: Text.AlignHCenter
                                    color: root.sleepTimerActive ? Theme.accentText : Theme.textSec
                                    font.pixelSize: Theme.fontMicro
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

                            activeFocusOnTab: true
                            Keys.onReturnPressed: sleepTimerPopup.openFromKeyboard()
                            Keys.onSpacePressed:  sleepTimerPopup.openFromKeyboard()
                            Accessible.role: Accessible.Button
                            Accessible.name: sleepLabel.text
                            Accessible.onPressAction: sleepTimerPopup.open()
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: -Theme.space1
                                radius: height / 2
                                color: "transparent"
                                border.width: sleepTimerBtn.activeFocus ? 2 : 0
                                border.color: Theme.accent
                            }
                        }
                    }

                    Popup {
                        id: sleepTimerPopup
                        objectName: "nowPlayingSleepTimerPopup"
                        parent: sleepTimerBtn
                        x: sleepTimerBtn.width - width
                        width: 260
                        padding: Theme.space3

                        // ── how tall it is, and which side of the pill it opens on ──
                        // Both come from the content's implicit height. Binding
                        // `y` to this popup's own `height` is a polish loop on
                        // Qt 6.4, where the positioner sets that height.
                        readonly property real popupHeight:
                            contentCol.implicitHeight + topPadding + bottomPadding
                        height: popupHeight

                        // The gap to the pill, whichever side it lands on.
                        readonly property real pillGap: Theme.space2

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

                        // From the keyboard the first choice takes focus, and
                        // closing hands it back to the pill.
                        property bool fromKeyboard: false
                        function openFromKeyboard() { fromKeyboard = true; open() }
                        onOpened: {
                            if (!fromKeyboard) return
                            var first = root.sleepTimerActive ? sleepCancel : firstSleepOption
                            first.forceActiveFocus(Qt.TabFocusReason)
                        }
                        onClosed: {
                            if (fromKeyboard) sleepTimerBtn.forceActiveFocus(Qt.TabFocusReason)
                            fromKeyboard = false
                        }
                    
                        background: Rectangle {
                            color: Theme.surfaceHigh
                            border.color: Theme.border
                            border.width: 1
                            radius: Theme.radiusLarge
                        
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
                            spacing: Theme.space3

                            Text {
                                text: qsTr("Sleep timer")
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontBody
                                font.bold: true
                                Layout.alignment: Qt.AlignLeft
                            }

                            // Options container when timer is INACTIVE
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.space3
                                visible: !root.sleepTimerActive

                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 3
                                    columnSpacing: Theme.space2
                                    rowSpacing: Theme.space2
                                
                                    // A preset starts at once; the slider below needs Start.
                                    PillButton { id: firstSleepOption; objectName: "nowPlayingSleepOption"; readonly property int minutes: 5
                                                 Layout.fillWidth: true; compact: true; accent: false
                                                 text: root.sleepPresetLabel(minutes); Accessible.name: root.sleepPresetName(minutes)
                                                 onClicked: root.startSleepPreset(minutes) }
                                    PillButton { objectName: "nowPlayingSleepOption"; readonly property int minutes: 15
                                                 Layout.fillWidth: true; compact: true; accent: false
                                                 text: root.sleepPresetLabel(minutes); Accessible.name: root.sleepPresetName(minutes)
                                                 onClicked: root.startSleepPreset(minutes) }
                                    PillButton { objectName: "nowPlayingSleepOption"; readonly property int minutes: 30
                                                 Layout.fillWidth: true; compact: true; accent: false
                                                 text: root.sleepPresetLabel(minutes); Accessible.name: root.sleepPresetName(minutes)
                                                 onClicked: root.startSleepPreset(minutes) }
                                    PillButton { objectName: "nowPlayingSleepOption"; readonly property int minutes: 45
                                                 Layout.fillWidth: true; compact: true; accent: false
                                                 text: root.sleepPresetLabel(minutes); Accessible.name: root.sleepPresetName(minutes)
                                                 onClicked: root.startSleepPreset(minutes) }
                                    PillButton { objectName: "nowPlayingSleepOption"; readonly property int minutes: 60
                                                 Layout.fillWidth: true; compact: true; accent: false
                                                 text: root.sleepPresetLabel(minutes); Accessible.name: root.sleepPresetName(minutes)
                                                 onClicked: root.startSleepPreset(minutes) }
                                    PillButton { objectName: "nowPlayingSleepOption"; readonly property int minutes: 90
                                                 Layout.fillWidth: true; compact: true; accent: false
                                                 text: root.sleepPresetLabel(minutes); Accessible.name: root.sleepPresetName(minutes)
                                                 onClicked: root.startSleepPreset(minutes) }
                                }

                                Rectangle {
                                    id: sleepEndOfTrack
                                    objectName: "nowPlayingSleepEndOfTrack"
                                    Layout.fillWidth: true
                                    height: 32
                                    radius: Theme.radiusMedium
                                    color: maEndOfTrack.containsMouse ? Qt.tint(Theme.surface, Theme.hoverFill) : Theme.surface
                                    border.color: activeFocus ? Theme.accent : Theme.border
                                    border.width: activeFocus ? 2 : 1
                                    function activate() {
                                        root.startSleepTimer(0, true)
                                        sleepTimerPopup.close()
                                    }
                                    activeFocusOnTab: true
                                    Keys.onReturnPressed: activate()
                                    Keys.onSpacePressed:  activate()
                                    Accessible.role: Accessible.Button
                                    Accessible.name: endOfTrackText.text
                                    Accessible.onPressAction: activate()
                                
                                    RowLayout {
                                        anchors.centerIn: parent
                                        spacing: Theme.space2
                                        VectorIcon {
                                            name: "track"
                                            color: Theme.accentText
                                            width: 12
                                            height: 12
                                        }
                                        Text {
                                            id: endOfTrackText
                                            text: qsTr("Stop at end of track")
                                            color: Theme.textPrimary
                                            font.pixelSize: Theme.fontMeta
                                            font.bold: true
                                        }
                                    }
                                
                                    MouseArea {
                                        id: maEndOfTrack
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        hoverEnabled: true
                                        onClicked: sleepEndOfTrack.activate()
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
                                    spacing: Theme.space1
                                    Text {
                                        id: customLabel
                                        text: qsTr("Custom: %1 min").arg(customSlider.value)
                                        color: Theme.textSec
                                        font.pixelSize: Theme.fontMeta
                                    }
                                
                                    // The volume's slider, in whole minutes.
                                    VolumeSlider {
                                        id: customSlider
                                        objectName: "nowPlayingSleepSlider"
                                        Layout.fillWidth: true
                                        from: 1; to: 120; stepSize: 1; pageStep: 10
                                        snapToStep: true
                                        value: 20
                                        onMoved: (v) => customSlider.value = v
                                        accessibleName: qsTr("Custom length", "sleep timer slider, in minutes")
                                        Accessible.description: customLabel.text
                                    }

                                    // The popup's primary action, the PillButton
                                    // other pages use for Play. Under the slider
                                    // because it commits what the slider says.
                                    PillButton {
                                        objectName: "nowPlayingSleepTimerStart"
                                        Layout.fillWidth: true
                                        Layout.topMargin: Theme.space2
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
                                spacing: Theme.space3
                                visible: root.sleepTimerActive

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 50
                                    color: Theme.accentSoft
                                    border.color: Theme.accentDim
                                    border.width: 1
                                    radius: Theme.radiusLarge
                                
                                    ColumnLayout {
                                        anchors.centerIn: parent
                                        spacing: Theme.spaceHalf
                                        Text {
                                            text: root.sleepStopAtEndOfTrack ? qsTr("Stopping at end of track") : 
                                                  root.sleepIsFading ? qsTr("Fading out audio…") : 
                                                  qsTr("Remaining: %1").arg(root.formatSleepTime(root.sleepTimeLeft))
                                            color: Theme.textPrimary
                                            font.pixelSize: Theme.fontMeta
                                            font.bold: true
                                            Layout.alignment: Qt.AlignHCenter
                                        }
                                        Text {
                                            text: root.sleepStopAtEndOfTrack ? qsTr("Fades out last 15s") : qsTr("Fades out last 30s")
                                            color: Theme.textDim
                                            font.pixelSize: Theme.fontMicro
                                            visible: root.sleepFadeOut
                                            Layout.alignment: Qt.AlignHCenter
                                        }
                                    }
                                }
                            
                                // The way back, so the quiet pill and not red.
                                PillButton {
                                    id: sleepCancel
                                    objectName: "nowPlayingSleepCancel"
                                    Layout.fillWidth: true
                                    compact: true
                                    accent: false
                                    text: qsTr("Cancel sleep timer")
                                    onClicked: {
                                        root.cancelSleepTimer()
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

                            // Robust Options Toggle (Custom Row Switch)
                            RowLayout {
                                id: fadeRow
                                objectName: "nowPlayingSleepFade"
                                Layout.fillWidth: true
                                spacing: Theme.space3
                                function toggle() {
                                    if (Window.window) Window.window.sleepFadeOut = !Window.window.sleepFadeOut
                                }
                                activeFocusOnTab: true
                                Keys.onReturnPressed: toggle()
                                Keys.onSpacePressed:  toggle()
                                Accessible.role: Accessible.CheckBox
                                Accessible.name: fadeText.text
                                Accessible.checkable: true
                                Accessible.checked: root.sleepFadeOut
                                Accessible.onToggleAction: toggle()
                                Accessible.onPressAction: toggle()
                            
                                Text {
                                    id: fadeText
                                    text: qsTr("Fade out audio")
                                    color: Theme.textSec
                                    font.pixelSize: Theme.fontMeta
                                    Layout.fillWidth: true
                                }
                            
                                // The row is the keyboard's target and the
                                // screen reader's checkbox, so the switch is
                                // only drawn here.
                                Toggle {
                                    objectName: "nowPlayingSleepFadeToggle"
                                    activeFocusOnTab: false
                                    Accessible.ignored: true
                                    showFocus: fadeRow.activeFocus
                                    checked: root.sleepFadeOut
                                    onToggled: fadeRow.toggle()
                                }
                            
                                // Handlers, not a MouseArea: the whole row is
                                // the hit target, and an anchored MouseArea
                                // inside a layout is undefined behaviour.
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                // Exclusive on press, as in SettingsPanel's buttons.
                                TapHandler {
                                    gesturePolicy: TapHandler.ReleaseWithinBounds
                                    onTapped: fadeRow.toggle()
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
                            IconButton { objectName: "nowPlayingShuffle"; icon: "shuffle"; size: 24; pad: Theme.space5; active: player.shuffle; checkable: true
                                      label: qsTranslate("PlayerBar", "Shuffle")
                                      onClicked: player.setShuffle(!player.shuffle) }
                            // The cluster's counterweight, which keeps play in
                            // the middle. Invisible, not zero-width: a RowLayout
                            // keeps the spacing of a zero-width child.
                            Item {
                                objectName: "nowPlayingTransportWeight"
                                visible: root.volumeClusterFits
                                Layout.preferredWidth: root.volumeClusterWidth
                            }
                            Item { Layout.fillWidth: true }
                            IconButton { objectName: "nowPlayingPrevious"; icon: "previous"; size: 28; pad: Theme.space5
                                      label: qsTranslate("PlayerBar", "Previous track")
                                      onClicked: player.previous() }
                            Rectangle {
                                id: npPlayPause
                                objectName: "nowPlayingPlayButton"
                                width: 64; height: 64; radius: width / 2; color: Theme.textPrimary
                                border.width: activeFocus ? 2 : 0
                                border.color: Theme.accent
                                activeFocusOnTab: true
                                Keys.onReturnPressed: player.playPause()
                                Keys.onSpacePressed:  player.playPause()
                                Accessible.role: Accessible.Button
                                Accessible.name: player.playing ? qsTranslate("PlayerBar", "Pause")
                                                                : qsTranslate("PlayerBar", "Play")
                                Accessible.onPressAction: player.playPause()
                                VectorIcon {
                                    anchors.centerIn: parent
                                    name: player.playing ? "pause" : "play"
                                    color: Theme.bg
                                    width: 32
                                    height: 32
                                    visible: !player.loading
                                }
                                BusyRing {
                                    objectName: "nowPlayingLoadingRing"
                                    anchors.centerIn: parent
                                    width: 30; height: 30
                                    thickness: 3
                                    color: Theme.bg
                                    visible: player.loading
                                    running: player.loading
                                }
                                scale: pHov.hovered ? 0.95 : 1; Behavior on scale { NumberAnimation { duration: Theme.dur(Theme.motionFast) } }
                                HoverHandler { id: pHov; cursorShape: Qt.PointingHandCursor }
                                TapHandler   { onTapped: player.playPause() }
                                PlayerBar.LoadErrorTip { }
                            }
                            IconButton { objectName: "nowPlayingNext"; icon: "next"; size: 28; pad: Theme.space5
                                      label: qsTranslate("PlayerBar", "Next track")
                                      onClicked: player.next() }
                            Item { Layout.fillWidth: true }
                            IconButton { objectName: "nowPlayingRepeat"; icon: player.repeatMode === 2 ? "repeat-one" : "repeat"; size: 24; pad: Theme.space5; active: player.repeatMode > 0
                                      label: player.repeatMode === 2 ? qsTranslate("PlayerBar", "Repeat: one track")
                                           : player.repeatMode === 1 ? qsTranslate("PlayerBar", "Repeat: all")
                                                                     : qsTranslate("PlayerBar", "Repeat: off")
                                      onClicked: player.setRepeatMode((player.repeatMode + 1) % 3) }

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
                        spacing: Theme.space3
                        // The true play order, shuffle included. queueCount is
                        // read for the dependency, not queueTracks, which
                        // copies the whole queue into JS.
                        property var upNext: (player.queueCount, player.queueIndex,
                                              player.shuffle, player.upcomingTracks(3))
                        visible: upNext.length > 0

                        Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true }

                        Text {
                            text: qsTr("Up next")
                            color: Theme.textDim
                            font.pixelSize: Theme.fontMicro
                            font.bold: true
                        }

                        Repeater {
                            model: upNextCol.upNext
                            delegate: RowLayout {
                                required property int index
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.topMargin: Theme.space1
                                Layout.bottomMargin: Theme.space1
                                spacing: Theme.space3
                                property var upTrack: modelData
                                CoverArt {
                                    width: 44; height: 44
                                    source: upTrack && upTrack.coverUrl80 ? upTrack.coverUrl80 : ""
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: Theme.space1
                                    Text { Layout.fillWidth: true; text: upTrack ? upTrack.title : ""; color: Theme.textPrimary; font.pixelSize: Theme.fontBody; elide: Text.ElideRight }
                                    ArtistLinks {
                                        Layout.fillWidth: true
                                        namePrefix: "nowPlayingUpNext"
                                        fontPixelSize: Theme.fontMeta
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
        height: 26; radius: Theme.radiusFull
        color: chip.on ? Theme.accent : Theme.artScrimStrong
        // The focus ring is the text colour, not the accent: an "on" chip is
        // already filled with the accent.
        border.width: chip.activeFocus ? 2 : 1
        border.color: chip.activeFocus ? Theme.textPrimary
                    : chip.on ? "transparent" : Theme.artBorder

        activeFocusOnTab: true
        Keys.onReturnPressed: chip.toggled()
        Keys.onSpacePressed:  chip.toggled()
        Accessible.role: Accessible.Button
        Accessible.name: chip.label
        Accessible.checkable: true
        Accessible.checked: chip.on
        Accessible.onPressAction: chip.toggled()
        Accessible.onToggleAction: chip.toggled()

        Text {
            id: chipLabel
            anchors.centerIn: parent
            text: chip.label
            color: chip.on ? Theme.accentInk : Theme.artInk
            font.pixelSize: Theme.fontMicro; font.bold: true
        }

        HoverHandler { cursorShape: Qt.PointingHandCursor }

        // ReleaseWithinBounds: the default DragThreshold policy takes only a
        // passive grab, so a lyric line under the chip would also seek.
        TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: chip.toggled()
        }
    }
    // The six presets' words and press, written once.
    function sleepPresetLabel(minutes) { return qsTr("%1m", "compact duration in minutes").arg(minutes) }
    function sleepPresetName(minutes) {
        return qsTr("%1 minutes", "sleep timer option, for a screen reader").arg(minutes)
    }
    function startSleepPreset(minutes) {
        root.startSleepTimer(minutes, false)
        sleepTimerPopup.close()
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
            !outPicker.menuVisible
            && (muteHov.hovered || pctHov.hovered || muteBtn.activeFocus)

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
                Accessible.role: Accessible.Button
                Accessible.name: player.muted ? qsTranslate("PlayerBar", "Unmute")
                                              : qsTranslate("PlayerBar", "Mute")
                Accessible.onPressAction: player.setMuted(!player.muted)
                Accessible.description: volPctText.text
                // As on the bar's speaker: focus shows the flyout, arrows move it.
                Keys.onUpPressed:   volFlyout.slider.stepBy(volFlyout.slider.stepSize)
                Keys.onDownPressed: volFlyout.slider.stepBy(-volFlyout.slider.stepSize)
                Rectangle {
                    anchors.fill: parent; anchors.margins: -Theme.space1; radius: Theme.radiusMedium; color: "transparent"
                    border.width: muteBtn.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                VectorIcon {
                    anchors.fill: parent
                    name: player.muted ? "volume-mute" : (player.volume < 0.3 ? "volume-low" : player.volume < 0.7 ? "volume-mid" : "volume-high")
                    color: muteHov.hovered ? Theme.textPrimary : Theme.textSec
                }
                // A click still mutes, and the hover is what the flyout reads.
                // A HoverHandler, because the flyout is not a child of this
                // item and cannot see a MouseArea's containsMouse.
                HoverHandler { id: muteHov; cursorShape: Qt.PointingHandCursor }
                MouseArea { anchors.fill: parent; onClicked: player.setMuted(!player.muted); cursorShape: Qt.PointingHandCursor }
                PlayerBar.VolumeWheel { }
            }

            Text {
                id: volPctText
                objectName: vol.visible ? "nowPlayingVolumePercent"
                                        : "nowPlayingVolumePercentOffstage"
                Component.onCompleted: Theme.tabularFigures(volPctText)
                // Fixed, so a label running from "0%" to "100%" cannot move the
                // buttons or the speaker. Layout.preferredWidth: a layout
                // overwrites a plain width with the Text's implicit one.
                Layout.preferredWidth: root.volumePercentWidth
                Layout.alignment: Qt.AlignHCenter
                topPadding: root.volumeStackGap
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("%1%").arg(Math.round((player.muted ? 0 : player.volume) * 100)
                                          .toLocaleString(Qt.locale(), 'f', 0))
                color: Theme.textDim; font.pixelSize: Theme.fontMeta
                HoverHandler { id: pctHov }
                PlayerBar.VolumeWheel { }
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
        if (t === "search")     return { page: "search",     params: { requestedQuery: player.sourceId } }
        return null
    }
    function goToSource() {
        var n = sourceNav()
        if (n) navigateTo(n.page, n.params)
    }
}
