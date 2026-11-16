pragma Singleton
import QtQuick

// The account writes that can be taken back, and the short history Ctrl+Z
// walks. A write counts once Tidal said yes and a read-back shows it; only
// then come the notice and the history entry. An undo takes the same path.
QtObject {
    id: edits

    // Newest last. Each entry is { undo: function (finish) }; see push().
    property var history: []
    readonly property int historyMax: 10
    readonly property int count: history.length

    // Waits between read-backs after the first, which goes out at once.
    // Tidal can lag behind its own yes. Writable so tests need not wait.
    property var retryDelaysMs: [500, 1000, 2000, 4000]

    // An undo is still being confirmed. Another one meanwhile is refused:
    // two undos racing on one playlist would put rows back at wrong places.
    property bool undoing: false

    // A playlist's rows changed, or may have: a page showing it reads it again.
    signal playlistChanged(string uuid)

    property Component _timerC: Component { Timer { } }

    function _later(ms, fn) {
        var t = edits._timerC.createObject(edits, { interval: Math.max(1, ms) })
        t.triggered.connect(function () { t.destroy(); fn() })
        t.start()
    }

    // check(cb) reads Tidal and calls cb(readOk, shows). done(true) once it
    // shows, done(false) when every try is spent.
    function _confirm(check, done) {
        var waits = edits.retryDelaysMs.slice(), tries = 0
        function attempt() {
            tries++
            check(function (ok, shows) {
                if (ok === true && shows === true) { done(true); return }
                if (waits.length === 0) { done(false); return }
                edits._later(waits.shift(), attempt)
            })
        }
        attempt()
    }

    function _push(entry) {
        var h = edits.history.slice()
        h.push(entry)
        while (h.length > edits.historyMax) h.shift()
        edits.history = h
    }

    function _take(entry) {
        var i = edits.history.indexOf(entry)
        if (i < 0) return false
        var h = edits.history.slice()
        h.splice(i, 1)
        edits.history = h
        return true
    }

    // A confirmed change: its notice offers Undo, and Ctrl+Z reaches it later.
    function _offer(message, undo) {
        var entry = { undo: undo }
        edits._push(entry)
        Toasts.undoable(message, function () { edits._run(entry) })
    }

    function _run(entry) {
        if (edits.undoing) {
            Toasts.show(qsTr("Still undoing the last change",
                             "shown when Undo is asked again before the last one finished"))
            return
        }
        if (!edits._take(entry)) return
        edits.undoing = true
        entry.undo(function () { edits.undoing = false })
    }

    // Ctrl+Z: the newest change, even after its notice has gone.
    function undoLast() {
        if (edits.undoing) {
            Toasts.show(qsTr("Still undoing the last change",
                             "shown when Undo is asked again before the last one finished"))
            return
        }
        if (edits.history.length === 0) {
            Toasts.show(qsTr("Nothing to undo", "shown when Ctrl+Z finds no change to take back"))
            return
        }
        edits._run(edits.history[edits.history.length - 1])
    }

    function clearHistory() {
        edits.history = []
        edits.undoing = false
    }

    readonly property string unconfirmedText:
        qsTr("Tidal did not confirm the change. Reloaded from Tidal.",
             "a write was accepted but a re-read did not show it")
    readonly property string undoFailedText:
        qsTr("Could not undo the change", "shown when an undo was refused")

    // ── favourites: like, save, follow ───────────────────────────────────
    // kind is "track", "album", "artist" or "mix". cb(ok, message) reports
    // the write itself, so a caller can show a pending state.

    function _favoriteWrite(kind, id, on, cb) {
        switch (kind) {
        case "track":  on ? bridge.addTrackFavorite(id, cb)  : bridge.removeTrackFavorite(id, cb); break
        case "album":  on ? bridge.addAlbumFavorite(id, cb)  : bridge.removeAlbumFavorite(id, cb); break
        case "artist": on ? bridge.addArtistFavorite(id, cb) : bridge.removeArtistFavorite(id, cb); break
        case "mix":    on ? bridge.addMixFavorite(id, cb)    : bridge.removeMixFavorite(id, cb); break
        }
    }

    // What a refused write says. The words are ContextMenu's, where they
    // were first written, so their translations stay.
    function _favoriteRefused(kind, on) {
        switch (kind) {
        case "track":  return on ? qsTranslate("ContextMenu", "Could not like the track",
                                               "shown when adding a track to favourites failed")
                                 : qsTranslate("ContextMenu", "Could not unlike the track",
                                               "shown when removing a track from favourites failed")
        case "album":  return on ? qsTranslate("ContextMenu", "Could not save the album",
                                               "shown when saving an album to the library failed")
                                 : qsTranslate("ContextMenu", "Could not remove the album from your collection",
                                               "shown when removing an album from the library failed")
        case "artist": return on ? qsTranslate("ContextMenu", "Could not follow the artist",
                                               "shown when following an artist failed")
                                 : qsTranslate("ContextMenu", "Could not unfollow the artist",
                                               "shown when unfollowing an artist failed")
        default:       return on ? qsTranslate("ContextMenu", "Could not save the mix",
                                               "shown when saving a mix to the library failed")
                                 : qsTranslate("ContextMenu", "Could not remove the mix from your collection",
                                               "shown when removing a mix from the library failed")
        }
    }

    // What a confirmed change says; `back` for one an undo made.
    function _favoriteDone(kind, on, back) {
        switch (kind) {
        case "track":
            if (!on) return qsTranslate("ContextMenu", "Removed from your liked tracks",
                                        "confirmation after unliking a track")
            return back ? qsTr("Back in your liked tracks", "after undoing an unlike")
                        : qsTr("Added to your liked tracks", "confirmation after liking a track")
        case "album":
            if (!on) return qsTranslate("ContextMenu", "Album removed from your collection",
                                        "confirmation after removing an album from the library")
            return back ? qsTr("Album back in your collection", "after undoing an album's removal")
                        : qsTr("Album saved to your collection", "confirmation after saving an album")
        case "artist":
            if (!on) return qsTranslate("ContextMenu", "You no longer follow this artist",
                                        "confirmation after unfollowing an artist")
            return back ? qsTr("You follow this artist again", "after undoing an unfollow")
                        : qsTr("You now follow this artist", "confirmation after following an artist")
        default:
            if (!on) return qsTranslate("ContextMenu", "Mix removed from your collection",
                                        "confirmation after removing a mix from the library")
            return back ? qsTr("Mix back in your collection", "after undoing a mix's removal")
                        : qsTr("Mix saved to your collection", "confirmation after saving a mix")
        }
    }

    // finish(confirmed) closes an undo; null for a change the user made.
    function _setFavorite(kind, id, on, cb, finish) {
        edits._favoriteWrite(kind, id, on, function (ok) {
            if (ok !== true) {
                var refused = finish ? edits.undoFailedText : edits._favoriteRefused(kind, on)
                Toasts.show(refused)
                if (cb) cb(false, refused)
                if (finish) finish(false)
                return
            }
            if (cb) cb(true, "")
            edits._confirm(function (back) {
                bridge.readFavoriteState(kind, String(id), function (readOk, present) {
                    back(readOk, present === on)
                })
            }, function (shown) {
                if (!shown) {
                    Toasts.show(edits.unconfirmedText)
                    bridge.reloadFavoriteKind(kind)
                } else if (finish) {
                    Toasts.show(edits._favoriteDone(kind, on, true))
                } else {
                    edits._offer(edits._favoriteDone(kind, on, false), function (done) {
                        edits._setFavorite(kind, id, !on, null, done)
                    })
                }
                if (finish) finish(shown)
            })
        })
    }

    function setFavorite(kind, id, on, cb) {
        edits._setFavorite(kind, id, on, cb, null)
    }

    // ── playlists ────────────────────────────────────────────────────────

    function _count(ids, trackId) {
        var n = 0
        for (var i = 0; i < ids.length; i++) if (Number(ids[i]) === Number(trackId)) n++
        return n
    }

    function _playlistCheck(uuid, test) {
        return function (back) {
            bridge.readPlaylistTrackIds(uuid, function (ok, ids) {
                back(ok, ok === true && test(ids || []))
            })
        }
    }

    // Adds a track at the end. cb(ok, message): message is what was said.
    // Tidal skips a track the playlist already holds, so that is said
    // instead and there is nothing to undo.
    function addToPlaylist(uuid, title, trackId, cb) {
        bridge.readPlaylistTrackIds(uuid, function (readOk, before) {
            var refused = qsTranslate("TrackRow", "Could not add the track to “%1”",
                                      "shown when adding a track to a playlist failed").arg(title)
            if (readOk !== true) { Toasts.show(refused); if (cb) cb(false, refused); return }
            var had = edits._count(before, trackId)
            if (had > 0) {
                var already = qsTr("Already in “%1”",
                                   "the track is in the playlist already; nothing was added").arg(title)
                Toasts.show(already)
                if (cb) cb(true, already)
                return
            }
            bridge.addTracksToPlaylist(uuid, trackId, function (ok) {
                if (ok !== true) { Toasts.show(refused); if (cb) cb(false, refused); return }
                var added = qsTranslate("TrackRow", "Added to “%1”",
                                        "confirmation after adding a track to a playlist").arg(title)
                if (cb) cb(true, added)
                edits._confirm(edits._playlistCheck(uuid, function (ids) {
                    return edits._count(ids, trackId) > had
                }), function (shown) {
                    edits.playlistChanged(uuid)
                    if (!shown) { Toasts.show(edits.unconfirmedText); return }
                    edits._offer(added, function (done) {
                        edits._takeLastOut(uuid, title, trackId, done)
                    })
                })
            })
        })
    }

    // Undoes an add: the last row holding the track, as Tidal has it now.
    function _takeLastOut(uuid, title, trackId, done) {
        bridge.readPlaylistTrackIds(uuid, function (readOk, ids) {
            if (readOk !== true) { Toasts.show(edits.undoFailedText); done(false); return }
            var at = -1
            for (var i = ids.length - 1; i >= 0; i--)
                if (Number(ids[i]) === Number(trackId)) { at = i; break }
            var gone = qsTr("Taken out of “%1” again", "after undoing an add to a playlist").arg(title)
            if (at < 0) { Toasts.show(gone); done(true); return }
            var had = edits._count(ids, trackId)
            bridge.removeTrackFromPlaylist(uuid, at, function (ok, stale) {
                if (ok !== true || stale === true) {
                    Toasts.show(edits.undoFailedText)
                    edits.playlistChanged(uuid)
                    done(false)
                    return
                }
                edits._confirm(edits._playlistCheck(uuid, function (now) {
                    return edits._count(now, trackId) < had
                }), function (shown) {
                    edits.playlistChanged(uuid)
                    Toasts.show(shown ? gone : edits.unconfirmedText)
                    done(shown)
                })
            })
        })
    }

    // Takes the row at itemIndex out. written(ok, stale, index) is the
    // bridge's reply, for the page to drop the row; the notice and Undo wait
    // for the read-back. `had` is how often the page lists the track.
    function removeFromPlaylist(uuid, title, trackId, itemIndex, had, written) {
        bridge.removeTrackFromPlaylist(uuid, itemIndex, function (ok, stale, index) {
            if (written) written(ok, stale, index)
            if (ok !== true || stale === true) return
            edits._confirm(edits._playlistCheck(uuid, function (ids) {
                return edits._count(ids, trackId) < had
            }), function (shown) {
                if (!shown) {
                    Toasts.show(edits.unconfirmedText)
                    edits.playlistChanged(uuid)
                    return
                }
                edits._offer(qsTranslate("PlaylistPage", "Removed from “%1”",
                                         "confirmation after removing a track from a playlist").arg(title),
                             function (done) { edits._putBack(uuid, title, trackId, index, done) })
            })
        })
    }

    // Undoes a removal: the track goes back at its old row, or the end when
    // the playlist has shrunk since.
    function _putBack(uuid, title, trackId, index, done) {
        bridge.readPlaylistTrackIds(uuid, function (readOk, ids) {
            if (readOk !== true) { Toasts.show(edits.undoFailedText); done(false); return }
            var at = Math.max(0, Math.min(index, ids.length))
            var had = edits._count(ids, trackId)
            bridge.restoreTrackToPlaylist(uuid, trackId, at, function (ok) {
                if (ok !== true) {
                    Toasts.show(qsTranslate("PlaylistPage", "Could not put the track back",
                                            "shown when undoing a removal from a playlist failed"))
                    edits.playlistChanged(uuid)
                    done(false)
                    return
                }
                edits._confirm(edits._playlistCheck(uuid, function (now) {
                    return edits._count(now, trackId) > had && Number(now[at]) === Number(trackId)
                }), function (shown) {
                    edits.playlistChanged(uuid)
                    Toasts.show(shown ? qsTr("Put back in “%1”",
                                             "after undoing a removal from a playlist").arg(title)
                                      : edits.unconfirmedText)
                    done(shown)
                })
            })
        })
    }

    // ── local changes ────────────────────────────────────────────────────
    // Nothing to confirm: undo() runs at once and `undone` says it happened.
    function recordLocal(message, undo, undone) {
        edits._offer(message, function (done) {
            undo()
            Toasts.show(undone)
            done(true)
        })
    }
}
