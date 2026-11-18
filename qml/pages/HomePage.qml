import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property var mixes: []
    property var recentAlbums: []
    property var playlists: []
    property var artists: []
    property bool loading: false
    // The mixes did not load. Its row says so and offers the retry; the other
    // rows hide while empty and refill from the bridge's lists.
    property bool mixesFailed: false
    property string greeting: greetingFor(new Date().getHours())

    function greetingFor(h) {
        if (h < 12) return qsTr("Good morning")
        if (h < 18) return qsTr("Good afternoon")
        return qsTr("Good evening")
    }

    Timer {
        interval: 60000; running: true; repeat: true
        onTriggered: root.greeting = root.greetingFor(new Date().getHours())
    }

    // ── what the user was listening to ───────────────────────────────────
    // Under the greeting, the user's own music: the track in the player, and
    // the albums, playlists, mixes and artists played most recently, on any
    // device: Tidal's history from the feed, merged with the plays here.
    readonly property var nowTrack: player.currentTrack
    readonly property bool hasTrack: !!nowTrack && nowTrack.id > 0

    // Played here, newest first. The app reports no plays to Tidal, so its
    // history holds none of these unless they were played elsewhere too.
    readonly property var localRecent: {
        var all = library.entries, out = []
        for (var i = 0; i < all.length; i++)
            if (all[i].lastPlayed > 0) out.push(all[i])
        out.sort(function (a, b) { return b.lastPlayed - a.lastPlayed })
        return out
    }
    readonly property var tidalRecent: {
        var mods = forYouFeed.modules || []
        for (var i = 0; i < mods.length; i++)
            if (mods[i].ownRow === "recent") return mods[i].items || []
        return []
    }
    readonly property var recentlyPlayed:
        mergeRecent(localRecent, tidalRecent, forYouFeed.fetchedAt || 0)

    function localCard(e) {
        return { id: e.id, title: e.title, coverUrl: e.imageUrl || "", kind: e.kind,
                 subtitle: e.kind === "artist" ? qsTr("Artist") : (e.subtitle || ""),
                 // An artist's subtitle is a translated label; see MediaCard.
                 pinSubtitle: e.kind === "artist" ? "" : undefined,
                 imageUrl: e.imageUrl || "", type: e.type || "", mixType: e.mixType || "" }
    }

    // Plays here since the feed was fetched first, then Tidal's list in its
    // order, then older plays here it does not hold. Each item once, where
    // it is newest; with no feed this is the plays here alone.
    function mergeRecent(local, tidal, fetchedAt) {
        var out = [], seen = {}
        function add(card) {
            var key = card.kind + ":" + card.id
            if (seen[key] || out.length >= root.rowLimit) return
            seen[key] = true
            out.push(card)
        }
        var i = 0
        for (; i < local.length && local[i].lastPlayed > fetchedAt; i++) add(localCard(local[i]))
        for (var j = 0; j < tidal.length; j++) add(feedCard(tidal[j]))
        for (; i < local.length; i++) add(localCard(local[i]))
        return out
    }

    // The row's items are library entries, so they open the way the
    // sidebar opens them.
    function openEntry(item) {
        switch (item.kind) {
        case "album":    navigateTo("album",  { albumId: parseInt(item.id) }); break
        case "artist":   navigateTo("artist", { artistId: parseInt(item.id) }); break
        case "playlist": navigateTo("playlist", { playlistUuid: item.id, playlistTitle: item.title,
                                                  coverUrl: item.coverUrl, playlistType: item.type }); break
        case "mix":      navigateTo("mix", { mixId: item.id, title: item.title, subtitle: item.subtitle,
                                             coverUrl: item.coverUrl, mixType: item.mixType }); break
        }
    }

    function playEntry(item) {
        function play(kind, tracks, err) {
            if (err || tracks.length === 0) return
            if (kind === "playlist") bridge.markPlaylistPlayed(item.id)
            player.setPlaybackSource(kind, "" + item.id, item.title || "")
            player.playTracks(tracks, 0)
        }
        switch (item.kind) {
        case "album":    bridge.fetchAlbumTracks(parseInt(item.id), function (t, e) { play("album", t, e) }); break
        case "playlist": bridge.fetchPlaylistTracks(item.id, function (t, e) { play("playlist", t, e) }); break
        case "mix":      bridge.fetchMixTracks(item.id, function (t, e) { play("mix", t, e) }); break
        default:         openEntry(item)
        }
    }

    function appWindow() { return Window.window }

    // ── Tidal's own Home ─────────────────────────────────────────────────
    // The rows Tidal's apps show on Home, in their order and under the
    // titles Tidal gives them. Home's own rows stand where the feed has its
    // counterparts. A feed that fails keeps the copy on hand, or shows none.
    property var forYouFeed: ({ tabs: [], modules: [] })
    property var staffFeed:  ({ tabs: [], modules: [] })
    property string feedTab: "static"
    property bool staffFeedAsked: false
    property bool forYouFailed: false
    property bool staffFailed: false
    readonly property string feedLanguage:
        (typeof i18n !== "undefined" && i18n) ? i18n.effectiveLanguage : "en"
    readonly property var feedTabs: forYouFeed.tabs || []
    readonly property bool onStaffPicks: feedTab === "editorial" && feedTabs.length > 1

    // The For you rows in three runs: before the favourite artists, between
    // them and the playlists, and after.
    readonly property var feedRuns: splitFeed(forYouFeed.modules || [])
    readonly property var staffRows: splitFeed(staffFeed.modules || []).reduce(
        function (all, run) { return all.concat(run) }, [])

    function splitFeed(modules) {
        var runs = [[], [], []], run = 0
        for (var i = 0; i < modules.length; i++) {
            var m = modules[i]
            if (m.ownRow === "artists")   { run = Math.max(run, 1); continue }
            if (m.ownRow === "playlists") { run = 2; continue }
            if (m.ownRow) continue
            var cards = firstOf(m.items || [], feedCard)
            if (cards.length > 0)
                runs[run].push({ id: m.id, title: m.title, subtitle: m.context || "",
                                 mediaType: m.mediaType, items: cards })
        }
        return runs
    }

    // A feed item as a card, in the shape openEntry() and playEntry() take.
    function feedCard(it) {
        switch (it.kind) {
        case "playlist":
            return { id: it.uuid, uuid: it.uuid, title: it.title, kind: "playlist",
                     subtitle: qsTr("%Ln track(s)", "", it.numTracks),
                     coverUrl: it.coverUrl, type: it.type || "" }
        case "mix":
            return { id: it.id, title: it.title, subtitle: it.subtitle || "", kind: "mix",
                     coverUrl: it.coverUrl, mixType: it.mixType || "" }
        case "artist":
            return { id: it.id, title: it.name, subtitle: qsTr("Artist"), pinSubtitle: "",
                     kind: "artist", coverUrl: it.coverUrl || "" }
        default:
            return { id: it.id, title: it.title, subtitle: it.artists, kind: "album",
                     coverUrl: it.coverUrl, artistList: it.artistList || [] }
        }
    }

    function loadFeed(feed) {
        if (feed === "editorial") root.staffFeedAsked = true
        bridge.fetchHomeFeed(feed, root.feedLanguage, function (page, err) {
            if (feed === "editorial") root.staffFailed = err.length > 0
            else root.forYouFailed = err.length > 0
            if (err.length > 0) return
            if (feed === "editorial") root.staffFeed = page
            else root.forYouFeed = page
        })
    }

    // Tidal names its tabs in title case ("Staff Picks"); the app writes
    // sentence case. Names and acronyms keep their capitals, and German its
    // nouns', so only an English feed is lowered.
    function tabTitle(name, language) {
        if (language === "de") return name
        return name.split(" ").map(function (w, i) {
            return i > 0 && /^[A-Z][a-z]+$/.test(w) && w !== "Tidal" ? w.toLowerCase() : w
        }).join(" ")
    }

    function showFeedTab(index) {
        var tab = root.feedTabs[index]
        if (!tab) return
        root.feedTab = tab.feed
        if (tab.feed === "editorial" && !root.staffFeedAsked) loadFeed("editorial")
    }

    // The titles are Tidal's, worded in the language asked for.
    Connections {
        target: (typeof i18n !== "undefined" && i18n) ? i18n : null
        ignoreUnknownSignals: true
        function onLanguageApplied() {
            root.loadFeed("static")
            if (root.staffFeedAsked) root.loadFeed("editorial")
        }
    }


    Component.onCompleted: loadContent()

    // How many tiles a row holds before "View all" is the only way to the rest.
    readonly property int rowLimit: 12

    // The Loader that holds this page is never torn down, so the favourite rows
    // follow the bridge's signals. A refresh reads the bridge's in-memory
    // favourites, the same source Collection reads.
    Connections {
        target: bridge
        // Back online: what failed loads again.
        function onOfflineChanged() { if (!bridge.offline) root.reloadFailed() }
        function onFavoriteAlbumsChanged()    { refreshDebounce.restart() }
        function onFavoriteArtistsChanged()   { refreshDebounce.restart() }
        function onFavoritePlaylistsChanged() { refreshDebounce.restart() }
        // The bridge cuts the feed's releases to the preferred version.
        function onPreferExplicitChanged() {
            root.forYouFeed = bridge.cachedHomeFeed("static")
            if (root.staffFeedAsked) root.staffFeed = bridge.cachedHomeFeed("editorial")
        }
    }

    // Each kind emits several times for one change, so the three handlers
    // coalesce into one pass.
    Timer {
        id: refreshDebounce
        interval: 120
        onTriggered: root.refreshRows()
    }

    function albumItem(a) {
        return { id: a.id, title: a.title, subtitle: a.artists,
                 coverUrl: a.coverUrl, type: "album", artistList: a.artistList || [] }
    }
    function playlistItem(p) {
        return { id: p.uuid, title: p.title,
                 subtitle: qsTr("%Ln track(s)", "", p.numTracks),
                 coverUrl: p.coverUrl, type: "playlist",
                 playlistType: p.type || "" }
    }
    function artistItem(a) {
        return { id: a.id, title: a.name, subtitle: qsTr("Artist"),
                 coverUrl: a.coverUrl || "", type: "artist" }
    }
    function firstOf(list, map) {
        var items = []
        for (var i = 0; i < Math.min(list.length, root.rowLimit); i++)
            items.push(map(list[i]))
        return items
    }

    function refreshRows() {
        recentAlbums = firstOf(bridge.searchFavoriteAlbums(""),  albumItem)
        refreshPlaylists()
        artists      = firstOf(bridge.searchFavoriteArtists(""), artistItem)
    }

    // Held until the bridge has every page: the order is recency over the
    // whole list, so a first page or the server's own order would reshuffle.
    function refreshPlaylists() {
        if (!bridge.playlistsLoading)
            playlists = firstOf(bridge.getUserPlaylists(), playlistItem)
    }

    function reloadFailed() {
        if (root.mixesFailed) root.loadMixes()
        if (root.forYouFailed) root.loadFeed("static")
        if (root.staffFailed) root.loadFeed("editorial")
        root.refreshRows()
    }

    function loadMixes() {
        loading = true
        bridge.fetchHomeMixes(function(mixList, err) {
            loading = false
            root.mixesFailed = err.length > 0
            if (err.length > 0) return
            var items = []
            for (var i = 0; i < Math.min(mixList.length, root.rowLimit); i++) {
                var m = mixList[i]
                items.push({ id: m.id, title: m.title, subtitle: m.subtitle,
                             coverUrl: m.coverUrl, type: "mix",
                             // Carried through so the tile can hand it to
                             // MixPage; see SideBar.open().
                             mixType: m.mixType || "" })
            }
            mixes = items
        })
    }

    // The first fill of albums and artists goes to the network: the cache
    // refreshRows() reads is still being paged in when this page mounts. A
    // failed fetch leaves its row hidden until the bridge's lists arrive.
    function loadContent() {
        loadMixes()
        forYouFeed = bridge.cachedHomeFeed("static")
        staffFeed  = bridge.cachedHomeFeed("editorial")
        loadFeed("static")

        bridge.fetchFavoriteAlbums(function(albums, err) {
            if (err.length > 0) return
            recentAlbums = firstOf(albums, albumItem)
        }, root.rowLimit, 0)

        refreshPlaylists()

        bridge.fetchFavoriteArtists(function(artistList, err) {
            if (err.length > 0) return
            artists = firstOf(artistList, artistItem)
        }, root.rowLimit, 0)
    }

    ScrollView {
        anchors.fill: parent
        rightPadding: Theme.space4
        contentWidth: availableWidth
        // Stated, because a ScrollView on Qt 6.5 works its content height
        // out once and does not follow the column as rows arrive.
        contentHeight: rowsColumn.implicitHeight

        ColumnLayout {
            id: rowsColumn
            width: parent.width
            spacing: 0

            // A ColumnLayout sizes a child from Layout.preferredHeight, so
            // every gap on this page sets that. A gap above a row that can be
            // empty hides with it.
            Item { Layout.preferredHeight: Theme.space6 }

            // The greeting, and Tidal's feeds as tabs at the end of its line,
            // on its baseline. Where the line cannot hold both, under it.
            Item {
                id: homeHeader
                objectName: "homeHeader"
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space6
                Layout.rightMargin: Theme.space6
                Layout.preferredHeight: homeTabs.visible
                    ? Math.max(greetingText.height, homeTabs.y + homeTabs.height) : greetingText.height

                readonly property bool tabsBelow: homeTabs.visible
                    && greetingText.implicitWidth + Theme.space6 + homeTabs.lineWidth > width

                Text {
                    id: greetingText
                    objectName: "homeTitle"
                    text: root.greeting
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontDisplay
                    font.bold: true
                }

                TabStrip {
                    id: homeTabs
                    namePrefix: "home"
                    visible: root.feedTabs.length > 1
                    animate: visible
                    x: homeHeader.tabsBelow ? 0 : homeHeader.width - width
                    y: homeHeader.tabsBelow ? greetingText.height + Theme.space4
                                            : greetingText.baselineOffset - baselineOffset
                    // Unset on the line, so the chips never wrap there.
                    width: homeHeader.tabsBelow ? homeHeader.width : undefined
                    model: root.feedTabs.map(function (t) { return root.tabTitle(t.name, root.feedLanguage) })
                    currentIndex: Math.max(0, root.feedTabs.findIndex(function (t) { return t.feed === root.feedTab }))
                    onActivated: (index) => root.showFeedTab(index)
                }
            }

            // Under it, the track in the player, to pick up where it was left.
            Item { Layout.preferredHeight: Theme.space6; visible: root.hasTrack }

            Rectangle {
                id: continueCard
                objectName: "homeContinue"
                visible: root.hasTrack
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space6
                Layout.rightMargin: Theme.space6
                Layout.preferredHeight: 104
                radius: Theme.radiusCard
                color: continueHov.hovered ? Theme.surfaceHigh : Theme.surface
                border.color: continueCard.activeFocus ? Theme.accent : Theme.border
                border.width: continueCard.activeFocus ? 2 : 1
                activeFocusOnTab: visible
                Keys.onReturnPressed: navigateTo("nowplaying", {})
                Keys.onSpacePressed:  player.playPause()
                Accessible.role: Accessible.Button
                Accessible.name: continueTitle.text + ", " + continueArtist.text
                Accessible.onPressAction: navigateTo("nowplaying", {})

                HoverHandler { id: continueHov; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: navigateTo("nowplaying", {}) }

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.space4
                    spacing: Theme.space4

                    CoverArt {
                        Layout.preferredWidth: 72
                        Layout.preferredHeight: 72
                        source: root.hasTrack ? (root.nowTrack.coverUrl || "") : ""
                        decodeSize: Qt.size(144, 144)
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceHalf
                        Text {
                            objectName: "homeContinueOverline"
                            text: player.playing ? qsTr("Now playing", "Home, over the track that plays")
                                                 : qsTr("Continue listening", "Home, over the paused track")
                            color: Theme.textSec
                            font.pixelSize: Theme.fontMicro
                            font.bold: true
                        }
                        Text {
                            id: continueTitle
                            Layout.fillWidth: true
                            text: root.hasTrack ? root.nowTrack.title || "" : ""
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontSection
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        Text {
                            id: continueArtist
                            Layout.fillWidth: true
                            text: root.hasTrack ? root.nowTrack.artists || "" : ""
                            color: Theme.textSec
                            font.pixelSize: Theme.fontBody
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: player.sourceName.length > 0 && player.sourceType !== "search"
                            text: qsTranslate("NowPlayingPage", "Playing from: %1").arg(player.sourceName)
                            color: Theme.textDim
                            font.pixelSize: Theme.fontMeta
                            elide: Text.ElideRight
                        }
                    }
                    // The one filled disc on the page: the thing to press.
                    Rectangle {
                        id: resumeButton
                        objectName: "homeResume"
                        Layout.preferredWidth: 48
                        Layout.preferredHeight: 48
                        radius: width / 2
                        color: resumeHov.hovered ? Qt.lighter(Theme.accent, 1.18) : Theme.accent
                        border.width: activeFocus ? 2 : 0
                        border.color: Theme.textPrimary
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
                            color: Theme.accentInk
                            width: 20; height: 20
                        }
                        HoverHandler { id: resumeHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: player.playPause() }
                        ToolTip.visible: resumeHov.hovered
                        ToolTip.text: Accessible.name
                        ToolTip.delay: Theme.tooltipDelay
                    }
                }
            }

            Item { Layout.preferredHeight: Theme.space6 }

            // The rows, with the gap as spacing: a Layout skips a hidden row
            // and its gap together, so no two gaps ever meet.
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.space8

                HorizontalSection {
                    objectName: "homeRecentlyPlayed"
                    Layout.fillWidth: true
                    visible: root.recentlyPlayed.length > 0 && !root.onStaffPicks
                    title: qsTr("Recently played", "Home, the row of things played here lately")
                    items: root.recentlyPlayed
                    // Each card takes its own kind; this names the row alone.
                    mediaType: "recent"
                    showViewAll: false
                    onItemClicked: (idx, item) => root.openEntry(item)
                    onItemPlayClicked: (idx, item) => root.playEntry(item)
                }

                HorizontalSection {
                    Layout.fillWidth: true
                    // Over nothing it reads as an account without mixes.
                    visible: mixes.length > 0 && !root.onStaffPicks
                    title: qsTr("My mixes")
                    items: root.mixes
                    mediaType: "mix"
                    onItemClicked: (idx, item) => navigateTo("mix", {
                        mixId: item.id, title: item.title,
                        subtitle: item.subtitle, coverUrl: item.coverUrl,
                        mixType: item.mixType || ""
                    })
                    // Declaring the source is what records the play: the player bar
                    // listens to player.sourceChanged. After the guard, so a failed
                    // or empty fetch records nothing.
                    onItemPlayClicked: (idx, item) => {
                        bridge.fetchMixTracks(item.id, function(tracks, err) {
                            if (err || tracks.length === 0) return
                            player.setPlaybackSource("mix", "" + item.id, item.title || "")
                            player.playTracks(tracks, 0)
                        })
                    }
                    onViewAllClicked: navigateTo("collection", { activeTab: 4 })
                }

                // The mixes row when its fetch failed: the heading, one line and
                // a retry, in place of cards that are not there.
                ColumnLayout {
                    objectName: "homeMixesFailed"
                    visible: root.mixesFailed && mixes.length === 0 && !root.onStaffPicks
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.space6
                    Layout.rightMargin: Theme.space6
                    spacing: Theme.space2
                    Text {
                        text: qsTr("My mixes")
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSection
                        font.bold: true
                    }
                    RowLayout {
                        spacing: Theme.space3
                        Text {
                            objectName: "homeMixesFailedText"
                            Layout.fillWidth: true
                            text: bridge.offline ? qsTr("Your mixes could not be loaded: Tidal cannot be reached.")
                                                 : qsTr("Your mixes could not be loaded.")
                            color: Theme.textSec
                            font.pixelSize: Theme.fontMeta
                            wrapMode: Text.WordWrap
                        }
                        PillButton {
                            objectName: "homeMixesRetry"
                            text: qsTr("Try again")
                            accent: false
                            Layout.preferredWidth: implicitWidth
                            Layout.preferredHeight: 32
                            onClicked: root.loadMixes()
                        }
                    }
                }

                Repeater {
                    model: root.feedRuns[0]
                    delegate: FeedRow { visible: !root.onStaffPicks }
                }

                HorizontalSection {
                    Layout.fillWidth: true
                    visible: artists.length > 0 && !root.onStaffPicks
                    title: qsTr("Favourite artists")
                    items: root.artists
                    mediaType: "artist"
                    onItemClicked: (idx, item) => navigateTo("artist", { artistId: item.id })
                    onViewAllClicked: navigateTo("collection", { activeTab: 2 })
                }

                Repeater {
                    model: root.feedRuns[1]
                    delegate: FeedRow { visible: !root.onStaffPicks }
                }

                HorizontalSection {
                    Layout.fillWidth: true
                    visible: recentAlbums.length > 0 && !root.onStaffPicks
                    title: qsTr("Saved albums")
                    items: root.recentAlbums
                    mediaType: "album"
                    onItemClicked: (idx, item) => navigateTo("album", { albumId: item.id })
                    onItemPlayClicked: (idx, item) => {
                        bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                            if (err || tracks.length === 0) return
                            player.setPlaybackSource("album", "" + item.id, item.title || "")
                            player.playTracks(tracks, 0)
                        })
                    }
                    onViewAllClicked: navigateTo("collection", { activeTab: 1 })
                }

                HorizontalSection {
                    Layout.fillWidth: true
                    visible: playlists.length > 0 && !root.onStaffPicks
                    title: qsTr("My playlists")
                    items: root.playlists
                    mediaType: "playlist"
                    onItemClicked: (idx, item) => navigateTo("playlist", { playlistUuid: item.id, playlistTitle: item.title, coverUrl: item.coverUrl, playlistType: item.playlistType || "" })
                    onItemPlayClicked: (idx, item) => {
                        bridge.fetchPlaylistTracks(item.id, function(tracks, err) {
                            if (err || tracks.length === 0) return
                            bridge.markPlaylistPlayed(item.id)
                            player.setPlaybackSource("playlist", "" + item.id, item.title || "")
                            player.playTracks(tracks, 0)
                        })
                    }
                    onViewAllClicked: navigateTo("collection", { activeTab: 3 })
                }

                Repeater {
                    model: root.feedRuns[2]
                    delegate: FeedRow { visible: !root.onStaffPicks }
                }

                // Built on the first visit and kept, as the For you rows are.
                Repeater {
                    model: root.staffFeedAsked ? root.staffRows : []
                    delegate: FeedRow { visible: root.onStaffPicks }
                }
            }

            Item { Layout.preferredHeight: Theme.space8 }
        }
    }

    // One of Tidal's rows. Its cards are of one kind or, in a "recent" row,
    // each of its own; Tidal's own pages behind "View all" are not built.
    // Both tabs' rows stay built, so a switch only shows and hides them.
    component FeedRow: HorizontalSection {
        required property var modelData
        objectName: "homeFeedRow_" + modelData.id
        Layout.fillWidth: true
        title: modelData.title
        subtitle: modelData.subtitle
        items: modelData.items
        mediaType: modelData.mediaType
        showViewAll: false
        onItemClicked: (idx, item) => root.openEntry(item)
        onItemPlayClicked: (idx, item) => root.playEntry(item)
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    Skeleton { loading: root.loading; kind: "cards" }
}
