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

    // Asks the window's playlist picker to add these tracks (track maps)
    // wherever the user picks. Main.qml holds the one picker that answers.
    signal playlistPickRequested(var tracks)
    function pickPlaylist(tracks) {
        var list = (tracks || []).filter(function (t) { return t && Number(t.id) > 0 })
        if (list.length > 0) edits.playlistPickRequested(list)
    }

    // cb(true) when the playlist holds every one of trackIds, for the
    // picker's tick. Reads are kept per playlist until it changes or its
    // count no longer fits, and at most two go out at once.
    property var _heldCache: ({})
    property var _heldWaiting: []
    property int _heldInFlight: 0
    readonly property int heldReadsAtOnce: 2
    onPlaylistChanged: (uuid) => { delete edits._heldCache[uuid] }

    function playlistHolds(uuid, numTracks, trackIds, cb) {
        var ids = (trackIds || []).map(Number)
        if (!uuid || ids.length === 0) { cb(false); return }
        var answer = function (rows) {
            cb(ids.every(function (id) { return edits._count(rows, id) > 0 }))
        }
        var known = edits._heldCache[uuid]
        if (known && (numTracks === undefined || known.length === Number(numTracks))) {
            answer(known); return
        }
        delete edits._heldCache[uuid]
        edits._heldWaiting.push({ uuid: uuid, answer: answer, fail: function () { cb(false) } })
        edits._readHeld()
    }

    function _readHeld() {
        while (edits._heldInFlight < edits.heldReadsAtOnce && edits._heldWaiting.length > 0) {
            var w = edits._heldWaiting.shift()
            // An earlier read of the same playlist may have answered it.
            if (edits._heldCache[w.uuid]) { w.answer(edits._heldCache[w.uuid]); continue }
            edits._heldInFlight++
            bridge.readPlaylistTrackIds(w.uuid, (function (w) {
                return function (ok, rows) {
                    edits._heldInFlight--
                    if (ok === true) {
                        edits._heldCache[w.uuid] = (rows || []).map(Number)
                        w.answer(edits._heldCache[w.uuid])
                    } else {
                        w.fail()
                    }
                    edits._readHeld()
                }
            })(w))
        }
    }

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

    // Asked when a track to add is in the playlist already; DuplicateAddDialog
    // draws it. { title, dupes, total, all(), fresh() or null }; null when
    // nothing is asked. answerDuplicates() takes the answer.
    property var duplicateQuestion: null

    function answerDuplicates(choice) {
        var q = edits.duplicateQuestion
        if (!q) return
        edits.duplicateQuestion = null
        if (choice === "all") q.all()
        else if (choice === "new" && q.fresh) q.fresh()
        else if (q.cancel) q.cancel()
    }

    // Adds a track at the end. cb(ok, message): message is what was said.
    function addToPlaylist(uuid, title, trackId, cb) {
        edits.addTracksToPlaylist(uuid, title, [trackId], cb)
    }

    // Adds tracks at the end, in order. One the playlist holds already is
    // asked about first: added anyway, or left out. cb(ok, message) as above;
    // a question turned down calls it with (true, "").
    function addTracksToPlaylist(uuid, title, trackIds, cb) {
        var ids = (trackIds || []).map(Number)
        if (ids.length === 0) return
        bridge.readPlaylistTrackIds(uuid, function (readOk, before) {
            if (readOk !== true) { edits._addRefused(title, ids.length, cb); return }
            var fresh = ids.filter(function (id) { return edits._count(before, id) === 0 })
            if (fresh.length === ids.length) { edits._addTracks(uuid, title, ids, before, cb); return }
            // Asked again with the answer: the playlist can change meanwhile.
            var reread = function (list) {
                return function () {
                    bridge.readPlaylistTrackIds(uuid, function (ok, now) {
                        if (ok !== true) { edits._addRefused(title, list.length, cb); return }
                        edits._addTracks(uuid, title, list, now, cb)
                    })
                }
            }
            if (edits.duplicateQuestion) edits.answerDuplicates("cancel")
            edits.duplicateQuestion = {
                title: title, dupes: ids.length - fresh.length, total: ids.length,
                all: reread(ids),
                fresh: fresh.length > 0 ? reread(fresh) : null,
                cancel: function () { if (cb) cb(true, "") }
            }
        })
    }

    function _addRefused(title, n, cb) {
        var refused = n === 1
            ? qsTranslate("TrackRow", "Could not add the track to “%1”",
                          "shown when adding a track to a playlist failed").arg(title)
            : qsTr("Could not add the tracks to “%1”",
                   "shown when adding several tracks to a playlist failed").arg(title)
        Toasts.show(refused)
        if (cb) cb(false, refused)
    }

    // Tracks per write. Tidal takes a comma list; a whole album or queue in
    // one request would be one long form, so it goes in runs of this many.
    readonly property int addRun: 100

    // In runs of addRun, in order. A run holding a track the playlist has,
    // or one listed twice, asks for ADD so each lands as one more row; the
    // rest SKIP. `before` is the playlist as it was read.
    function _addTracks(uuid, title, ids, before, cb) {
        var had = ids.map(function (id) { return edits._count(before, id) })
        var runs = []
        for (var k = 0; k < ids.length; k += edits.addRun) runs.push(k)
        var r = 0
        function next() {
            if (r === runs.length) { edits._added(uuid, title, ids, had, cb); return }
            var from = runs[r], to = Math.min(ids.length, from + edits.addRun)
            r++
            var run = ids.slice(from, to), again = false
            for (var j = from; j < to; j++)
                if (had[j] > 0 || ids.indexOf(ids[j]) < j) again = true
            bridge.addTrackListToPlaylist(uuid, run, again, function (ok) {
                if (ok !== true) {
                    edits._addRefused(title, ids.length, cb)
                    if (r > 1) edits.playlistChanged(uuid)
                    return
                }
                next()
            })
        }
        next()
    }

    function _added(uuid, title, ids, had, cb) {
        var added = ids.length === 1
            ? qsTranslate("TrackRow", "Added to “%1”",
                          "confirmation after adding a track to a playlist").arg(title)
            : qsTr("%Ln track(s) added to “%1”",
                   "confirmation after adding several tracks to a playlist", ids.length).arg(title)
        if (cb) cb(true, added)
        edits._confirm(edits._playlistCheck(uuid, function (now) {
            for (var k = 0; k < ids.length; k++)
                if (edits._count(now, ids[k]) <= had[k]) return false
            return true
        }), function (shown) {
            edits.playlistChanged(uuid)
            if (!shown) { Toasts.show(edits.unconfirmedText); return }
            edits._offer(added, function (done) {
                edits._takeLastOut(uuid, title, ids.slice(), done)
            })
        })
    }

    // Undoes an add: for each track the last row holding it, as Tidal has
    // it now, newest first.
    function _takeLastOut(uuid, title, ids, done) {
        var gone = qsTr("Taken out of “%1” again", "after undoing an add to a playlist").arg(title)
        var left = ids.slice()
        function next(changed) {
            if (left.length === 0) {
                if (changed) edits.playlistChanged(uuid)
                Toasts.show(gone)
                done(true)
                return
            }
            var trackId = left.pop()
            bridge.readPlaylistTrackIds(uuid, function (readOk, rows) {
                if (readOk !== true) { Toasts.show(edits.undoFailedText); done(false); return }
                var at = -1
                for (var i = rows.length - 1; i >= 0; i--)
                    if (Number(rows[i]) === Number(trackId)) { at = i; break }
                if (at < 0) { next(changed); return }
                var had = edits._count(rows, trackId)
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
                        if (!shown) {
                            edits.playlistChanged(uuid)
                            Toasts.show(edits.unconfirmedText)
                            done(false)
                            return
                        }
                        next(true)
                    })
                })
            })
        }
        next(false)
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

    // Moves the row at `from` so it ends at `to`. written(ok, stale) is the
    // bridge's reply, for the page to move the row. No notice, as a drag
    // shows itself; Ctrl+Z moves it back once the read-back shows it.
    function movePlaylistItem(uuid, title, trackId, from, to, written) {
        bridge.moveTrackInPlaylist(uuid, from, to, function (ok, stale) {
            if (written) written(ok, stale)
            if (ok !== true || stale === true) {
                if (ok !== true && stale !== true)
                    Toasts.show(qsTr("Could not move the track", "shown when reordering a playlist failed"))
                return
            }
            edits._confirm(edits._playlistCheck(uuid, function (ids) {
                return Number(ids[to]) === Number(trackId)
            }), function (shown) {
                if (!shown) {
                    Toasts.show(edits.unconfirmedText)
                    edits.playlistChanged(uuid)
                    return
                }
                edits._push({ undo: function (done) { edits._moveBack(uuid, title, trackId, to, from, done) } })
            })
        })
    }

    function _moveBack(uuid, title, trackId, from, to, done) {
        bridge.readPlaylistTrackIds(uuid, function (readOk, ids) {
            // Moved again since, or no longer there: not this undo's to touch.
            if (readOk !== true || Number(ids[from]) !== Number(trackId)) {
                Toasts.show(edits.undoFailedText); done(false); return
            }
            bridge.moveTrackInPlaylist(uuid, from, to, function (ok) {
                if (ok !== true) {
                    Toasts.show(edits.undoFailedText)
                    edits.playlistChanged(uuid)
                    done(false)
                    return
                }
                edits._confirm(edits._playlistCheck(uuid, function (now) {
                    return Number(now[to]) === Number(trackId)
                }), function (shown) {
                    edits.playlistChanged(uuid)
                    Toasts.show(shown ? qsTr("Moved back in “%1”", "after undoing a move in a playlist").arg(title)
                                      : edits.unconfirmedText)
                    done(shown)
                })
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
