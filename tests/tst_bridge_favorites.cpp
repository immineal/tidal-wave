// TidalBridge's own in-memory caches: the lists the interface reads instead of
// the server.
//
// ── why this file was rewritten ──────────────────────────────────────────────
//
// It used to hold three cases that could not fail. None of them instantiated a
// TidalBridge; each built a local QList<Album>, performed by hand what the bridge
// was supposed to perform, and then asserted that its own two lines had done what
// its own two lines do. `addMustInsertNotJustSignal` appended an album if its own
// data column said to and then checked whether the album it had just appended was
// there. Every one of them stayed green for any possible change to
// TidalBridge.cpp, including deleting the method under test.
//
// The cost of that came due: a playlist the user had just put two songs into went
// on reporting "0 tracks" everywhere the number is cached, because
// addTracksToPlaylist told the server and updated nothing, and no test in the tree
// instantiated the class that was supposed to do the updating.
//
// So these cases drive a real TidalBridge. The seam is four `virtual`s on
// TidalClient - createPlaylist, fetchPlaylist, addTrackToPlaylist and
// removeTrackFromPlaylist - which is the same arrangement LibraryIndex has had all
// along behind its six protected virtuals, and FakeClient below answers them from
// lists this file owns. Nothing here touches the network and nothing here needs a
// Tidal session.
//
// ── what is still not covered, and why ───────────────────────────────────────
//
// The album, artist and track favourites the old file was named for. Those paths
// run through client calls that are not virtual, so there is no way to answer one,
// and `isAlbumFavorite` cannot be reached after a `addAlbumFavorite` that never
// comes back. Widening the seam to the whole of TidalClient to cover them is a
// bigger change than this fix, and it is recorded rather than half-done: the three
// cases that claimed to cover them are gone, because a green that cannot fail is
// worse than an absence anybody can see.

#include <QTest>
#include <QSignalSpy>
#include <QJSEngine>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>

#include "api/TidalBridge.h"
#include "api/TidalClient.h"
#include "api/Models.h"

using namespace Tidal;

// Every fixture is invented. `addedAt` is passed explicitly wherever a case is
// about the ordering key, because 0 - "the response carried no date" - is exactly
// the value that would hide a bug that overwrote it.
Playlist mkPlaylist(const QString &uuid, const QString &title, int numTracks,
                    int duration, const QString &image, qint64 addedAt) {
    Playlist p;
    p.uuid      = uuid;
    p.title     = title;
    p.numTracks = numTracks;
    p.duration  = duration;
    p.image     = image;
    p.type      = QStringLiteral("USER");
    p.addedAt   = addedAt;
    return p;
}

// A TidalClient with the four playlist calls answered from lists the test fills
// in. The api pointer is null and is never dereferenced, because no non-virtual
// method is called on this.
class FakeClient : public TidalClient {
    Q_OBJECT
public:
    FakeClient() : TidalClient(nullptr) {}

    // Readable from JS, so a callback handed to the bridge can record what the
    // client had been asked for at the moment it was answered. That is the only
    // way to pin the *order* of the two from out here: the callback is a
    // QJSValue, so the observation has to be made in script.
    Q_INVOKABLE int headerReadsSoFar() const { return headerReads; }

    // What the next createPlaylist answers.
    Playlist created;
    QString  createError;

    // What `playlists/<uuid>` answers, per uuid. A uuid with no entry answers an
    // error, which is the "the re-read failed" case.
    QHash<QString, Playlist> headers;
    QString                  headerError;

    bool addOk    = true;
    bool removeOk = true;

    int createCalls = 0;
    int addCalls    = 0;
    int removeCalls = 0;
    // The count that matters for the round-trip argument: one per accepted
    // mutation and none per refused one.
    int headerReads = 0;
    QStringList headerReadUuids;

    // Holds the header reply so a test can assert what the cache looked like
    // before it landed as well as after.
    bool deferHeaders = false;

    void deliverHeaders() {
        while (!m_parked.isEmpty()) {
            const Parked p = m_parked.takeFirst();
            answerHeader(p.uuid, p.cb);
        }
    }
    int parkedHeaders() const { return int(m_parked.size()); }

    void createPlaylist(const QString &title,
                        std::function<void(Playlist, QString)> cb) override {
        ++createCalls;
        if (!createError.isEmpty()) { cb({}, createError); return; }
        Playlist p = created;
        if (p.title.isEmpty()) p.title = title;
        cb(p, QString());
    }

    void fetchPlaylist(const QString &uuid,
                       std::function<void(Playlist, QString)> cb) override {
        ++headerReads;
        headerReadUuids << uuid;
        if (deferHeaders) { m_parked.append({uuid, cb}); return; }
        answerHeader(uuid, cb);
    }

    void addTrackToPlaylist(const QString &uuid, qint64 trackId,
                            std::function<void(bool)> cb) override {
        Q_UNUSED(uuid); Q_UNUSED(trackId);
        ++addCalls;
        cb(addOk);
    }

    void removeTrackFromPlaylist(const QString &uuid, int itemIndex,
                                 std::function<void(bool)> cb) override {
        Q_UNUSED(uuid); Q_UNUSED(itemIndex);
        ++removeCalls;
        cb(removeOk);
    }

