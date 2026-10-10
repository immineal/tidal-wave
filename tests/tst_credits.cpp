// Parsing the three responses a set of song credits is assembled from. The
// screen half is tests/qml/tst_credits.qml.
// tracks/<id>/credits answers a bare JSON array at the top level. Read through
// a QJsonObject callback it would be an empty object with no error, which is
// why TidalApi::getArray exists. The fixtures are invented data.

#include <QTest>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

#include "api/Models.h"

using namespace Tidal;

class TestCredits : public QObject {
    Q_OBJECT

    static QJsonDocument doc(const char *s) {
        return QJsonDocument::fromJson(QByteArray(s));
    }

    // The shape tracks/<id>/credits really answers, trimmed to three groups.
    static const char *creditsBody() {
        return R"([
            { "type": "Producer",
              "contributors": [ { "name": "Pat Invented", "id": 11 },
                                { "name": "Jo Fictional", "id": 12 } ] },
            { "type": "Bass guitar",
              "contributors": [ { "name": "Sam Notreal", "id": 13 } ] },
            { "type": "Mastering Engineer",
              "contributors": [ { "name": "Kim Madeup" } ] }
        ])";
    }

private slots:
    // ── the array trap ───────────────────────────────────────────────────

    // Read as an object, the whole response is {} with no error. This case is
    // about the plumbing, the others about the fields.
    void creditsAreAnArrayNotAnObject() {
        const QJsonDocument d = doc(creditsBody());
        QVERIFY2(!d.isNull(), "the fixture is not valid JSON");
        QVERIFY2(d.isArray(), "tracks/<id>/credits answers an array at the top level");
        QCOMPARE(d.array().size(), 3);
        // An object read of an array document is empty and reports no error.
        QVERIFY2(d.object().isEmpty(),
                 "reading an array document as an object used to answer {} - if "
                 "that ever changes, getArray's reason for existing has gone");
    }

    // ── the contributor groups ───────────────────────────────────────────

    void groupsCarryTheirTypeAndTheirPeople() {
        const QJsonArray groups = doc(creditsBody()).array();

        const CreditGroup producer = TrackCredits::groupFromJson(groups[0].toObject());
        QCOMPARE(producer.type, QStringLiteral("Producer"));
        QCOMPARE(producer.contributors.size(), 2);
        QCOMPARE(producer.contributors[0].name, QStringLiteral("Pat Invented"));
        QCOMPARE(producer.contributors[0].id, 11LL);
        QCOMPARE(producer.contributors[1].name, QStringLiteral("Jo Fictional"));

        // The role is the label's own wording and is carried through exactly as
        // it arrived.
        const CreditGroup bass = TrackCredits::groupFromJson(groups[1].toObject());
        QCOMPARE(bass.type, QStringLiteral("Bass guitar"));
        QCOMPARE(bass.contributors.size(), 1);

        // A contributor with no id is still a credit: nothing navigates by the
        // id, so a missing one is 0.
        const CreditGroup mastering = TrackCredits::groupFromJson(groups[2].toObject());
        QCOMPARE(mastering.contributors.size(), 1);
        QCOMPARE(mastering.contributors[0].name, QStringLiteral("Kim Madeup"));
        QCOMPARE(mastering.contributors[0].id, 0LL);
    }

    // A nameless contributor gets no row.
    void anamelessContributorIsDropped() {
        const CreditGroup g = TrackCredits::groupFromJson(doc(R"({
            "type": "Engineer",
            "contributors": [ { "name": "Pat Invented", "id": 1 },
                              { "id": 2 },
                              { "name": "", "id": 3 } ]
        })").object());
        QCOMPARE(g.contributors.size(), 1);
        QCOMPARE(g.contributors[0].name, QStringLiteral("Pat Invented"));
    }

    void aGroupWithNoContributorsParsesEmpty() {
        const CreditGroup g = TrackCredits::groupFromJson(
            doc(R"({"type":"Producer"})").object());
        QCOMPARE(g.type, QStringLiteral("Producer"));
        QVERIFY(g.contributors.isEmpty());
    }

    // ── what counts as having nothing to show ────────────────────────────

    // A track with no contributor groups is not an empty panel: the release
    // date and the rights line come from the album and are shown on their own.
    void aTrackWithNoGroupsButADateIsNotEmpty() {
        TrackCredits c;
        QVERIFY2(c.isEmpty(), "nothing at all is empty");

        c.releaseDate = QStringLiteral("2017-09-22");
        QVERIFY2(!c.isEmpty(), "a release date on its own is still worth a panel");

        TrackCredits d;
        d.copyright = QStringLiteral("(P) 2017 An Invented Label Ltd.");
        QVERIFY2(!d.isEmpty(), "a rights line on its own is still worth a panel");

        TrackCredits e;
        e.isrc = QStringLiteral("ZZ0000000001");
        QVERIFY2(!e.isEmpty(), "an identifier on its own is still worth a panel");

        TrackCredits f;
        CreditGroup g; g.type = QStringLiteral("Producer");
        Artist a; a.name = QStringLiteral("Pat Invented");
        g.contributors.append(a);
        f.groups.append(g);
        QVERIFY(!f.isEmpty());
    }

    // ── the album's half ─────────────────────────────────────────────────

    // albums/<id> is the only response that carries the full release date, the
    // barcode and the album's rights line.
    void albumCarriesTheWholeDateTheRightsLineAndTheBarcode() {
        const Album a = Album::fromJson(doc(R"({
            "id": 12345, "title": "An Invented Record",
            "numberOfTracks": 11, "duration": 2400,
            "releaseDate": "2017-09-22",
            "copyright": "(P) 2017 An Invented Label Ltd.",
            "upc": "000000000001",
            "audioQuality": "LOSSLESS", "type": "ALBUM"
        })").object());

        QCOMPARE(a.releaseDate, QStringLiteral("2017-09-22"));
        QCOMPARE(a.copyright, QStringLiteral("(P) 2017 An Invented Label Ltd."));
        QCOMPARE(a.upc, QStringLiteral("000000000001"));
    }

    // The album nested inside a track response carries none of the three, so a
    // page that wants them fetches the album. vibrantColor is written without
    // '#': moc 6.12 takes one in a multi-line raw string for a directive.
    void theAlbumInsideATrackCarriesNoneOfThem() {
        const Track t = Track::fromJson(doc(R"({
            "id": 77, "title": "A Song", "duration": 215,
            "album": { "id": 12345, "title": "An Invented Record",
                       "cover": "aaaa-bbbb", "vibrantColor": "123456" }
        })").object());

        QCOMPARE(t.album.id, 12345LL);
        QVERIFY2(t.album.releaseDate.isEmpty(),
                 "the nested album has no release date to read");
        QVERIFY2(t.album.copyright.isEmpty(),
                 "the nested album has no rights line to read");
        QVERIFY2(t.album.upc.isEmpty(), "the nested album has no barcode to read");
    }

    // An absent field is an empty string: every line on the credits panel hides
    // itself on an empty string.
    void missingFieldsAreEmptyNotInvented() {
        const Album a = Album::fromJson(doc(R"({"id":1,"title":"x"})").object());
        QVERIFY(a.releaseDate.isEmpty());
        QVERIFY(a.copyright.isEmpty());
        QVERIFY(a.upc.isEmpty());
    }

    // ── the date that is not the release date ────────────────────────────

    // streamStartDate is on every track response and is when the catalogue got
    // the track, which can be decades after the release. Nothing may read it as
    // a release date.
    void streamStartDateIsNotTheReleaseDate() {
        const QJsonObject track = doc(R"({
            "id": 77, "title": "A Song",
            "streamStartDate": "2026-07-01T00:00:00.000+0000",
            "album": { "id": 1, "title": "A 1975 Record" }
        })").object();
        const QJsonObject album = doc(R"({
            "id": 1, "title": "A 1975 Record", "releaseDate": "1975-11-21"
        })").object();

        const QString streamStart = track["streamStartDate"].toString().left(10);
        const QString released    = Album::fromJson(album).releaseDate;
        QVERIFY2(streamStart != released,
                 "the fixture is meant to show these two disagreeing");
        QCOMPARE(released, QStringLiteral("1975-11-21"));
        // And Track::fromJson does not pick the wrong one up by accident.
        QVERIFY(Track::fromJson(track).album.releaseDate.isEmpty());
    }
};

QTEST_MAIN(TestCredits)
#include "tst_credits.moc"
