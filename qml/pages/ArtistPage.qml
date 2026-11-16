import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    // The width the collapsed sidebar hands back. Below the rail breakpoint the
    // pane gets wider as the window narrows, so a breakpoint subtracts this to
    // measure against a width that only shrinks with the window.
    readonly property int sidebarReclaim: {
        var w = Window.window ? Window.window.width : 0
        return (w > 0 && w < prefs.railBreak())
               ? Math.max(0, prefs.sidebarWidth - prefs.rail()) : 0
    }

    property var artistId: 0
    property var artistData: ({})
    property var topTracks: []
    property var albums: []
    property bool loading: false
    property bool showAllTracks: false
    property bool isFollowing: false
    // artists/<id>/similar, fetched beside the rest. Empty hides the row.
    property var similarArtists: []
    property bool bioExpanded: false
    readonly property int bioCollapsedLines: 4

    // What the last load was told, "" when it was served.
    property string loadError: ""

    // Nothing came back at all. Every section hides when its list is empty, so
    // a refused artist would be a blank page. Gated on what the server said, so
    // an artist still in flight or with nothing filed is not called gone.
    readonly property bool loadFailed:
        loadError.length > 0 && !loading && !artistData.name
        && topTracks.length === 0 && albums.length === 0

    // The first reason is kept: all three calls fail with the same message.
    function noteLoadError(err) {
        if (root.loadError.length === 0) root.loadError = err
    }

    // Records this artist as the "playing from" source, then plays.
    function playFrom(list, i) {
        player.setPlaybackSource("artist", "" + root.artistId, root.artistData.name || "")
        player.playTracks(list, i)
    }

    function updateFollowState() {
        isFollowing = artistId > 0 ? bridge.isArtistFavorite(artistId) : false
    }

    // The Follow pill's one call, and what it says when the server refuses it.
    // isFollowing is read back from the bridge and never written here.
    readonly property alias favoriteAction: artistFav
    ContextMenu.FavoriteAction { id: artistFav }

    onArtistIdChanged: if (artistId > 0) { loadArtist(); updateFollowState() }

    Connections {
        target: bridge
        function onFavoriteArtistsChanged() { root.updateFollowState() }
    }

    function loadArtist() {
        loading = true
        loadError = ""
        bioExpanded = false
        similarArtists = []
        // Which artist these three replies are about. artistId can change while
        // they are in flight, and a reply for the artist just left must not
        // touch the one on screen. Checked before the error.
        var requested = artistId
        bridge.fetchArtistDetail(artistId, function(d, err) {
            if (requested !== root.artistId) return
            if (err) { root.noteLoadError(err); return }
            root.artistData = d
        })
        bridge.fetchArtistTopTracks(artistId, function(t, err) {
            if (requested !== root.artistId) return
            if (err) { root.noteLoadError(err); return }
            root.topTracks = t
        })
        bridge.fetchArtistAlbums(artistId, function(a, err) {
            if (requested !== root.artistId) return
            root.loading = false
            if (err) { root.noteLoadError(err); return }
            // TidalClient::fetchArtistAlbums merges its three requests, so this
            // callback is the only place that clears `loading`. The list
            // arrives with one entry per record.
            root.albums = a
        })
        // Not part of `loading` or the page's error: many artists have no
        // list (Tidal answers 404), and the row just stays hidden.
        bridge.fetchSimilarArtists(artistId, function(s, err) {
            if (requested !== root.artistId || err) return
            root.similarArtists = s
        })
    }

    // The row a release belongs in: "a" Albums, "s" Singles & EPs, "f" Appears
    // on. The bridge names it, by the rule that also says which entries are
    // one record. An entry that names none stays on the page, with the albums.
    function sectionOf(a) {
        return a.section || "a"
    }

    // Dolby Atmos and no stereo mode, as AlbumPage.atmosOnly() reads it.
    function atmosOnly(a) {
        var atmos = false, stereo = false
        for (var i = 0; a.audioModes && i < a.audioModes.length; ++i) {
            if (a.audioModes[i] === "DOLBY_ATMOS") atmos = true
            if (a.audioModes[i] === "STEREO") stereo = true
        }
        return atmos && !stereo
    }

    // A card's second line. Where the row has the title more than once, it
    // says what tells the cards apart. A card is 160 px wide, so a Dolby
    // Atmos only one gives up its year.
    function secondLine(a, withLength) {
        if (!a.titleShared) return a.year
        var tracks = a.numTracks > 0 ? qsTr("%Ln track(s)", "", a.numTracks) : ""
        var parts = root.atmosOnly(a) ? [tracks, qsTr("Dolby Atmos")] : [a.year || "", tracks]
        if (withLength && a.duration > 0) parts.push(Theme.lengthText(a.duration))
        return parts.filter(function (p) { return p.length > 0 }).join(" · ")
    }

    // The cards of a row. Two that would still read the same add their length.
    function releaseCards(list) {
        var lines = list.map(function (a) { return root.secondLine(a, false) })
        return list.map(function (a, i) {
            var alike = a.titleShared && list.some(function (b, j) {
                return j !== i && b.title === a.title && lines[j] === lines[i]
            })
            return { id: a.id, title: a.title, coverUrl: a.coverUrl,
                     subtitle: alike ? root.secondLine(a, true) : lines[i],
                     // The line can hold translated words, so a pin stores this.
                     pinSubtitle: a.year }
        })
    }

    ScrollView {
        id: artistScroll
        objectName: "artistContent"
        anchors.fill: parent
        rightPadding: Theme.space4
        contentWidth: availableWidth
        // Stated, because a ScrollView on Qt 6.5 works its content height
        // out once and does not follow the column as rows arrive.
        contentHeight: rowsColumn.implicitHeight
        // Hidden, not covered: behind the error panel the Play and Follow pills
        // would still be hit targets and tab stops for an artist the API will
        // not answer for.
        visible: !root.loadFailed

        ColumnLayout {
            id: rowsColumn
            width: parent.width
            spacing: 0

            // No artwork tile: the photo is the whole hero's backdrop.
            DetailHero {
                id: hero
                Layout.fillWidth: true
                kind: qsTr("Artist")
                title: artistData.name || ""
                titleObjectName: "artistName"
                titleLines: 2
                showArt: false
                backdropSource: artistData.coverUrl750 || ""
                backdropObjectName: "artistHeroPhoto"
                backdropOpacity: 0.4
                onPinRequested: (x, y) => {
                    var p = hero.mapToItem(root, x, y)
                    root.showHeroPinMenu(p.x, p.y)
                }

                actions: [
                    PillButton {
                        text: qsTr("Play", "verb, button label")
                        icon: "play"
                        accent: true
                        onClicked: if (topTracks.length > 0) root.playFrom(topTracks, 0)
                    },
                    PillButton {
                        // Album's word, so it shares its translation.
                        text: qsTranslate("AlbumPage", "Shuffle")
                        icon: "shuffle"
                        accent: false
                        onClicked: {
                            if (topTracks.length > 0) {
                                player.setShuffle(true)
                                root.playFrom(topTracks, Math.floor(Math.random() * topTracks.length))
                            }
                        }
                    },
                    PillButton {
                        objectName: "artistFollowPill"
                        text: root.isFollowing ? qsTr("Following") : qsTr("Follow")
                        icon: root.isFollowing ? "artist-following" : "artist-follow"
                        accent: root.isFollowing
                        // On the action row, which has clear space above.
                        onClicked: root.favoriteAction.toggleArtist(root.artistId, root.isFollowing,
                                                                  hero.actionRow)
                    }
                ]
            }

            Item { height: Theme.space2 }

            RowLayout {
                visible: root.topTracks.length > 0
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space6
                Layout.rightMargin: Theme.space6
                Text {
                    text: qsTr("Popular")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSection
                    font.bold: true
                    Layout.fillWidth: true
                }
                Text {
                    objectName: "artistShowAllTracks"
                    visible: root.topTracks.length > 5
                    text: root.showAllTracks ? qsTr("Show less") : qsTr("Show all")
                    color: showAllHov.hovered || activeFocus ? Theme.textPrimary : Theme.textSec
                    font.pixelSize: Theme.fontMeta
                    font.underline: activeFocus
                    activeFocusOnTab: visible
                    Keys.onReturnPressed: root.showAllTracks = !root.showAllTracks
                    Keys.onSpacePressed:  root.showAllTracks = !root.showAllTracks
                    Accessible.role: Accessible.Button
                    Accessible.name: text
                    Accessible.onPressAction: root.showAllTracks = !root.showAllTracks
                    HoverHandler { id: showAllHov }
                    TapHandler { onTapped: root.showAllTracks = !root.showAllTracks }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.NoButton }
                }
            }

            Item { height: Theme.space2; visible: root.topTracks.length > 0 }

            // The top tracks are one tab stop; see TrackRow.rowGroup.
            QtObject { id: topTrackGroup; property int current: 0 }
            Repeater {
                model: root.showAllTracks ? root.topTracks : root.topTracks.slice(0, 5)
                onModelChanged: topTrackGroup.current = 0
                TrackRow {
                    rowGroup: topTrackGroup
                    rowIndex: index
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.space4
                    Layout.rightMargin: Theme.space4
                    // Against the width this row would have with the sidebar
                    // out, so the column cannot reappear as the window
                    // narrows. See root.sidebarReclaim.
                    showAlbum:   width - root.sidebarReclaim >= albumBreakpoint
                    trackNum:    index + 1
                    title:       modelData.title
                    artists:     modelData.artists
                    albumTitle:  modelData.albumTitle
                    durationStr: modelData.durationStr
                    coverUrl:    modelData.coverUrl80
                    trackData:   modelData
                    onPlayRequested: root.playFrom(root.topTracks, index)
                }
            }

            Item { height: Theme.space6; visible: root.topTracks.length > 0 }

            HorizontalSection {
                id: albumsSection
                objectName: "artistAlbumsSection"
                Layout.fillWidth: true
                property var mainAlbums: root.albums.filter(function(a) {
                    return root.sectionOf(a) === "a"
                })
                visible: mainAlbums.length > 0
                title: singlesSection.singles.length > 0 ? qsTr("Albums") : qsTr("Discography")
                showViewAll: false
                mediaType: "album"
                items: root.releaseCards(mainAlbums)
                onItemClicked: function(i, item) { navigateTo("album", { albumId: item.id }) }
                // Declares the source, so the player bar records the play.
                onItemPlayClicked: function(i, item) {
                    bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                        if (err || tracks.length === 0) return
                        player.setPlaybackSource("album", "" + item.id, item.title || "")
                        player.playTracks(tracks, 0)
                    })
                }
            }

            HorizontalSection {
                id: singlesSection
                objectName: "artistSinglesSection"
                Layout.fillWidth: true
                property var singles: root.albums.filter(function(a) {
                    return root.sectionOf(a) === "s"
                })
                visible: singles.length > 0
                title: qsTr("Singles & EPs")
                showViewAll: false
                mediaType: "album"
                items: root.releaseCards(singles)
                onItemClicked: function(i, item) { navigateTo("album", { albumId: item.id }) }
                onItemPlayClicked: function(i, item) {
                    bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                        if (err || tracks.length === 0) return
                        player.setPlaybackSource("album", "" + item.id, item.title || "")
                        player.playTracks(tracks, 0)
                    })
                }
            }

            // Records by other artists that this one appears on. Last, after
            // the artist's own releases, and hidden for an artist with none.
            HorizontalSection {
                id: appearsOnSection
                objectName: "artistAppearsOnSection"
                Layout.fillWidth: true
                property var appearances: root.albums.filter(function(a) {
                    return root.sectionOf(a) === "f"
                })
                visible: appearances.length > 0
                title: qsTr("Appears on")
                showViewAll: false
                mediaType: "album"
                items: root.releaseCards(appearances)
                onItemClicked: function(i, item) { navigateTo("album", { albumId: item.id }) }
                onItemPlayClicked: function(i, item) {
                    bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                        if (err || tracks.length === 0) return
                        player.setPlaybackSource("album", "" + item.id, item.title || "")
                        player.playTracks(tracks, 0)
                    })
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space6
                Layout.rightMargin: Theme.space6
                visible: (artistData.bio || "").length > 0
                spacing: Theme.space2

                Item { height: Theme.space2 }

                Text {
                    text: qsTr("About")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSection
                    font.bold: true
                }

                FontMetrics { id: bioMetrics; font: bioText.font }

                // StyledText, not RichText: only its layout honours
                // maximumLineCount, and the clamp relies on `truncated`.
                Text {
                    id: bioText
                    objectName: "artistBio"
                    Layout.fillWidth: true
                    // About 75 characters a line; the page width is too long a line.
                    Layout.maximumWidth: Math.ceil(bioMetrics.averageCharacterWidth * 75)
                    text: root.formatBio(artistData.bio || "")
                    color: Theme.textSec
                    linkColor: Theme.accentText
                    font.pixelSize: Theme.fontBody
                    wrapMode: Text.WordWrap
                    // Of the font's own line height, which is already ~1.35 em.
                    lineHeight: 1.15
                    textFormat: Text.StyledText
                    // undefined resets the limit, so the whole bio shows.
                    maximumLineCount: root.bioExpanded ? undefined : root.bioCollapsedLines
                    elide: Text.ElideRight
                    HoverHandler {
                        cursorShape: bioText.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }
                    onLinkActivated: (link) => {
                        var parts = link.split(":")
                        if (parts.length === 2) {
                            var type = parts[0]
                            var id = Number(parts[1])
                            if (type === "artist") {
                                navigateTo("artist", { artistId: id })
                            } else if (type === "album") {
                                navigateTo("album", { albumId: id })
                            }
                        }
                    }
                }

                // Shown once the bio is cut, and kept while it is open.
                Text {
                    objectName: "artistBioToggle"
                    visible: root.bioExpanded || bioText.truncated
                    text: root.bioExpanded ? qsTr("Show less") : qsTr("Read more")
                    color: bioToggleHov.hovered ? Theme.textPrimary : Theme.textSec
                    font.pixelSize: Theme.fontMeta
                    font.bold: true
                    Accessible.role: Accessible.Button
                    Accessible.name: text
                    HoverHandler { id: bioToggleHov }
                    TapHandler { onTapped: root.bioExpanded = !root.bioExpanded }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.NoButton }
                }

                Item { height: Theme.space6 }
            }

            HorizontalSection {
                objectName: "artistRelatedSection"
                Layout.fillWidth: true
                visible: root.similarArtists.length > 0
                title: qsTr("Related artists")
                mediaType: "artist"
                showViewAll: false
                items: root.similarArtists.map(function(a) {
                    return { id: a.id, title: a.name, subtitle: qsTr("Artist"), coverUrl: a.coverUrl || "" }
                })
                onItemClicked: function(i, item) { navigateTo("artist", { artistId: item.id }) }
            }

            Item { height: Theme.space8 }
        }
    }

    function escapeBio(s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // A reference becomes a link only where it opens another page here.
    function bioLink(kind, id, label) {
        var core = label.trim()
        var words = root.escapeBio(core)
        var opens = /^\d+$/.test(id)
            && (kind === "album" || (kind === "artist" && Number(id) !== Number(root.artistId)))
        if (opens && core.length > 0)
            words = '<a href="' + kind + ':' + id + '">' + words + '</a>'
        // Spaces Tidal puts inside the reference stay outside the link.
        return (/^\s/.test(label) ? " " : "") + words + (/\s$/.test(label) ? " " : "")
    }

    // Tidal separates paragraphs with one or two <br/> and refers to pages as
    // [wimpLink artistId="…"]name[/wimpLink]. Any other markup is shown as text.
    function formatBio(bio) {
        if (!bio) return ""
        var paragraphs = bio.split(/(?:\s*<br\s*\/?>\s*|\s*\n\s*)+/i)
        var out = []
        for (var i = 0; i < paragraphs.length; ++i) {
            var p = paragraphs[i].trim()
            if (p.length === 0) continue
            var re = /\[wimpLink\s+(\w+?)Id="([^"]*)"\]([\s\S]*?)\[\/wimpLink\]/g
            var html = "", last = 0, m
            while ((m = re.exec(p)) !== null) {
                html += root.escapeBio(p.slice(last, m.index)) + root.bioLink(m[1], m[2], m[3])
                last = re.lastIndex
            }
            html += root.escapeBio(p.slice(last))
            // A reference that never closes leaves no tag on screen.
            out.push(html.replace(/\[\/?wimpLink[^\]]*\]/g, ""))
        }
        return out.join("<br><br>")
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    // The pin carries the labels and the artwork the page is showing, so the
    // sidebar row reads the same as the page it came from.
    readonly property alias pinMenu: heroPinMenu

    function showHeroPinMenu(x, y) {
        heroPinMenu.showPin(x, y, "artist", root.artistId > 0 ? "" + root.artistId : "",
                            root.artistData.name || "", "", root.artistData.coverUrl || "")
    }

    ContextMenu {
        id: heroPinMenu
        objectName: "heroPinMenu"
        // No trackSource, so no queue actions: an artist is not a tracklist.

        // The hero's action row, which has the page above it to draw over.
        confirmAnchor: hero.actionRow
    }

    // What the page says when there is nothing to draw and a reason for it.
    // Declared before the back-button bar so the bar stays on top.
    Rectangle {
        objectName: "artistLoadError"
        anchors.fill: parent
        visible: root.loadFailed
        color: Theme.bg

        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 96, 420)
            spacing: Theme.space3

            VectorIcon {
                Layout.alignment: Qt.AlignHCenter
                // A Layout owns the size of its direct children, so a plain
                // width would be overwritten.
                Layout.preferredWidth: 40
                Layout.preferredHeight: 40
                name: "artist"
                color: Theme.textDim
            }

            Text {
                objectName: "artistLoadErrorText"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("This artist is not available")
                color: Theme.textPrimary
                font.pixelSize: Theme.fontSection
                font.bold: true
                wrapMode: Text.WordWrap
            }

            // Not the server's own string, which is a Qt network error with the
            // request URL in it.
            Text {
                objectName: "artistLoadErrorDetail"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                // One long literal: lupdate cannot read a concatenation.
                text: qsTr("Tidal would not serve the page for this artist. They may have been removed from the catalogue, or they may not be available where you are. Searching for the name often finds their releases anyway.")
                color: Theme.textSec
                font.pixelSize: Theme.fontMeta
                wrapMode: Text.WordWrap
            }
        }
    }

    DetailBar {
        objectName: "artistStickyHeader"
        flickable: artistScroll.contentItem
        heroHeight: hero.height
        title: artistData.name || ""
    }

    LoadingOverlay { loading: root.loading }
}