    // ── the favourite-mix seam ───────────────────────────────────────────
    //
    // Three more virtuals, answered from here. The real ones are a v2 PUT and a
    // `pages/mix` GET; without the seam nothing could reach isMixFavorite()
    // after an addMixFavorite() that never comes back - which is exactly the
    // hole this file's header paragraph records for albums and artists.

    bool addMixOk    = true;
    bool removeMixOk = true;
    QStringList mixCalls;          // "add:<id>" / "remove:<id>", in order
    // What `pages/mix` answers for the row the bridge re-reads on an accepted
    // save, per id. An id with no entry answers an error, which is the "the
    // re-read failed" case - the sidebar gets nothing and the cache still moves.
    QHash<QString, Mix> mixHeaders;
    int  mixHeaderReads = 0;
    // The whole saved list, for the sign-in load. Never reached in this file:
    // calling setUserId() on a client with a null api would send the four v1
    // favourites pagers at a null pointer. Overridden anyway, so that a future
    // case which does seed this way cannot reach the network by accident.
    QList<Mix> savedMixes;

    void fetchFavoriteMixes(MixesCallback cb) override { cb(savedMixes, QString()); }

    void addMixFavorite(const QString &mixId, std::function<void(bool)> cb) override {
        mixCalls << QStringLiteral("add:") + mixId;
        cb(addMixOk);
    }

    void removeMixFavorite(const QString &mixId, std::function<void(bool)> cb) override {
        mixCalls << QStringLiteral("remove:") + mixId;
        cb(removeMixOk);
    }

    // What the page's TRACK_LIST holds. Only the map-shape case below uses it;
    // the save path drops the tracks.
    QList<Track> mixPageTracks;

    // What `tracks/<id>` answers, per id, for the "which mix is this track's
    // radio" lookup. An id with no entry answers an error.
    QHash<qint64, Track> tracks;
    QString trackError;
    int     trackReads = 0;

    void fetchTrack(qint64 trackId, std::function<void(Track, QString)> cb) override {
        ++trackReads;
        if (!trackError.isEmpty())  { cb({}, trackError); return; }
        if (!tracks.contains(trackId)) { cb({}, QStringLiteral("404")); return; }
        cb(tracks.value(trackId), QString());
    }

    void fetchMixPage(const QString &mixId, MixPageCallback cb) override {
        ++mixHeaderReads;
        if (!mixHeaders.contains(mixId)) { cb({}, {}, QStringLiteral("404")); return; }
        cb(mixHeaders.value(mixId), mixPageTracks, QString());
    }

private:
    void answerHeader(const QString &uuid, std::function<void(Playlist, QString)> cb) {
        if (!headerError.isEmpty())    { cb({}, headerError); return; }
        if (!headers.contains(uuid))   { cb({}, QStringLiteral("404")); return; }
        cb(headers.value(uuid), QString());
    }

    struct Parked { QString uuid; std::function<void(Playlist, QString)> cb; };
    QList<Parked> m_parked;
};

namespace {

QVariantMap rowFor(const QVariantList &rows, const QString &uuid) {
    for (const QVariant &v : rows) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("uuid")).toString() == uuid) return m;
    }
    return {};
}

} // namespace

