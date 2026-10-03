// Parsing the three responses a set of song credits is assembled from.
//
// The user: "currently there is no way to see song credits or exact copyright
// information or the actual date that something came out." The screen half of
// that is tests/qml/tst_credits.qml; this is the half that reads the JSON, and
// the reason it is worth its own file is that one of the three responses is not
// shaped like anything else in the API.
//
// tracks/<id>/credits answers a bare JSON ARRAY at the top level. Every other
// GET in TidalApi goes through a QJsonObject callback, and QJsonDocument::object()
// on an array document answers an empty object with no error to show for it - so
// the credits would have come back empty, silently, for every track. That is what
// TidalApi::getArray exists for, and the first case below is the trap itself.
//
// None of the fixtures here is real data: the names are invented and the codes
// are not issued ones.

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

    // Why TidalApi::getArray had to be added rather than reusing get(). Read as
    // an object, the whole response is {} - no error, no groups, nothing to
    // debug. This is the one case here that is about the plumbing and not about
    // the fields.
    void creditsAreAnArrayNotAnObject() {
        const QJsonDocument d = doc(creditsBody());
        QVERIFY2(!d.isNull(), "the fixture is not valid JSON");
        QVERIFY2(d.isArray(), "tracks/<id>/credits answers an array at the top level");
        QCOMPARE(d.array().size(), 3);
        // The trap: an object read of an array document is empty and says so to
        // nobody.
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

        // The role is the label's own word for it, with a space and lower case
        // and all: it is data on the recording, not a token to be matched
        // against, so it is carried through exactly as it arrived.
        const CreditGroup bass = TrackCredits::groupFromJson(groups[1].toObject());
        QCOMPARE(bass.type, QStringLiteral("Bass guitar"));
        QCOMPARE(bass.contributors.size(), 1);

        // A contributor with no id is still a credit. The id is not always an
        // artist id and nothing navigates by it, so a missing one is a 0 and not
        // a dropped name.
        const CreditGroup mastering = TrackCredits::groupFromJson(groups[2].toObject());
        QCOMPARE(mastering.contributors.size(), 1);
        QCOMPARE(mastering.contributors[0].name, QStringLiteral("Kim Madeup"));
        QCOMPARE(mastering.contributors[0].id, 0LL);
    }

    // A nameless contributor is nothing to put on a panel, so it does not get a
    // row: the group would otherwise render a trailing comma and a gap.
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

    // A track with no contributor groups is not an empty panel: the release date
    // and the rights line are what the user asked for as much as the names are,
    // and they come from the album rather than from the credits call. Treating
    // "no groups" as "nothing" would have hidden both.
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

    // albums/<id> is the only response that carries the release date in full,
    // the barcode, and the album's rights line. None of the three were read
    // before, which is why the album page could only print four digits.
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

    // The album object nested inside a track response carries none of the three -
    // checked against a live response, where it holds only id, title, cover,
    // vibrantColor and videoCover. So the fields parse as empty rather than as
    // anything made up, and a page that wants them has to fetch the album, which
    // is what TidalClient::fetchTrackCredits chains a third request for.
    //
    // vibrantColor really arrives as "#rrggbb" and is written without its hash
    // here on purpose. Inside a multi-line raw string, moc 6.12 reads a '#' as
    // the start of a preprocessor directive, gives up on the rest of the file and
    // reports "No relevant classes found" - which lands as an empty .moc and a
    // link failure on the vtable, with nothing in the output naming the colour.
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

    // An absent field is an empty string and not a placeholder: every line on the
    // credits panel hides itself on an empty string, so a guess here would put a
    // row on screen with nothing in it.
    void missingFieldsAreEmptyNotInvented() {
        const Album a = Album::fromJson(doc(R"({"id":1,"title":"x"})").object());
        QVERIFY(a.releaseDate.isEmpty());
        QVERIFY(a.copyright.isEmpty());
        QVERIFY(a.upc.isEmpty());
    }

    // ── the date that is not the release date ────────────────────────────

    // streamStartDate is on every track response and looks like the answer. It is
    // not: probed live against a 1975 album it answered 2026-07-01, because it is
    // when this account's catalogue got the track. Nothing in the app may read it
    // as a release date, and this is the note that says why.
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
