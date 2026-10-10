// TidalBridge's own in-memory caches: the lists the interface reads instead of
// the server. These cases drive a real TidalBridge. The seam is the virtuals
// on TidalClient that FakeClient below answers from lists this file owns, so
// nothing here touches the network or needs a Tidal session.
// Not covered: the album, artist and track favourites, whose client calls are
// not virtual and so cannot be answered.

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

// Every fixture is invented. `addedAt` is passed explicitly: 0, no date on the
// response, is the value that would hide a bug that overwrote it.
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

    // Readable from JS, so a callback handed to the bridge can record how many
    // header reads the client had seen when it was answered.
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
    // One per accepted mutation and none per refused one.
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
    // Three more virtuals, answered from here. The real ones are a v2 PUT and
    // a `pages/mix` GET.

    bool addMixOk    = true;
    bool removeMixOk = true;
    QStringList mixCalls;          // "add:<id>" / "remove:<id>", in order
    // What `pages/mix` answers for the row the bridge re-reads on an accepted
    // save, per id. An id with no entry answers an error.
    QHash<QString, Mix> mixHeaders;
    int  mixHeaderReads = 0;
    // The whole saved list, for the sign-in load. Not reached in this file, and
    // overridden so that no case can reach the network through it.
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
        // Never the real configuration: the bridge's constructor reads
        // audio/preferredQuality, and sortPlaylists() reads stored play times.
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_bridge_favorites"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
    }

    // ── a playlist's cached count ───────────────────────────────────────────
    // Create, then add, then read the list the picker reads. getUserPlaylists()
    // is what TrackRow's picker fills its rows from, and numTracks is the field
    // it draws.
    void addingTracksMovesTheCountThePickerReads() {
        Harness h;
        h.client.created = mkPlaylist(kUuid, QStringLiteral("Tape"), 0, 0, QString(), kJan2026);
        h.bridge.createPlaylist(QStringLiteral("Tape"), QJSValue());
        QCOMPARE(h.client.createCalls, 1);
        QCOMPARE(rowFor(h.bridge.getUserPlaylists(), kUuid)
                     .value(QStringLiteral("numTracks")).toInt(), 0);

        // Two songs on, and the server's header now says so. The duration has to
        // differ from 0 for that half of the assertion to mean anything.
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

    // One accepted mutation costs one header read. A version that read the
    // header on every picker open, or twice per add, would fail here.
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
        // overwrite the row.
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

    // The mirror of the add: taking a song off moves the cached count down.
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
    // `playlists/<uuid>` has no favourites wrapper, so the header's date is the
    // author's `created`, which can be years old. Copying it into `addedAt`
    // would sink the row. The playlist added to sits in the middle of three.
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

    // A header the server confirmed unchanged raises no redraw: several readers
    // rebuild a grid or a row off this signal.
    void aHeaderThatSaysNothingNewRaisesNoRedraw() {
        Harness h;
        h.fillOne(2, 418);
        h.client.headers[kUuid] = mkPlaylist(kUuid, QStringLiteral("Tape"), 2, 418,
                                             QStringLiteral("img"), kJan2026);

        QSignalSpy changed(&h.bridge, &TidalBridge::favoritePlaylistsChanged);
        QSignalSpy stats(&h.bridge, &TidalBridge::playlistStatsChanged);
        h.bridge.addTracksToPlaylist(kUuid, 101, QJSValue());

        QCOMPARE(changed.count(), 0);
        // The hand-across to the sidebar's separate list goes out regardless:
        // that list may be behind this one.
        QCOMPARE(stats.count(), 1);
    }

    // A re-read that failed must not write the parse of an error body into the
    // row. The uuid check is the guard that earns this: an error reply arrives
    // as a default-constructed Playlist with an empty uuid.
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

    // A reply about a different playlist, as a mismatched response would parse.
    // The row asked about must not take the other playlist's numbers.
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

    // The caller hears the server's answer before the header request goes out.
    // Observed from inside a JS callback, the only place the order is visible.
    void theCallerIsAnsweredBeforeTheHeaderIsAskedFor() {
        Harness h;
        h.fillOne(0, 0);
        h.client.headers[kUuid] = mkPlaylist(kUuid, QStringLiteral("Tape"), 1, 200,
                                             QStringLiteral("img"), kJan2026);

        QJSEngine::setObjectOwnership(&h.client, QJSEngine::CppOwnership);
        h.engine.globalObject().setProperty(QStringLiteral("fakeClient"),
                                            h.engine.newQObject(&h.client));
        // A plain object held on the global. Qt's engine does not define
        // `globalThis`, so assigning through it would throw inside the callback.
        QJSValue probe = h.engine.newObject();
        h.engine.globalObject().setProperty(QStringLiteral("probe"), probe);
        QJSValue cb = h.engine.evaluate(
            QStringLiteral("(function (ok) {"
                           "  probe.ok    = ok;"
                           "  probe.reads = fakeClient.headerReadsSoFar();"
                           "})"));
        QVERIFY(cb.isCallable());

        h.bridge.addTracksToPlaylist(kUuid, 101, cb);

        // The probe really ran, so the assertions under it are about the bridge.
        QVERIFY(probe.property(QStringLiteral("ok")).isBool());
        QCOMPARE(probe.property(QStringLiteral("ok")).toBool(), true);
        // Nothing had been asked for yet when the picker was told it worked.
        QCOMPARE(probe.property(QStringLiteral("reads")).toInt(), 0);
        // And the repair did then happen.
        QCOMPARE(h.client.headerReads, 1);
    }

    // The count is not written on the strength of the post alone: the post
    // sends onDuplicateFound=SKIP, so an accepted add may have added nothing.
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
    // mergePlaylistMeta is the one function both caches run, so its field list
    // and exclusions are pinned here.
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

    // Emptying a playlist takes it back to no tracks, no length and no mosaic,
    // so those three are written even when the new value is the empty one.
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

    // The title is the exception: Tidal will not hold a nameless playlist, so
    // "" is a reply that did not parse, and the label is kept.
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
    // The pill reads its state back out of isMixFavorite(), so the cache has to
    // move on an accepted save and stay put on a refused one. Every id is
    // invented, at the shape of a real one: 30 lowercase hex characters.

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
        // favoriteMixesChanged, so this signal is what takes the row out of it.
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

    // The sidebar's half. It holds a separate list, so the row is handed across.
    // The bridge is given only an id, so it re-reads the mix to have a titled
    // row to send.
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

    // A re-read that fails must not cost the save: the server said yes, and the
    // sidebar catches up at the next sign-in.
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

    // An empty id never reaches the network and still answers its callback, or
    // the pill would wait forever.
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
    // TrackRow chooses its viewer on `trackData.trackMixId`, a field of the map
    // TidalBridge::trackToMap builds. The QML tests drive the stub bridge, so
    // this is the only test of the real map. Read back through fetchMixPage.
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
        // A track whose payload said nothing hands QML an empty string, the
        // value TrackRow's fallback turns on.
        QCOMPARE(seen.property(QStringLiteral("second")).toString(), QString());
    }

    // ── which mix a track's radio is ────────────────────────────────────
    // The lookup TrackRow falls back on when the row's payload did not name the
    // mix. The two answers go back in a fixed order, (mixId, error).
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

    // A track Tidal serves and builds no station for: "" and no error, which
    // the caller must tell apart from a failure.
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
    // answer its callback.
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
    // An author's creation date, as the header carries for a followed playlist.
    static constexpr qint64 kAuthored2019 = 1546300800000LL; // 2019-01-01T00:00:00Z
    static qint64 daysAfterJan(int days) { return kJan2026 + days * kDay; }

    // A bridge whose cache can be filled. That needs a JS engine: without a
    // Tidal session a row only enters m_favoritePlaylists through
    // createPlaylist, which hands it back through qjsEngine(this).
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

        // What QML was told, recorded in script, the only place a QJSValue
        // callback can be observed. `seen` is separate from `ok`: a dropped
        // reply and a refusal are different bugs.
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
