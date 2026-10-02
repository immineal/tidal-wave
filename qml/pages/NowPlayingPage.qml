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
    // Download state for the current track: "idle" | "busy" | "done" | "error"
    property string dlState: "idle"

    // ─── Responsive layout ─────────────────────────────
    // The page margin and the gap between the cover and the text column, named
    // because all the width arithmetic below leans on them.
    readonly property int pageMargin: 48
    readonly property int columnGap:  64

    readonly property real contentWidth: Math.max(0, width - 2 * pageMargin)

    // The transport row's fixed content measures 248px (44 shuffle, 48
    // previous, 64 play, 48 next, 44 repeat) and its six 16px gaps bring it to
    // 344. Side by side the text column only ever gets 55% of the content
    // width less the 64px gap, which is 290px at a 960px window: 54px short,
    // and short at the old 900px minimum too. So below this page width the
    // cover moves above the text and the transport rather than beside them.
    // 1000 is the agreed round number; the arithmetic itself gives out at 838.
    readonly property int  stackBreakpoint: 1000
    readonly property bool stacked: width < stackBreakpoint

    // The vertical gap between the two blocks once they are stacked, which is
    // also what stackedCoverRoom has to leave room for.
    readonly property int stackGap: 32

    // ─── Crossing the breakpoint ───────────────────────
    //
    // How stacked the page is: 0 with the cover beside the text, 1 with it
    // above. The one animated property on this page, and everything that has
    // to move during the rearrangement is lerped off it rather than switched
    // on `stacked`, which is the same shape components/SideBar.qml uses for
    // its slide: one clock, so nothing can arrive early or late.
    //
    // The page used to re-form in a single frame, which is what the user asked
    // for an animation about ("at the moment it just snaps into the rearranged
    // look. For instance, the now playing").
    //
    // 170ms and OutCubic, the same as the sidebar's slide, and reduced motion
    // goes through the duration rather than through `enabled` so the move
    // still starts and still finishes, in the frame it started (see
    // Theme.dur).
    // Lyrics are the stacked arrangement whatever the window is doing. A tall
    // column of words beside a tall column of controls is two columns and
    // neither gets a measure worth reading; the page has one wide slot to give
    // and the lyrics want all of it. So opening them is a breakpoint crossing
    // in its own right, and it goes down the same clock rather than switching.
    readonly property bool stackedLayout: stacked || showLyrics
    property real stackness: stackedLayout ? 1 : 0

    Behavior on stackness {
        NumberAnimation { duration: Theme.dur(170); easing.type: Easing.OutCubic }
    }

    // ─── Artwork or lyrics ─────────────────────────────
    //
    // How far the hero slot is from being an album cover and towards being a
    // page of lyrics: 0 artwork, 1 lyrics. The second clock on this page, run
    // the same way as `stackness` and at the same duration, so the two of them
    // move as one when opening the lyrics is also what stacks the page.
    //
    // It exists because the two things wanted different shapes out of one
    // slot. The lyrics used to be poured into the artwork's square -- 180px of
    // it in a short window -- so a line like "We are losing the game" wrapped
    // after four words with the whole width of the page empty beside it.
    property real lyricsness: showLyrics ? 1 : 0

    Behavior on lyricsness {
        NumberAnimation { duration: Theme.dur(170); easing.type: Easing.OutCubic }
    }

    // Reads as "a quantity on its way from the side-by-side value to the
    // stacked one". Every piece of geometry below is written this way so that
    // at rest it is exactly the number the layout used before, and in between
    // there is nothing to disagree about.
    function blend(side, stackedValue) {
        return side + (stackedValue - side) * root.stackness
    }

    // The same, between the artwork's shape and the lyrics'.
    function lblend(art, lyrics) {
        return art + (lyrics - art) * root.lyricsness
    }

    // Stacked, the cover takes the height the rest of the page leaves it,
    // capped at 420 and at the content width and floored at 180 so it stays a
    // cover. Deriving it rather than taking a fixed fraction of the height is
    // what keeps 960x1200, the user's half-screen size, off the scrollbar: a
    // flat 420 overshot it by twenty pixels. Side by side it keeps the 45% of
    // the content width it always had.
    readonly property real sideCoverSize:    Math.min(contentWidth * 0.45, 420)
    readonly property real stackedCoverSize: Math.min(contentWidth, 420,
                                                      Math.max(180, stackedCoverRoom))
    readonly property real coverSize: blend(sideCoverSize, stackedCoverSize)

    // ─── What the lyrics ask for instead ───────────────
    //
    // A measure, not a square. 640px is about 90 characters of the 14px the
    // lines are set in, which is past the longest line anything the parser
    // produces, so at that width a lyric is one line and the eye comes back to
    // a known place. Wider is not more readable, so the slot stops there and
    // centres in whatever is left.
    readonly property int lyricsMeasure: 640
    readonly property real lyricsWidth: Math.min(contentWidth, lyricsMeasure)

    // And the height the page can spare, read off the same room the stacked
    // cover takes: floored at 280 so there is always a column rather than a
    // porthole, capped at 560 because past that the active line is too far from
    // the middle of the screen to follow. Never shorter than the artwork it
    // replaces, so opening the lyrics only ever makes the slot bigger -- which
    // is what lets the crossfade below leave the cover at its own size while
    // the slot grows around it.
    readonly property real lyricsHeight:
        Math.max(coverSize, 280, Math.min(560, stackedCoverRoom))

    // The slot both of them live in. Square for the artwork, a column for the
    // lyrics, and on its way between the two for 170ms.
    readonly property real slotWidth:  lblend(coverSize, lyricsWidth)
    readonly property real slotHeight: lblend(coverSize, lyricsHeight)

    // What is left once the margins, the header row, the two 32px gaps and the
    // text column have taken their height. The text column's own height does
    // not depend on the cover's, so this cannot chase its own tail. It is the
    // *settled* stacked height on purpose: measuring the room against a cover
    // that is still moving would feed the animation back into itself.
    readonly property real stackedCoverRoom:
        height - 2 * pageMargin - headerRow.height - 32 - stackGap
        - infoColumn.implicitHeight

    // What the title and transport column actually gets. The pair below is
    // written so that infoX + infoWidth is the content width at every value of
    // stackness, not only at the two ends: the column's right edge is the page
    // margin throughout the move, so it cannot briefly hang out of the page.
    readonly property real sideInfoWidth:
        Math.max(0, contentWidth - sideCoverSize - columnGap)
    readonly property real infoWidth: blend(sideInfoWidth, contentWidth)

    // ─── Where the two blocks are ──────────────────────
    //
    // The text column's height is set by its content and does not change with
    // the layout, which is what lets the arithmetic below be closed-form
    // rather than circular.
    readonly property real infoHeight: infoColumn.implicitHeight
    // The height the pair takes side by side, and the centre line they are
    // both held on there. Measured against this rather than against the
    // container's current height, which is itself one of the things being
    // animated.
    // `lblend` and not `slotHeight`, because this is the *settled* side-by-side
    // figure: the whole point of measuring against it is that it is not itself
    // one of the things the stack animation is moving.
    readonly property real sideBodyHeight:
        Math.max(lblend(sideCoverSize, lyricsHeight), infoHeight)

    readonly property real coverX: Math.round(blend(0, (contentWidth - slotWidth) / 2))
    readonly property real coverY: Math.round(blend((sideBodyHeight - slotHeight) / 2, 0))
    readonly property real infoX:  Math.round(blend(contentWidth - sideInfoWidth, 0))
    readonly property real infoY:  Math.round(blend((sideBodyHeight - infoHeight) / 2,
                                                    slotHeight + stackGap))

    // What the two of them actually reach, which is what the page reserves for
    // them and therefore what it can be scrolled by.
    //
    // Derived from the positions above rather than from the two end states,
    // because the halfway point of the rearrangement is taller than halfway
    // between the two heights: the text column has already started down the
    // page while the page is still only partly as tall as it will be. Reserving
    // the average instead left the bottom of the column unreachable for the
    // length of the move, which is the same mistake as the sidebar reserving
    // its full width before the panel had got there.
    readonly property real bodyHeight:
        Math.max(coverY + slotHeight, infoY + infoHeight)

    // 248px of buttons and six gaps. Where 344 will not fit, which is any
    // window at or below 640, the gaps tighten to 8 and the row comes down to
    // 296 rather than the buttons spilling over each other.
    readonly property int transportFixedWidth: 248
    readonly property int transportGaps: 6
    readonly property int transportSpacing:
        infoWidth >= transportFixedWidth + transportGaps * 16 ? 16 : 8
    readonly property int transportMinWidth:
        transportFixedWidth + transportGaps * transportSpacing

    // ─── Fullscreen ────────────────────────────────────
    // The window owns its own visibility, so this page can only ask. Both
    // reads are written to survive a host that has neither - the layout and
    // navigation test hosts stand in for Main.qml with only the surface they
    // each need, and a missing property has to read as "not fullscreen"
    // rather than as a warning.
    readonly property bool fullScreen:
        Window.window ? Window.window.fullScreen === true : false

    function toggleFullScreen() {
        if (Window.window && Window.window.toggleFullScreen)
            Window.window.toggleFullScreen()
    }

    // ─── The cover-derived background ──────────────────
    // On by default, and fullscreen only - which is why it hangs off the
    // property above rather than being a thing the page always does.
    //
    // Read defensively, for the same reason Theme.reduceMotion reaches for
    // `app` the way it does: a QML test host installs only the context
    // properties it needs, and a settings file written by an older build has
    // never heard of this key. Both of those read as the default, and the
    // default is on.
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

    // The band at the bottom of the lyrics panel that belongs to the two chips
    // and not to the words. Resync is 28 tall on a 10px bottom margin, so it
    // reaches 38px up from the panel floor, and the Lyrics toggle 36; 48 leaves
    // ten pixels of air between the taller of them and the last line. Nothing
    // scrolls through it, which is what stops a tap on a chip also landing on a
    // lyric.
    readonly property int lyricsFooterRoom: 48
    // The same at the top, for the fullscreen button in that corner: 36 tall on
    // a 10px margin reaches 46, and this leaves a little air above the first
    // line once it has been scrolled to the top.
    readonly property int lyricsHeaderRoom: 56

    // Puts the line being sung back in the middle. Called on every resize of
    // the list as well as from the sync timer, because the slot changes shape
    // when the lyrics open and again whenever the page restacks, and a
    // ListView keeps its scroll offset rather than its centred item.
    function recentreLyrics() {
        if (!root.showLyrics || root.userScrolled) return
        if (root.currentLyricLine < 0 || root.lyricsData.length === 0) return
        lyricsView.positionViewAtIndex(root.currentLyricLine, ListView.Center)
    }

    // Opening the panel is the one resize that happens before there is a list
    // to position, so it asks again once there is.
    onShowLyricsChanged: if (showLyrics) Qt.callLater(root.recentreLyrics)

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
                    lyricsView.positionViewAtIndex(found, ListView.Center)
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
    Component.onCompleted: {
        updateLikedState()
        loadLyrics()
        if (hasTrack && downloader.isDownloading(track.id)) dlState = "busy"
    }

    // ─── The background ────────────────────────────────
    //
    // Docked, and with the preference off, this is exactly the gradient the
    // page has always drawn: a soft accent wash at the top fading into the
    // page ground. Nothing below changes a pixel of it.
    //
    // Fullscreen, with the preference on, the top stop comes out of the
    // artwork instead. That is what clearing the accent out of this page was
    // for - see the artist link further down - so that the one strong colour
    // on a fullscreen Now Playing is the record's and not the theme's.
    //
    // The colour is extracted in C++ (src/ui/CoverColor.h): off the GUI
    // thread, once per cover, and clamped to a lightness the page's own type
    // is still legible against. Until it arrives - a cover still downloading,
    // a track with no artwork - hasColor is false and the accent wash paints,
    // so there is never a frame with no gradient at all.
    CoverTint {
        id: coverTint
        objectName: "nowPlayingCoverTint"
        active:  root.fullScreen && root.coverGradient
        coverId: root.hasTrack && root.track.coverUrl ? root.track.coverUrl : ""
        // The two grounds that bracket the band the tint is held inside. The
        // clamp is the C++ side's business; which palette it is measured
        // against is this page's.
        bg:    Theme.bg
        limit: Theme.surfaceHigh
    }

    // The gradient's top stop, as a property rather than an expression inside
    // the Gradient, so that a change to it can be eased. A new track fades its
    // colour in over Theme.dur(420) instead of the page changing between two
    // frames; reduced motion collapses that to zero the usual way.
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

    // The page scrolls when it cannot fit, which stacking makes likely: the
    // stacked column stands a whole cover taller than the side by side one and
    // the window minimum is only 600 tall. Non-interactive while everything
    // fits, so nothing moves at the sizes where it already fitted.
    Flickable {
        id: pageFlick
        // Named so tests/qml/tst_layout_player.qml can check that the height it
        // can be scrolled by follows the two blocks instead of jumping to where
        // they are going.
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

            // The way out, and the way to make the page the whole screen.
            //
            // The down-arrow mirrors the player bar's up-arrow: the page came
            // up over the bar, this puts it back down. It used to be the text
            // "←  Now Playing", which named the page you were already looking
            // at and pointed the wrong way; the words went the same way for
            // the same reason. Nothing between the two buttons now but the
            // spacer that holds them to their ends.
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

            // Two columns side by side above the breakpoint, one stacked column
            // below it. The same two items either way, so crossing the
            // breakpoint moves them rather than rebuilding anything.
            //
            // This was a GridLayout with `columns: stacked ? 1 : 2`, and a grid
            // owns its children's positions, so there was nothing an animation
            // could get hold of: the page re-formed between two frames. The two
            // blocks are placed by hand now, off the one `stackness` clock, and
            // the gaps the grid used to keep (columnGap across, stackGap down)
            // are in that arithmetic instead.
            //
            // Not Layout.fillHeight, deliberately: the grid asked for it but
            // could never take it either -- a nested layout whose children
            // neither fill reports its implicit height as its maximum -- so the
            // pair has always been as tall as its content and no taller, with
            // the slack left at the bottom of a tall window. Keeping that is
            // what keeps the cover centred where it was.
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
                    // Mid-move the two blocks pass through each other, and the
                    // artwork is the one that goes over the top.
                    //
                    // They are swapping both axes at once and each is most of
                    // the page, so a path that kept them apart was looked for
                    // and does not exist. All the clearance there is to spend is
                    // the 64px column gap across and the 32px stack gap down,
                    // against a cover around 400px tall and 480px of travel: in
                    // the unit square of (vertical done, horizontal done), the
                    // region where the two rects miss each other is a thin L.
                    // Measured at every width and height the suite sweeps, the
                    // text column may be at most 8-19% of the way across while
                    // it is anywhere in the first 90% of its way down, and the
                    // rest of the crossing only opens up in the last 4% of the
                    // drop. That holds with the clearance set to zero as well,
                    // so it is the size of the blocks and not the buffer. Any
                    // path obeying it is therefore the sequenced L -- all the
                    // way down, then all the way across -- with a corner that
                    // can be rounded by about 20px out of 900px of travel,
                    // inside 170ms, which is a flick in one direction and then
                    // another rather than a move.
                    //
                    // So the overlap is arranged instead of avoided. The cover
                    // is opaque, so with it on top the text slides behind the
                    // artwork and comes out below it, which reads as one thing
                    // passing another. The other way round the title is drawn
                    // over album art for a tenth of a second and reads as a
                    // double exposure. At rest the two are clear of each other,
                    // so this does nothing at either end;
                    // tests/qml/tst_layout_player.qml holds both halves of that.
                    z: 1

                    // Album art. A square of its own size centred in the slot
                    // rather than filling it: the slot stops being square when
                    // the lyrics open, and an artwork stretched across that for
                    // the length of the crossfade is the one frame of this that
                    // would look broken. It is exactly anchors.fill while the
                    // slot is a cover, which is whenever it can be seen at all.
                    Rectangle {
                        objectName: "nowPlayingArt"
                        anchors.centerIn: parent
                        width:  root.coverSize
                        height: root.coverSize
                        radius: Theme.radiusArt; color: Theme.surfaceHigh; clip: true
                        opacity: 1 - root.lyricsness
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
                        color: Theme.surface
                        border.color: Theme.border
                        opacity: root.lyricsness
                        visible: opacity > 0.01
                        clip: true

                        ListView {
                            id: lyricsView
                            objectName: "nowPlayingLyricsView"
                            anchors.fill: parent
                            anchors.margins: 16
                            // Content margins, NOT a smaller viewport.
                            //
                            // This band used to be taken out of the viewport so
                            // that nothing was ever drawn under the chips. It
                            // worked, and it cost the thing it was protecting:
                            // the bottom of the panel stayed permanently empty
                            // and the last line of a song could never reach it,
                            // which reads as the box being broken rather than
                            // as considerate spacing.
                            //
                            // The list fills the panel again, and these are
                            // margins on the CONTENT, so a line can be drawn
                            // anywhere in the box and can still be scrolled
                            // clear of either chip. The tap-through that
                            // started all this is held shut where it belongs,
                            // by the chips taking an exclusive grab, not by
                            // leaving a hole for them to sit in.
                            topMargin: root.lyricsHeaderRoom
                            bottomMargin: root.lyricsFooterRoom
                            clip: true
                            model: root.lyricsData
                            spacing: 8
                            cacheBuffer: 200

                            onMovingChanged: if (moving) root.userScrolled = true

                            // Every resize is a re-wrap, and a re-wrap moves the
                            // line that was centred. Deferred, so it runs after
                            // the delegates have been laid out at the new width
                            // and not against last frame's heights; coalesced by
                            // Qt.callLater, so an animated resize re-centres once
                            // a frame rather than once a binding.
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
                                color: active ? Theme.accent : (hovered ? Theme.textPrimary : Theme.textSec)
                                font.pixelSize: 14
                                font.bold: active
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
                                        lyricsView.positionViewAtIndex(index, ListView.Center)
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

                        // Fullscreen, in the lyrics panel's own top right.
                        //
                        // The same toggle as the one in the page chrome, not a
                        // second notion of fullscreen: reading lyrics is the
                        // case where the whole screen is most wanted, and
                        // reaching back up to the chrome row to get it meant
                        // leaving the thing you were reading.
                        ChromeButton {
                            objectName: "nowPlayingLyricsFullscreen"
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 10
                            icon: root.fullScreen ? "fullscreen-exit" : "fullscreen"
                            tip: root.fullScreen
                                 ? qsTr("Leave fullscreen", "button, restores the window")
                                 : qsTr("Fullscreen", "button, fills the screen with this page")
                            onActivated: root.toggleFullScreen()
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
                            // The chip said its own name with a rotation
                            // arrow glued to the front of the translatable
                            // string. The word carries it; the glyph was
                            // decoration, and a character the font may not
                            // have at that.
                            Text {
                                id: rsText
                                anchors.centerIn: parent
                                text: qsTr("Resync")
                                color: Theme.artInk; font.pixelSize: 12
                            }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            // ReleaseWithinBounds, not the default: this chip
                            // floats over the lyric list, and a DragThreshold
                            // TapHandler takes only a passive grab, so the line
                            // underneath answered the same tap and the chip
                            // resynced to a line the tap had just seeked to.
                            TapHandler {
                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: {
                                    root.userScrolled = false
                                    if (root.currentLyricLine >= 0)
                                        lyricsView.positionViewAtIndex(root.currentLyricLine, ListView.Center)
                                }
                            }
                        }
                    }

                    // Lyrics toggle button — hidden when lyrics confirmed unavailable
                    Rectangle {
                        objectName: "nowPlayingLyricsToggle"
                        visible: root.lyricsState !== "unavailable"
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        anchors.margins: 10
                        width: lyricsToggleText.implicitWidth + 16
                        height: 26; radius: Theme.radiusChip
                        color: root.showLyrics ? Theme.accent : Theme.artScrimStrong
                        border.color: root.showLyrics ? "transparent" : Theme.artBorder
                        Text {
                            id: lyricsToggleText
                            anchors.centerIn: parent
                            text: root.lyricsState === "loading" ? qsTr("Loading…") : qsTr("Lyrics")
                            color: root.showLyrics ? Theme.accentInk : Theme.artInk; font.pixelSize: 11; font.bold: true
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        // ReleaseWithinBounds, not the default: the user found
                        // that "closing the lyrics tab skips to the line that
                        // the lyrics switch button is over". A DragThreshold
                        // TapHandler takes only a passive grab, so the lyric
                        // line under this chip answered the same tap and seeked.
                        // The band the list now leaves at the bottom of the
                        // panel means nothing is under the chip any more; this
                        // is what makes that a layout choice rather than the
                        // only thing holding the bug shut.
                        TapHandler {
                            gesturePolicy: TapHandler.ReleaseWithinBounds
                            onTapped: {
                                root.showLyrics = !root.showLyrics
                                if (root.showLyrics && root.lyricsState === "none") root.loadLyrics()
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
                        Layout.fillWidth: true
                        spacing: 16

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            // "Playing from" source link — navigates back to the
                            // playlist / album / mix / liked songs it started from.
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
                            // The title opens the album the track is on
                            // (SPEC N1), the same place the album line below
                            // goes. Built like the two links under it: the hit
                            // target and the focus ring follow the words, not
                            // the column the Text fills.
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
                            // One focus stop and one hover target per artist,
                            // so a featured credit opens the guest rather than
                            // the lead — the behaviour the bottom bar already
                            // has (components/PlayerBar.qml), at this page's
                            // size and in this page's accent. Unlike the bar
                            // there is nothing for the gaps between the names
                            // to fall through to: the page they would open is
                            // this one, so they are simply not targets.
                            Item {
                                id: artistLine
                                objectName: "nowPlayingArtistLine"
                                // Fills and elides, like the title above it.
                                // Without this the names' own 453px was the
                                // column's minimum width and dragged the whole
                                // page out past the window edge.
                                Layout.fillWidth: true
                                implicitHeight: Math.max(artistLink.implicitHeight,
                                                         artistRow.implicitHeight)

                                // The fallback for a track with no artistList:
                                // the joined string, linking to the one
                                // artistId such a track carries. It is the lead
                                // artist or nothing, which is all the map says.
                                Text {
                                    id: artistLink
                                    objectName: "nowPlayingArtists"
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    visible: root.artistList.length === 0
                                    text: hasTrack ? track.artists : ""
                                    // The bar's treatment, not an accent link:
                                    // textSec at rest, textPrimary and
                                    // underlined under the pointer. Now Playing
                                    // is being cleared of accent-coloured
                                    // content so a cover-derived background can
                                    // go behind it, and this line was the first
                                    // of it.
                                    color: artistHit.containsMouse && hasTrack && Number(track.artistId) > 0
                                           ? Theme.textPrimary : Theme.textSec
                                    font.pixelSize: 18
                                    elide: Text.ElideRight
                                    font.underline: artistHit.containsMouse && hasTrack && Number(track.artistId) > 0
                                    activeFocusOnTab: visible && hasTrack && Number(track.artistId) > 0
                                    Keys.onReturnPressed: if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                                    Keys.onSpacePressed:  if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                                    Rectangle {
                                        // Tracks the words, not the column the Text now
                                        // fills, so the ring and the hit target do not
                                        // float out to the right of a short name.
                                        x: -4; y: -4
                                        width:  Math.min(parent.width, parent.contentWidth) + 8
                                        height: parent.height + 8
                                        radius: Theme.radiusButton; color: "transparent"
                                        border.width: artistLink.activeFocus ? 2 : 0
                                        border.color: Theme.accent
                                    }
                                    MouseArea {
                                        id: artistHit
                                        width:  Math.min(parent.width, parent.contentWidth)
                                        height: parent.height
                                        hoverEnabled: true
                                        cursorShape: hasTrack && Number(track.artistId) > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        onClicked: if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                                    }
                                }

                                Row {
                                    id: artistRow
                                    width: parent.width
                                    visible: root.artistList.length > 0
                                    spacing: 0

                                    Repeater {
                                        model: root.artistList
                                        delegate: Row {
                                            id: artistItem
                                            required property var modelData
                                            required property int index

                                            readonly property bool linkable: Number(modelData.id) > 0
                                            readonly property real sepWidth: index > 0 ? npSep.implicitWidth : 0
                                            // What the line has left once the
                                            // names in front of this one have
                                            // taken theirs. The pixel of slack
                                            // absorbs the difference between
                                            // the measured string and the
                                            // rendered one.
                                            readonly property real room:
                                                Math.max(0, artistRow.width - root.artistStartX(index) - sepWidth - 1)
                                            // Too tight to read is too tight to
                                            // aim at, so the name goes rather
                                            // than leaving a clickable sliver
                                            // or an unreachable tab stop behind.
                                            visible: room >= 8
                                            spacing: 0

                                            Text {
                                                id: npSep
                                                objectName: "nowPlayingArtistSeparator"
                                                visible: artistItem.index > 0
                                                text: root.artistSeparator
                                                color: Theme.textSec
                                                font.pixelSize: 18
                                            }

                                            Text {
                                                id: npName
                                                objectName: "nowPlayingArtistName"
                                                text: artistItem.modelData.name
                                                // Only the name that runs out
                                                // of line elides; the ones
                                                // before it keep their full
                                                // width.
                                                width: Math.min(implicitWidth, artistItem.room)
                                                elide: Text.ElideRight
                                                color: npNameHit.containsMouse
                                                       ? Theme.textPrimary : Theme.textSec
                                                font.pixelSize: 18
                                                font.underline: npNameHit.containsMouse
                                                // Tab reaches each artist in
                                                // turn rather than one blob,
                                                // and skips a credit with no id
                                                // because there is nowhere for
                                                // it to go.
                                                activeFocusOnTab: artistItem.linkable
                                                Keys.onReturnPressed: root.openArtist(Number(artistItem.modelData.id))
                                                Keys.onSpacePressed:  root.openArtist(Number(artistItem.modelData.id))

                                                Rectangle {
                                                    x: -4; y: -4
                                                    width:  parent.width + 8
                                                    height: parent.height + 8
                                                    radius: Theme.radiusButton; color: "transparent"
                                                    border.width: npName.activeFocus ? 2 : 0
                                                    border.color: Theme.accent
                                                }

                                                // A MouseArea rather than a
                                                // Tap/Hover handler pair, for
                                                // the same reason the bar uses
                                                // one: a TapHandler only takes
                                                // a passive grab, so anything
                                                // under the names answers the
                                                // same click. Disabled when the
                                                // artist has no id, so that
                                                // name is not a dead target.
                                                MouseArea {
                                                    id: npNameHit
                                                    anchors.fill: parent
                                                    enabled: artistItem.linkable
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.openArtist(Number(artistItem.modelData.id))
                                                }
                                            }
                                        }
                                    }
                                }
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

                        // Download button — always visible while a track is playing
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
                            visible: root.hasTrack
                            icon: root.isLiked ? "heart-filled" : "heart"
                            size: 24
                            active: root.isLiked
                            onClicked: {
                                var trackId = root.track.id
                                if (root.isLiked) {
                                    bridge.removeTrackFavorite(trackId, function(success) {})
                                } else {
                                    bridge.addTrackFavorite(trackId, function(success) {})
                                }
                            }
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
                            // An atom and a diamond used to be pasted in
                            // front of the label. Neither says anything about
                            // audio that "Hi-Res Lossless" does not say in
                            // words, and the badge is already colour-coded by
                            // the same three cases, so the marks are gone
                            // rather than redrawn.
                            Text {
                                id: qlbl; objectName: "qualityBadgeText"
                                anchors.centerIn: parent
                                text: player.qualityLabel(player.audioQuality)
                                color: Theme.textPrimary; font.pixelSize: 11; font.bold: true
                            }
                        }

                        Item { Layout.fillWidth: true } // Pusher

                        // Sleep Timer button.
                        //
                        // Two circles, and the user had to draw the gap between
                        // them twice. First: "the clock icon is weirdly spaced
                        // at the top and bottom in relation to how it's spaced
                        // on the left in a fully rounded pill." Then, over a
                        // screenshot of the attempt that was meant to fix it:
                        // "the spacing from the very left of the pill to the
                        // left border of the clock, and then the padding on the
                        // top and bottom of the clock icon, so that the circular
                        // outline of the pill aligns with the circular outline
                        // of the clock icon with some padding."
                        //
                        // So: concentric. The glyph's centre goes on the centre
                        // of the left cap's arc, and the ring of air around the
                        // clock is then the same width the whole way round that
                        // end of the pill.
                        //
                        // What the attempt in between got wrong, measured off a
                        // render of it rather than argued from the source: the
                        // clock's painted rim sat 16px from the pill's left edge
                        // and 4px from its top, a ring four times thicker at the
                        // side than above. Two things made it that, and only one
                        // of them was the padding:
                        //
                        //   * the padding was set equal to the corner radius,
                        //     from an argument about clearance at the content's
                        //     own corner - which is not the gap the eye reads
                        //     here, as the user saying it twice shows; and
                        //   * the clock was painted at 24px, not the 12 it was
                        //     written at. VectorIcon's implicit size is 24, this
                        //     is a RowLayout child, and a layout imposes a
                        //     child's implicit size over any plain width/height.
                        //     Exactly the trap documented on implicitWidth
                        //     below, one level down, and the reason a glyph
                        //     meant to leave 8px above it left 2.
                        //
                        // The trailing side is a separate question and keeps the
                        // corner radius. It ends in text, which has no round
                        // outline to line up with, and an icon-and-label pill
                        // wants its tighter end at the icon.
                        //
                        // It is not made to match the quality badge beside it,
                        // which keeps its near-square 4px corners: that badge
                        // states what the stream is and cannot be pressed, this
                        // one opens a popup. The two are at opposite ends of the
                        // row with the pusher between them, and the shapes are
                        // the difference between a mark and a button.
                        Rectangle {
                            id: sleepTimerBtn
                            objectName: "nowPlayingSleepTimerButton"
                            height: 28
                            // What the pill actually draws: Theme.radiusChip is
                            // a "round it all the way" sentinel, and Qt clamps
                            // it to half the shorter side.
                            readonly property real cornerRadius:
                                Math.min(Theme.radiusChip, height / 2)
                            // The clock's box. Everything below is derived from
                            // it and the height, so this is the one number to
                            // turn.
                            //
                            // 14, measured rather than picked: VectorIcon paints
                            // its glyph at 85% of its box, so a 14px box puts a
                            // 12px rim on screen, against a label that measures
                            // 11px from the top of its "S" to the foot of its
                            // "p". The 24px box this was painting at before put
                            // a 20px rim in a 28px pill, which is what left 4px
                            // of air above a clock with 16px beside it.
                            readonly property real glyphSize: 14
                            // Concentric with the left cap: the glyph's centre on
                            // the centre of the cap's arc. Derived from the two
                            // numbers above rather than typed, so it survives a
                            // change of either - the leading gap is then
                            // cornerRadius - glyphSize/2 and the gap above the
                            // glyph is (height - glyphSize)/2, and those are the
                            // same number for as long as the pill is fully round.
                            readonly property real leadInset:
                                cornerRadius - glyphSize / 2
                            // The text end, which has no circle to align with.
                            readonly property real trailPad: cornerRadius

                            // implicitWidth, NOT width. This is a direct child
                            // of a RowLayout, and a Layout owns its children's
                            // width: with implicitWidth left at 0 the layout
                            // keeps re-imposing the size it captured and fights
                            // the binding, so the pill painted one frame at the
                            // right width after every change and then snapped
                            // back to the previous one. That is a visible flash
                            // on every tick of the countdown, and it is what
                            // tests/qml/tst_layout_player.qml had been reporting
                            // as "jitter" all along - twice written off as a
                            // test artefact before a per-frame trace on the Mac
                            // showed the width really was wrong on screen.
                            // Any Rectangle in a Layout that sets `width:` has
                            // the same trap.
                            implicitWidth: leadInset + sleepTimerRow.implicitWidth
                                           + trailPad
                            radius: cornerRadius

                            // Rest and hover as a pair, the way ChromeButton
                            // further down this file does it, so the two states
                            // are read off one line each.
                            //
                            // The user asked for the hover after looking at the
                            // pill again: it opens a popup and was the only
                            // control in this row that never answered the
                            // pointer. The idle pair is the house ground step,
                            // surfaceHigh -> surfaceHov.
                            //
                            // The counting pair is not, because the obvious
                            // token does not work. accentTint is the accent at
                            // 0.22 and accentWash at 0.26, and over this page's
                            // ground that step is 6 of 255 - a change you can
                            // only find if you already know to look. The accent
                            // at 0.36 was grabbed instead: the fill goes
                            // (7,41,53) -> (6,56,73), a step of 20, against the
                            // idle pair's measured 30 -> 56. The two states now
                            // answer the pointer by about the same amount.
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
                                // Anchored to the left edge, not centred in the
                                // pill: the two ends are padded differently now
                                // and a centred row can only ever pad them the
                                // same.
                                anchors.left: parent.left
                                anchors.leftMargin: sleepTimerBtn.leadInset
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6

                                VectorIcon {
                                    objectName: "nowPlayingSleepTimerIcon"
                                    name: "clock"
                                    color: root.sleepTimerActive ? Theme.accent : Theme.textSec

                                    // Heavier than VectorIcon's 1.8 default, to
                                    // keep the weight the glyph had when it was
                                    // being painted at 24. The stroke scales
                                    // with the box, so at 14 the default draws a
                                    // 0.89px line that antialiases to a grey
                                    // ghost - visibly fainter than the label
                                    // beside it in a grab of the two at 16x.
                                    // 2.4 puts 1.19px on screen, which matches
                                    // the type.
                                    strokeWidth: 2.4

                                    // Layout.preferredWidth/Height, NOT
                                    // width/height. A layout imposes its child's
                                    // implicit size over a plain width/height,
                                    // so the `width: 12` that used to be here
                                    // was simply ignored and VectorIcon's
                                    // implicit 24 was what got painted. The same
                                    // trap as the pill's own implicitWidth, one
                                    // level down.
                                    //
                                    // Both dimensions, and the same number in
                                    // each: the row around this is 15 tall and
                                    // the glyph is 14, so a Layout.fillHeight
                                    // anywhere near here would stretch the clock
                                    // to 14 by 15 - round in the source and an
                                    // oval on screen.
                                    Layout.preferredWidth:  sleepTimerBtn.glyphSize
                                    Layout.preferredHeight: sleepTimerBtn.glyphSize
                                }

                                Text {
                                    objectName: "nowPlayingSleepTimerLabel"
                                    text: root.sleepTimerActive ?
                                          (root.sleepStopAtEndOfTrack ? qsTr("End of Track") : root.formatSleepTime(root.sleepTimeLeft)) :
                                          qsTr("Sleep Timer")
                                    // The whole pill is sized from this label,
                                    // and "10:00" and "9:59" are not the same
                                    // width: left alone the pill would have
                                    // breathed in and out once a second, which
                                    // is worse than odd padding. While it is
                                    // counting the label holds the widest clock
                                    // it can show and centres the digits in it,
                                    // so only the digits change. "End of Track"
                                    // does not tick and takes its own width, and
                                    // nothing here is a fixed number of pixels,
                                    // so a longer German label still fits.
                                    // The widest clock of the shape this one
                                    // is: "mm:ss" below the hour and "h:mm:ss"
                                    // above it. Reserving the hour shape the
                                    // whole time would sit a fifteen-minute
                                    // timer in a pill built for ninety.
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

                            // One object for the pointer: hover, cursor and
                            // click. A HoverHandler would be the idiom used by
                            // ChromeButton and the lyrics chips, and it was
                            // tried here first - it never reported a hover at
                            // all, because setting cursorShape on a MouseArea
                            // makes that MouseArea accept hover events, and it
                            // is a child of this Rectangle and so sits in front
                            // of the handler. Two things wanting the pointer,
                            // one of them winning silently. Those chips have no
                            // MouseArea; the controls in this file that do -
                            // SleepOptionBtn below, among others - read
                            // containsMouse, which is what this does.
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
                        parent: sleepTimerBtn
                        x: sleepTimerBtn.width - width
                        y: sleepTimerBtn.height + 6
                        width: 260
                        height: contentCol.implicitHeight + 24
                        padding: 12
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
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text {
                                            text: qsTr("Custom: %1 min").arg(customSlider.value)
                                            color: Theme.textSec
                                            font.pixelSize: 12
                                        }
                                        Item { Layout.fillWidth: true }
                                        Text {
                                            text: qsTr("Start", "verb, begins the sleep timer")
                                            color: Theme.accent
                                            font.pixelSize: 12
                                            font.bold: true
                                        
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    root.startSleepTimer(customSlider.value, false)
                                                    sleepTimerPopup.close()
                                                }
                                            }
                                        }
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
                            
                                // Handlers rather than a MouseArea: the whole
                                // row is the hit target, and an anchored
                                // MouseArea inside a layout is undefined
                                // behaviour (Qt warns about it).
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
                        Layout.fillWidth: true
                        position: player.position; duration: player.duration
                        onSeeked: (ms) => player.seek(ms)
                    }

                    RowLayout {
                        Layout.fillWidth: true; spacing: root.transportSpacing
                        CtrlBtn { icon: "shuffle"; size: 24; active: player.shuffle; onClicked: player.setShuffle(!player.shuffle) }
                        Item { Layout.fillWidth: true }
                        CtrlBtn { icon: "previous"; size: 28; onClicked: player.previous() }
                        Rectangle {
                            id: npPlayPause
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
                        CtrlBtn { icon: "next"; size: 28; onClicked: player.next() }
                        Item { Layout.fillWidth: true }
                        CtrlBtn { icon: player.repeatMode === 2 ? "repeat-one" : "repeat"; size: 24; active: player.repeatMode > 0; onClicked: player.setRepeatMode((player.repeatMode + 1) % 3) }
                    }

                    RowLayout {
                        Layout.fillWidth: true; spacing: 12
                        Item {
                            id: muteBtn
                            width: 18; height: 18
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
                                color: Theme.textSec
                                strokeWidth: 1.5
                            }
                            MouseArea { anchors.fill: parent; onClicked: player.setMuted(!player.muted); cursorShape: Qt.PointingHandCursor }
                        }
                        VolumeSlider {
                            Layout.fillWidth: true
                            value: player.muted ? 0 : player.volume
                            onMoved: (v) => { player.setMuted(false); player.setVolume(v) }
                        }
                        Text {
                            text: qsTr("%1%").arg(Math.round((player.muted ? 0 : player.volume) * 100)
                                                      .toLocaleString(Qt.locale(), 'f', 0))
                            color: Theme.textDim; font.pixelSize: 12; width: 36
                        }

                        // The output picker, the same component the player bar
                        // puts next to its volume slider: this computer's
                        // outputs and any cast target in one list. It used to
                        // be a cast-only picker written out twice, once here
                        // and once in the bar, because the two could not share
                        // a file without touching CMakeLists.txt. They share
                        // PlayerBar's inline component instead, so the list,
                        // the headings and the "stop casting" rule are written
                        // once.
                        PlayerBar.OutputPicker {
                            objectName: "nowPlayingOutputButton"
                            size: 20
                        }
                    }

                    // Up Next preview
                    ColumnLayout {
                        id: upNextCol
                        Layout.fillWidth: true
                        spacing: 12
                        // Reflects the true play order (respects shuffle).
                        // queueCount, not queueTracks, is read for the
                        // dependency: both are notified by queueChanged, but
                        // queueTracks copies the entire queue into JS to be
                        // thrown away, which on a 5000-track queue is the
                        // whole cost of a track change. queueIndex brings the
                        // advance, shuffle brings a reorder.
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
                                    Text { Layout.fillWidth: true; text: upTrack ? upTrack.artists : ""; color: Theme.textSec; font.pixelSize: 12; elide: Text.ElideRight }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // A disc-backed icon button for the page's own chrome. The same treatment
    // as components/BackButton.qml, and for the same reason: stacked, this row
    // sits directly above the cover and on a short window the page scrolls it
    // over the artwork, where a bare glyph loses its edge. The border carries
    // the shape when the fill alone would not.
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
        // ReleaseWithinBounds, not the default. A DragThreshold TapHandler
        // takes only a passive grab, so anything underneath answers the same
        // tap - which is the bug the lyrics toggle already had to fix once,
        // and one of these now sits over the lyric list too.
        TapHandler   { gesturePolicy: TapHandler.ReleaseWithinBounds
                       onTapped: cb.activated() }
    }

    component SleepOptionBtn : Rectangle {
        id: optBtn
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

    // ─── Artist links (SPEC N2, here as well as in the bar) ──────────────
    // The same arithmetic as components/PlayerBar.qml's artist line, at this
    // page's 18px rather than the bar's 12px. Kept here rather than extracted
    // into a shared component because a new qml/ file has to be added to
    // QML_FILES in CMakeLists.txt, which another change owns this session; if
    // the two ever disagree, this is the pair to reconcile.
    //
    // TidalBridge::trackToMap() carries the whole artist list as [{id, name}].
    // Tracks whose map predates it — the recently-played entries saved to
    // disk, anything a caller builds by hand — only have the joined `artists`
    // string and a single `artistId`, and artistLink below stands in for them.
    readonly property var artistList:
        (hasTrack && track.artistList && track.artistList.length > 0) ? track.artistList : []

    // Sits between two names and belongs to neither, so it is not a link.
    readonly property string artistSeparator: qsTr(", ", "between two artist names")

    FontMetrics { id: artistFm; font.pixelSize: 18 }

    // Where the i-th name begins, measured on the names in front of it rather
    // than on the laid-out items: a delegate cannot see its siblings' widths,
    // and binding a width to the x a Row just assigned is how binding loops
    // start.
    function artistStartX(i) {
        if (i <= 0) return 0
        var before = []
        for (var k = 0; k < i && k < root.artistList.length; k++)
            before.push(root.artistList[k].name)
        return artistFm.advanceWidth(before.join(root.artistSeparator))
    }

    // Guarded here rather than at each of the three call sites, so a credit
    // with no id is a no-op wherever it is activated from.
    function openArtist(artistId) {
        if (artistId > 0) root.navigateTo("artist", { artistId: artistId })
    }

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