class TestBridgeFavorites : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        // Never the owner's real configuration. The bridge's constructor reads
        // audio/preferredQuality, and sortPlaylists() would read the stored play
        // times for a signed-in account.
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_bridge_favorites"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
    }

    // ── the reported bug ────────────────────────────────────────────────────
    //
    // "If I create a new playlist and then add two songs to it, the two songs are
    // in the playlist, but in the add-to-playlist menu it still says the playlist
    // has zero tracks."
    //
    // Driven exactly that way round: create, then add, then read the list the
    // picker reads. getUserPlaylists() is what TrackRow's picker fills its rows
    // from, and numTracks is the field it draws.
    void addingTracksMovesTheCountThePickerReads() {
        Harness h;
        h.client.created = mkPlaylist(kUuid, QStringLiteral("Tape"), 0, 0, QString(), kJan2026);
        h.bridge.createPlaylist(QStringLiteral("Tape"), QJSValue());
        QCOMPARE(h.client.createCalls, 1);
        QCOMPARE(rowFor(h.bridge.getUserPlaylists(), kUuid)
                     .value(QStringLiteral("numTracks")).toInt(), 0);

        // Two songs on, and the server's header now says so. 418 seconds is the
        // pair's combined length; it has to differ from 0 for the duration half
        // of the assertion to mean anything.
        h.client.headers[kUuid] =
            mkPlaylist(kUuid, QStringLiteral("Tape"), 2, 418,
                       QStringLiteral("mosaic-after-two"), kJan2026);

        h.bridge.addTracksToPlaylist(kUuid, 101, QJSValue());
        h.bridge.addTracksToPlaylist(kUuid, 102, QJSValue());

        const QVariantMap row = rowFor(h.bridge.getUserPlaylists(), kUuid);
        QCOMPARE(row.value(QStringLiteral("numTracks")).toInt(), 2);
        QCOMPARE(row.value(QStringLiteral("duration")).toInt(), 418);
        // The cover moves on the same event: a USER playlist's artwork is a
        // mosaic Tidal builds out of its first tracks, so an empty playlist that
        // gains songs gains a picture.
        QVERIFY(row.value(QStringLiteral("coverUrl")).toString()
                    .contains(QStringLiteral("mosaic/after/two")));
    }

    // One accepted mutation, one header read. This is the whole cost of the
    // chosen fix, and it is asserted rather than described: a version that read
    // the header on every picker open, or twice per add, would fail here.
    void anAcceptedAddCostsExactlyOneHeaderRead() {
        Harness h;
        h.fillOne(0, 0);
        h.client.headers[kUuid] = mkPlaylist(kUuid, QStringLiteral("Tape"), 1, 200,
                                             QStringLiteral("img"), kJan2026);

        h.bridge.addTracksToPlaylist(kUuid, 101, QJSValue());

        QCOMPARE(h.client.addCalls, 1);
        QCOMPARE(h.client.headerReads, 1);
        QCOMPARE(h.client.headerReadUuids, QStringList{kUuid});
    }

    // A post the server refused must move nothing and must not pay for a reply
    // that would only confirm what is already cached.
    void arefusedAddReadsNothingAndMovesNothing() {
        Harness h;
        h.fillOne(5, 900);
        // Set, so that a version which re-read the header anyway would visibly
        // overwrite the row rather than quietly cost a request.
        h.client.headers[kUuid] = mkPlaylist(kUuid, QStringLiteral("Tape"), 6, 1100,
                                             QStringLiteral("img-6"), kJan2026);
        h.client.addOk = false;

        QSignalSpy changed(&h.bridge, &TidalBridge::favoritePlaylistsChanged);
        QSignalSpy stats(&h.bridge, &TidalBridge::playlistStatsChanged);
        h.bridge.addTracksToPlaylist(kUuid, 101, QJSValue());

        QCOMPARE(h.client.addCalls, 1);
        QCOMPARE(h.client.headerReads, 0);
        QCOMPARE(changed.count(), 0);
        QCOMPARE(stats.count(), 0);
        QCOMPARE(rowFor(h.bridge.getUserPlaylists(), kUuid)
                     .value(QStringLiteral("numTracks")).toInt(), 5);
    }

    // The mirror of the add, which had the same bug the other way up: taking a
    // song off left every cached count one too high.
    void removingATrackMovesTheCountBackDown() {
        Harness h;
        h.fillOne(3, 700);
        h.client.headers[kUuid] = mkPlaylist(kUuid, QStringLiteral("Tape"), 2, 460,
                                             QStringLiteral("img-2"), kJan2026);

        QSignalSpy changed(&h.bridge, &TidalBridge::favoritePlaylistsChanged);
        h.bridge.removeTrackFromPlaylist(kUuid, 0, QJSValue());

        QCOMPARE(h.client.removeCalls, 1);
        QCOMPARE(h.client.headerReads, 1);
        QCOMPARE(changed.count(), 1);
        const QVariantMap row = rowFor(h.bridge.getUserPlaylists(), kUuid);
        QCOMPARE(row.value(QStringLiteral("numTracks")).toInt(), 2);
        QCOMPARE(row.value(QStringLiteral("duration")).toInt(), 460);
    }

    void arefusedRemovalReadsNothingAndMovesNothing() {
        Harness h;
        h.fillOne(3, 700);
        h.client.headers[kUuid] = mkPlaylist(kUuid, QStringLiteral("Tape"), 2, 460,
                                             QStringLiteral("img-2"), kJan2026);
        h.client.removeOk = false;

        QSignalSpy changed(&h.bridge, &TidalBridge::favoritePlaylistsChanged);
        h.bridge.removeTrackFromPlaylist(kUuid, 0, QJSValue());

        QCOMPARE(h.client.removeCalls, 1);
        QCOMPARE(h.client.headerReads, 0);
        QCOMPARE(changed.count(), 0);
        QCOMPARE(rowFor(h.bridge.getUserPlaylists(), kUuid)
                     .value(QStringLiteral("numTracks")).toInt(), 3);
    }

    // ── the trap ────────────────────────────────────────────────────────────
    //
    // `playlists/<uuid>` carries no favourites wrapper, so Playlist::fromJson
    // falls back to the playlist's own `created` - the original author's date,
    // which on a followed playlist can be years old. Half the ordering key every
    // reader of this list uses is max(last played, addedAt), so a merge that
    // copied it would sink a playlist to the bottom of the library for the crime
    // of having a song dropped on it. A fork patch did exactly that.
    //
    // The fixture is three playlists with distinct dates and the one being added
    // to in the *middle*, so the assertion can see a row move in either
    // direction. The header answers an addedAt from 2019, well before all three.
    void aHeaderReadNeverOverwritesTheDateTheRowIsOrderedBy() {
        Harness h;
        h.fill({ mkPlaylist(QStringLiteral("p-new"),  QStringLiteral("Newest"), 4, 800,
                            QStringLiteral("i1"), daysAfterJan(30)),
                 mkPlaylist(kUuid,                     QStringLiteral("Tape"),   0, 0,
                            QString(),            daysAfterJan(20)),
                 mkPlaylist(QStringLiteral("p-old"),  QStringLiteral("Oldest"), 7, 900,
                            QStringLiteral("i3"), daysAfterJan(10)) });
        QCOMPARE(uuidsOf(h.bridge.getUserPlaylists()),
                 (QStringList{QStringLiteral("p-new"), kUuid, QStringLiteral("p-old")}));

        h.client.headers[kUuid] = mkPlaylist(kUuid, QStringLiteral("Tape"), 2, 418,
                                             QStringLiteral("img-2"), kAuthored2019);
        h.bridge.addTracksToPlaylist(kUuid, 101, QJSValue());

        const QVariantList rows = h.bridge.getUserPlaylists();
        // The count moved.
        QCOMPARE(rowFor(rows, kUuid).value(QStringLiteral("numTracks")).toInt(), 2);
        // The row did not. Had addedAt been copied, "Tape" would be last.
        QCOMPARE(uuidsOf(rows),
                 (QStringList{QStringLiteral("p-new"), kUuid, QStringLiteral("p-old")}));
    }

    // A header the server confirmed unchanged is not a redraw. Four readers
    // rebuild a grid or a row off this signal, and rebuild() in the sidebar's
    // copy collates every row in the library.
    void aHeaderThatSaysNothingNewRaisesNoRedraw() {
        Harness h;
        h.fillOne(2, 418);
        h.client.headers[kUuid] = mkPlaylist(kUuid, QStringLiteral("Tape"), 2, 418,
                                             QStringLiteral("img"), kJan2026);

        QSignalSpy changed(&h.bridge, &TidalBridge::favoritePlaylistsChanged);
        QSignalSpy stats(&h.bridge, &TidalBridge::playlistStatsChanged);
        h.bridge.addTracksToPlaylist(kUuid, 101, QJSValue());

        QCOMPARE(changed.count(), 0);
        // The hand-across to the sidebar's separate list goes out regardless,
        // because whether this list holds the row says nothing about whether
        // that one does - and that one may well be behind.
        QCOMPARE(stats.count(), 1);
    }

    // A re-read that failed is not news about the playlist, and must not write
    // the parse of an error body into the row.
    //
    // Honest about which guard earns this: the uuid check, not the error check.
    // TidalClient::fetchPlaylist answers an error with a default-constructed
    // Playlist, so the reply that arrives here has an empty uuid and would be
    // refused with the `err` test deleted - a mutation that removed it passed, and
    // no fixture can make it fail without inventing a reply the real client cannot
    // produce. The case is kept because the behaviour it describes is the one that
    // matters; the note is here so nobody reads it as cover for the other half.
    void aFailedHeaderReadLeavesTheRowAlone() {
        Harness h;
        h.fillOne(2, 418);
        h.client.headerError = QStringLiteral("network is down");

        QSignalSpy changed(&h.bridge, &TidalBridge::favoritePlaylistsChanged);
        QSignalSpy stats(&h.bridge, &TidalBridge::playlistStatsChanged);
        h.bridge.addTracksToPlaylist(kUuid, 101, QJSValue());

        QCOMPARE(h.client.headerReads, 1);
        QCOMPARE(changed.count(), 0);
        QCOMPARE(stats.count(), 0);
        const QVariantMap row = rowFor(h.bridge.getUserPlaylists(), kUuid);
        QCOMPARE(row.value(QStringLiteral("numTracks")).toInt(), 2);
        QCOMPARE(row.value(QStringLiteral("title")).toString(), QStringLiteral("Tape"));
    }

    // A reply about a different playlist, which is what a mismatched or
    // truncated response parses to. The row it was asked about must not take the
    // other playlist's numbers, and neither must anything else.
    void aHeaderAboutAnotherPlaylistIsIgnored() {
        Harness h;
        h.fill({ mkPlaylist(kUuid, QStringLiteral("Tape"), 2, 418,
                            QStringLiteral("img"), daysAfterJan(20)),
                 mkPlaylist(QStringLiteral("p-other"), QStringLiteral("Other"), 9, 999,
                            QStringLiteral("i9"), daysAfterJan(10)) });
        // The reply to "tell me about kUuid" comes back about p-other.
        h.client.headers[kUuid] = mkPlaylist(QStringLiteral("p-other"),
                                             QStringLiteral("Other"), 9, 999,
                                             QStringLiteral("i9"), daysAfterJan(10));

        QSignalSpy changed(&h.bridge, &TidalBridge::favoritePlaylistsChanged);
        h.bridge.addTracksToPlaylist(kUuid, 101, QJSValue());

        QCOMPARE(changed.count(), 0);
        QCOMPARE(rowFor(h.bridge.getUserPlaylists(), kUuid)
                     .value(QStringLiteral("numTracks")).toInt(), 2);
        QCOMPARE(rowFor(h.bridge.getUserPlaylists(), kUuid)
                     .value(QStringLiteral("title")).toString(), QStringLiteral("Tape"));
    }

    // The caller hears the server's answer before the second request even goes
    // out, so the "Added to …" in the picker is never waiting on the repair.
    //
    // Observed from inside a real JS callback, because that is the only place the
    // order of the two is visible: by the time the test regains control both have
    // happened.
    void theCallerIsAnsweredBeforeTheHeaderIsAskedFor() {
        Harness h;
        h.fillOne(0, 0);
        h.client.headers[kUuid] = mkPlaylist(kUuid, QStringLiteral("Tape"), 1, 200,
                                             QStringLiteral("img"), kJan2026);

        QJSEngine::setObjectOwnership(&h.client, QJSEngine::CppOwnership);
        h.engine.globalObject().setProperty(QStringLiteral("fakeClient"),
                                            h.engine.newQObject(&h.client));
        // A plain object held on the global, not `globalThis`: Qt's engine does
        // not define that name, so assigning through it throws inside the
        // callback and the probe records nothing - which is how this case first
        // went red while the code under test was correct.
        QJSValue probe = h.engine.newObject();
        h.engine.globalObject().setProperty(QStringLiteral("probe"), probe);
        QJSValue cb = h.engine.evaluate(
            QStringLiteral("(function (ok) {"
                           "  probe.ok    = ok;"
                           "  probe.reads = fakeClient.headerReadsSoFar();"
                           "})"));
        QVERIFY(cb.isCallable());

        h.bridge.addTracksToPlaylist(kUuid, 101, cb);

        // The probe really ran, so the two assertions under it are about the
        // bridge and not about an exception nobody saw.
        QVERIFY(probe.property(QStringLiteral("ok")).isBool());
        QCOMPARE(probe.property(QStringLiteral("ok")).toBool(), true);
        // Nothing had been asked for yet when the picker was told it worked.
        QCOMPARE(probe.property(QStringLiteral("reads")).toInt(), 0);
        // And the repair did then happen.
        QCOMPARE(h.client.headerReads, 1);
    }

    // The count is never written on the strength of the post alone. A version
    // that added one to what it already held - which is wrong anyway, because the
    // post sends onDuplicateFound=SKIP and a song already on the playlist is
    // accepted without being added - would move the row here, with the header
    // request still unanswered.
    void theCacheIsNotWrittenUntilTheHeaderAnswers() {
        Harness h;
        h.fillOne(0, 0);
        h.client.headers[kUuid] = mkPlaylist(kUuid, QStringLiteral("Tape"), 1, 200,
                                             QStringLiteral("img"), kJan2026);
        h.client.deferHeaders = true;

        h.bridge.addTracksToPlaylist(kUuid, 101, QJSValue());
        QCOMPARE(h.client.parkedHeaders(), 1);
        QCOMPARE(rowFor(h.bridge.getUserPlaylists(), kUuid)
                     .value(QStringLiteral("numTracks")).toInt(), 0);

        h.client.deliverHeaders();
        QCOMPARE(rowFor(h.bridge.getUserPlaylists(), kUuid)
                     .value(QStringLiteral("numTracks")).toInt(), 1);
    }

    // ── the merge rule on its own ───────────────────────────────────────────
    //
    // mergePlaylistMeta is the one function both caches run, so the field list
    // and the exclusions are pinned here field by field rather than inferred from
    // the two call sites.
    void theMergeWritesFourFieldsAndRefusesTheRest() {
        Playlist dst = mkPlaylist(kUuid, QStringLiteral("Old name"), 2, 418,
                                  QStringLiteral("img-old"), daysAfterJan(20));
        dst.description = QStringLiteral("what the user typed");

        Playlist fresh = mkPlaylist(kUuid, QStringLiteral("New name"), 5, 999,
                                    QStringLiteral("img-new"), kAuthored2019);
        fresh.description = QStringLiteral("what the server still has");
        fresh.type        = QStringLiteral("EDITORIAL");

        QVERIFY(mergePlaylistMeta(dst, fresh));

        QCOMPARE(dst.numTracks, 5);
        QCOMPARE(dst.duration,  999);
        QCOMPARE(dst.image,     QStringLiteral("img-new"));
        QCOMPARE(dst.title,     QStringLiteral("New name"));
        // The ordering key, the identity, the type and the text the rename path
        // owns all stay.
        QCOMPARE(dst.addedAt,     daysAfterJan(20));
        QCOMPARE(dst.uuid,        kUuid);
        QCOMPARE(dst.type,        QStringLiteral("USER"));
        QCOMPARE(dst.description, QStringLiteral("what the user typed"));
    }

    void theMergeAnswersFalseWhenNothingMoved() {
        Playlist dst   = mkPlaylist(kUuid, QStringLiteral("Tape"), 2, 418,
                                    QStringLiteral("img"), daysAfterJan(20));
        Playlist fresh = mkPlaylist(kUuid, QStringLiteral("Tape"), 2, 418,
                                    QStringLiteral("img"), kAuthored2019);
        QVERIFY(!mergePlaylistMeta(dst, fresh));
        QCOMPARE(dst.addedAt, daysAfterJan(20));
    }

    // Emptying a playlist really does take it back to no tracks, no length and
    // no mosaic, so those three are written even when the new value is the empty
    // one. A merge that skipped empties would leave the last cover on a playlist
    // with nothing in it.
    void theMergeWritesTheEmptyCaseForTheThreeFieldsItDescribes() {
        Playlist dst = mkPlaylist(kUuid, QStringLiteral("Tape"), 1, 200,
                                  QStringLiteral("img"), daysAfterJan(20));
        Playlist fresh = mkPlaylist(kUuid, QStringLiteral("Tape"), 0, 0,
                                    QString(), kAuthored2019);
        QVERIFY(mergePlaylistMeta(dst, fresh));
        QCOMPARE(dst.numTracks, 0);
        QCOMPARE(dst.duration,  0);
        QVERIFY(dst.image.isEmpty());
    }

    // The title is the exception, and for a reason that is not symmetry: Tidal
    // will not hold a nameless playlist, so "" is never a fact about one - it is
    // a reply that did not parse. Blanking the label would leave a row nobody
    // can identify.
    void theMergeRefusesToBlankTheTitle() {
        Playlist dst = mkPlaylist(kUuid, QStringLiteral("Tape"), 2, 418,
                                  QStringLiteral("img"), daysAfterJan(20));
        Playlist fresh = mkPlaylist(kUuid, QString(), 3, 600,
                                    QStringLiteral("img-3"), kAuthored2019);
        QVERIFY(mergePlaylistMeta(dst, fresh));
        QCOMPARE(dst.title,     QStringLiteral("Tape"));
        QCOMPARE(dst.numTracks, 3);
    }

    // ── saving and unsaving a mix ───────────────────────────────────────
    //
    // The owner's longest-standing complaint, at the layer that answers "is this
    // saved": a track radio arrived in the sidebar from another device, opened on
    // MixPage, and had no way to be unsaved - and no way to be saved either,
    // because "Start radio" opened a different page with no mix id on it.
    //
    // The pill reads its state back out of isMixFavorite(), so if the cache does
    // not move on an accepted save the pill goes on saying "Save" over a mix that
    // is now in the library. That is the gap addAlbumFavorite was fixed for, and
    // these cases are here so the mix never has it.
    //
    // Every id is invented, at the shape a real one has: 30 lowercase hex
    // characters. None of the owner's is in this file.

    void aMixIsNotSavedUntilItIsSaved() {
        Harness h;
        QVERIFY(!h.bridge.isMixFavorite(kMixId));
        // And an empty id is never saved, whatever is in the set.
        QVERIFY(!h.bridge.isMixFavorite(QString()));
    }

    void anAcceptedSaveMovesTheStateThePillReads() {
        Harness h;
        QSignalSpy moved(&h.bridge, &TidalBridge::favoriteMixesChanged);

        h.bridge.addMixFavorite(kMixId, QJSValue());

        QCOMPARE(h.client.mixCalls, QStringList{QStringLiteral("add:") + kMixId});
        QVERIFY2(h.bridge.isMixFavorite(kMixId),
                 "the server accepted the save and the pill still reads Save");
        QCOMPARE(moved.count(), 1);
    }

    void aRefusedSaveMovesNothingAndSaysSo() {
        Harness h;
        h.client.addMixOk = false;
        QSignalSpy moved(&h.bridge, &TidalBridge::favoriteMixesChanged);

        const auto told = h.answerSlot();
        h.bridge.addMixFavorite(kMixId, told.fn);

        QVERIFY2(told.seen(), "the refused save never answered its callback");
        QVERIFY2(!told.ok(), "a refused save was reported to QML as a success");
        QVERIFY2(!h.bridge.isMixFavorite(kMixId),
                 "a refused save marked the mix as saved anyway");
        QCOMPARE(moved.count(), 0);
    }

    void anAcceptedRemovalTakesTheMixBackOut() {
        Harness h;
        h.bridge.addMixFavorite(kMixId, QJSValue());
        QVERIFY(h.bridge.isMixFavorite(kMixId));

        QSignalSpy gone(&h.bridge, &TidalBridge::favoriteRemoved);
        h.bridge.removeMixFavorite(kMixId, QJSValue());

        QVERIFY2(!h.bridge.isMixFavorite(kMixId),
                 "the server accepted the removal and the pill still reads Saved");
        QCOMPARE(h.client.mixCalls.last(), QStringLiteral("remove:") + kMixId);
        // The sidebar keeps its own copy of the library and hears nothing from
        // favoriteMixesChanged, so this is the signal that takes the row out of
        // it. Before the pill existed, a mix could only ever arrive there.
        QCOMPARE(gone.count(), 1);
        QCOMPARE(gone.first().at(0).toString(), QStringLiteral("mix"));
        QCOMPARE(gone.first().at(1).toString(), kMixId);
    }

    void aRefusedRemovalLeavesTheMixSaved() {
        Harness h;
        h.bridge.addMixFavorite(kMixId, QJSValue());
        h.client.removeMixOk = false;
        QSignalSpy gone(&h.bridge, &TidalBridge::favoriteRemoved);

        const auto told = h.answerSlot();
        h.bridge.removeMixFavorite(kMixId, told.fn);

        QVERIFY2(told.seen(), "the refused removal never answered its callback");
        QVERIFY2(!told.ok(), "a refused removal was reported to QML as a success");
        QVERIFY2(h.bridge.isMixFavorite(kMixId),
                 "a refused removal unsaved the mix anyway");
        QCOMPARE(gone.count(), 0);
    }

    // The sidebar's half. It holds a separate list from the bridge's set, so the
    // row has to be handed across - and the bridge is given an id and nothing
    // else, so it re-reads the mix to have a titled row to send.
    void anAcceptedSaveHandsTheRowToTheSidebar() {
        Harness h;
        Mix radio;
        radio.id       = kMixId;
        radio.title    = QStringLiteral("Weit hinter dem Horizont");
        radio.subTitle = QStringLiteral("Radio");
        radio.mixType  = QStringLiteral("TRACK_MIX");
        h.client.mixHeaders[kMixId] = radio;

        QList<Mix> handed;
        QObject::connect(&h.bridge, &TidalBridge::favoriteMixAdded,
                         &h.bridge, [&handed](const Mix &m) { handed << m; });
        h.bridge.addMixFavorite(kMixId, QJSValue());

        QCOMPARE(h.client.mixHeaderReads, 1);
        QCOMPARE(handed.size(), 1);
        QCOMPARE(handed.first().id, kMixId);
        QCOMPARE(handed.first().title, QStringLiteral("Weit hinter dem Horizont"));
        QCOMPARE(handed.first().mixType, QStringLiteral("TRACK_MIX"));
    }

    // A re-read that fails must not cost the save. The cache has already moved -
    // the server said yes - and the sidebar catches up at the next sign-in.
    void aFailedRereadStillLeavesTheMixSaved() {
        Harness h;                       // no entry in mixHeaders: 404
        int handed = 0;
        QObject::connect(&h.bridge, &TidalBridge::favoriteMixAdded,
                         &h.bridge, [&handed](const Mix &) { ++handed; });

        h.bridge.addMixFavorite(kMixId, QJSValue());

        QCOMPARE(h.client.mixHeaderReads, 1);
        QCOMPARE(handed, 0);
        QVERIFY2(h.bridge.isMixFavorite(kMixId),
                 "a failed re-read undid a save the server had accepted");
    }

    // A refused save must not cost a round trip either.
    void aRefusedSaveDoesNotRereadTheMix() {
        Harness h;
        h.client.addMixOk = false;
        h.bridge.addMixFavorite(kMixId, QJSValue());
        QCOMPARE(h.client.mixHeaderReads, 0);
    }

    // An empty id never reaches the network, and still answers its callback -
    // dropping it would leave the pill waiting forever.
    void anEmptyMixIdIsRefusedWithoutACall() {
        Harness h;
        const auto add = h.answerSlot();
        h.bridge.addMixFavorite(QString(), add.fn);
        QVERIFY2(add.seen(), "an empty id dropped its callback, so the pill would wait forever");
        QVERIFY(!add.ok());

        const auto remove = h.answerSlot();
        h.bridge.removeMixFavorite(QString(), remove.fn);
        QVERIFY(remove.seen());
        QVERIFY(!remove.ok());

        QVERIFY2(h.client.mixCalls.isEmpty(), "an empty mix id reached the client");
    }

    // ── the map QML reads a track out of ────────────────────────────────
    //
    // The link nothing else can see. TrackRow decides between the two viewers on
    // `trackData.trackMixId`, and `trackData` is the map TidalBridge::trackToMap
    // builds - but every QML test drives the stub bridge, which assembles its own
    // maps from fixtures. So a trackToMap that stopped carrying the field would
    // leave the whole of "Start radio opens the mix" green and dead: proved by
    // blanking it, which fails nothing in tests/qml.
    //
    // Read back through fetchMixPage, which is the one bridge call this file's
    // FakeClient can answer with tracks, and out of script, because the map only
    // exists as a QJSValue.
    void theTrackMapCarriesTheRadiosMixId() {
        Harness h;
        Mix header;
        header.id = kMixId;
        h.client.mixHeaders[kMixId] = header;

        Track t;
        t.id         = 900000001;
        t.title      = QStringLiteral("Weit hinter dem Horizont");
        t.trackMixId = kMixId;
        Track plain;
        plain.id    = 900000002;
        plain.title = QStringLiteral("Ohne Radio");
        h.client.mixPageTracks = {t, plain};

        QJSValue seen = h.engine.newObject();
        seen.setProperty(QStringLiteral("first"),  QStringLiteral("unset"));
        seen.setProperty(QStringLiteral("second"), QStringLiteral("unset"));
        const QJSValue cb = h.engine.evaluate(
            QStringLiteral("(function (s) { return function (mix, tracks, err) {"
                           " s.first  = String(tracks[0].trackMixId);"
                           " s.second = String(tracks[1].trackMixId); }; })"))
                                .call({seen});

        h.bridge.fetchMixPage(kMixId, cb);

        QCOMPARE(seen.property(QStringLiteral("first")).toString(), kMixId);
        // And a track whose payload said nothing hands QML an empty string, not
        // "undefined" or a 0 - that is the value TrackRow's fallback turns on.
        QCOMPARE(seen.property(QStringLiteral("second")).toString(), QString());
    }

    // ── which mix a track's radio is ────────────────────────────────────
    //
    // The lookup TrackRow falls back on when the row's own payload did not name
    // the mix - which is every row whose endpoint turns out not to carry
    // `mixes`, and that was deliberately not established. The two answers go
    // back in a fixed order, (mixId, error); swapped, every lookup would read
    // as a refusal with the mix id as its reason and the fix would silently
    // stop working.
    void theLookupAnswersTheMixIdThenTheError() {
        Harness h;
        Track t;
        t.id         = 900000001;
        t.trackMixId = kMixId;
        h.client.tracks[900000001] = t;

        QJSValue seen = h.engine.newObject();
        seen.setProperty(QStringLiteral("mix"), QStringLiteral("unset"));
        seen.setProperty(QStringLiteral("err"), QStringLiteral("unset"));
        const QJSValue cb = h.engine.evaluate(
            QStringLiteral("(function (s) { return function (mixId, err) {"
                           " s.mix = String(mixId); s.err = String(err); }; })"))
                                .call({seen});

        h.bridge.fetchTrackMix(900000001, cb);

        QCOMPARE(h.client.trackReads, 1);
        QCOMPARE(seen.property(QStringLiteral("mix")).toString(), kMixId);
        QCOMPARE(seen.property(QStringLiteral("err")).toString(), QString());
    }

    // A track Tidal serves and builds no station for: "" and no error. Both of
    // the caller's fallbacks hang off telling this apart from a failure.
    void aTrackWithNoRadioAnswersAnEmptyIdAndNoError() {
        Harness h;
        Track t;
        t.id = 900000002;                 // trackMixId left empty
        h.client.tracks[900000002] = t;

        QJSValue seen = h.engine.newObject();
        const QJSValue cb = h.engine.evaluate(
            QStringLiteral("(function (s) { return function (mixId, err) {"
                           " s.mix = String(mixId); s.err = String(err); }; })"))
                                .call({seen});
        h.bridge.fetchTrackMix(900000002, cb);

        QCOMPARE(seen.property(QStringLiteral("mix")).toString(), QString());
        QCOMPARE(seen.property(QStringLiteral("err")).toString(), QString());
    }

    void aFailedLookupAnswersItsReason() {
        Harness h;
        h.client.trackError = QStringLiteral("503");

        QJSValue seen = h.engine.newObject();
        const QJSValue cb = h.engine.evaluate(
            QStringLiteral("(function (s) { return function (mixId, err) {"
                           " s.mix = String(mixId); s.err = String(err); }; })"))
                                .call({seen});
        h.bridge.fetchTrackMix(900000003, cb);

        QCOMPARE(seen.property(QStringLiteral("mix")).toString(), QString());
        QCOMPARE(seen.property(QStringLiteral("err")).toString(), QStringLiteral("503"));
    }

    // A row with no usable track id must not reach the network, and must still
    // answer - a dropped callback would leave the menu press doing nothing at
    // all, which is the failure mode this whole fix is about.
    void anImpossibleTrackIdIsAnsweredWithoutACall() {
        Harness h;
        QJSValue seen = h.engine.newObject();
        seen.setProperty(QStringLiteral("seen"), false);
        const QJSValue cb = h.engine.evaluate(
            QStringLiteral("(function (s) { return function (mixId, err) {"
                           " s.seen = true; s.mix = String(mixId); }; })"))
                                .call({seen});
        h.bridge.fetchTrackMix(0, cb);

        QVERIFY(seen.property(QStringLiteral("seen")).toBool());
        QCOMPARE(seen.property(QStringLiteral("mix")).toString(), QString());
        QCOMPARE(h.client.trackReads, 0);
    }

private:
    static constexpr qint64 kDay      = 24LL * 60 * 60 * 1000;
    static constexpr qint64 kJan2026  = 1767225600000LL;   // 2026-01-01T00:00:00Z
    // The "original author created this years ago" date the header really does
    // carry for a followed playlist.
    static constexpr qint64 kAuthored2019 = 1546300800000LL; // 2019-01-01T00:00:00Z
    static qint64 daysAfterJan(int days) { return kJan2026 + days * kDay; }

    // A bridge whose cache can be filled, which needs a JS engine: the only way
    // a row enters m_favoritePlaylists without a Tidal session is createPlaylist,
    // and that one hands the row back through qjsEngine(this). The engine is not
    // otherwise used - every callback below is a default QJSValue, which
    // TidalBridge::call() skips as not callable.
    struct Harness {
        QJSEngine   engine;
        FakeClient  client;
        TidalBridge bridge{&client};
        QJSValue    keepAlive;

        Harness() {
            QJSEngine::setObjectOwnership(&bridge, QJSEngine::CppOwnership);
            keepAlive = engine.newQObject(&bridge);
        }

        // One playlist in the cache with the given count and length.
        void fillOne(int numTracks, int duration) {
            fill({ mkPlaylist(kUuid, QStringLiteral("Tape"), numTracks, duration,
                              numTracks > 0 ? QStringLiteral("img") : QString(),
                              kJan2026) });
        }

        // What QML was told, recorded in script.
        //
        // The callbacks these methods take are QJSValues, so the only place the
        // answer can be observed is inside the engine. `seen` is separate from
        // `ok` on purpose: "the callback was never called" and "the callback was
        // called with false" are different bugs, and a single bool could not tell
        // a dropped reply from a refusal.
        struct Answer {
            QJSValue fn;
            QJSValue holder;
            bool seen() const { return holder.property(QStringLiteral("seen")).toBool(); }
            bool ok()   const { return holder.property(QStringLiteral("ok")).toBool(); }
        };

        Answer answerSlot() {
            QJSValue holder = engine.newObject();
            holder.setProperty(QStringLiteral("seen"), false);
            // Starts true, so a callback that is never called cannot pass for a
            // refusal and a refusal cannot pass for "not called".
            holder.setProperty(QStringLiteral("ok"), true);
            const QJSValue fn = engine.evaluate(
                QStringLiteral("(function (h) { return function (ok) {"
                               " h.seen = true; h.ok = (ok === true); }; })"))
                                   .call({holder});
            return { fn, holder };
        }

        void fill(const QList<Playlist> &playlists) {
            for (const Playlist &p : playlists) {
                client.created = p;
                bridge.createPlaylist(p.title, QJSValue());
            }
            client.created = {};
        }

    };

    static QStringList uuidsOf(const QVariantList &rows) {
        QStringList out;
        for (const QVariant &v : rows)
            out << v.toMap().value(QStringLiteral("uuid")).toString();
        return out;
    }

    static const QString kUuid;
    // Invented, at a real mix id's shape: 30 lowercase hex characters.
    static const QString kMixId;

    QTemporaryDir m_dir;
};

const QString TestBridgeFavorites::kUuid  = QStringLiteral("pl-tape-1");
const QString TestBridgeFavorites::kMixId =
    QStringLiteral("0a1b2c3d4e5f60718293a4b5c6d7e8");

QTEST_GUILESS_MAIN(TestBridgeFavorites)
#include "tst_bridge_favorites.moc"
