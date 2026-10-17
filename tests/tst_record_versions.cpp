// The rule of api/RecordVersions.h: which entries of an artist's lists are one
// record, which member stands for it, and where it sits. The request side is
// in tests/tst_artist_discography.cpp. Every id, title and number is invented.

#include <QTest>
#include <QList>
#include <QString>
#include <QStringList>

#include <algorithm>

#include "api/Models.h"
#include "api/RecordVersions.h"

using namespace Tidal;

namespace {

// A clean 16-bit stereo album of the artist's own, streamable.
Album product(qint64 id, const QString &title, int tracks, int duration) {
    Album a;
    a.id           = id;
    a.title        = title;
    a.type         = QStringLiteral("ALBUM");
    a.numTracks    = tracks;
    a.duration     = duration;
    a.audioQuality = QStringLiteral("LOSSLESS");
    a.audioModes   = {QStringLiteral("STEREO")};
    a.mediaTags    = {QStringLiteral("LOSSLESS")};
    return a;
}

Album hiRes(Album a) {
    a.mediaTags = {QStringLiteral("LOSSLESS"), QStringLiteral("HIRES_LOSSLESS")};
    return a;
}

// Dolby Atmos only: the listing calls it LOW and names no stereo mode.
Album atmos(Album a) {
    a.audioQuality = QStringLiteral("LOW");
    a.audioModes   = {QStringLiteral("DOLBY_ATMOS")};
    a.mediaTags    = {QStringLiteral("DOLBY_ATMOS")};
    return a;
}

Album explicitOne(Album a)       { a.explicit_ = true; return a; }
Album single(Album a)            { a.type = QStringLiteral("SINGLE"); return a; }
Album guest(Album a)             { a.featured = true; return a; }
Album popular(Album a, int p)    { a.popularity = p; return a; }
Album withVideos(Album a, int n) { a.numVideos = n; return a; }
Album unstreamable(Album a)      { a.allowStreaming = false; return a; }

QList<qint64> ids(const QList<Album> &albums) {
    QList<qint64> out;
    for (const Album &a : albums) out << a.id;
    return out;
}

// The groups as sorted id lists, themselves sorted: what belongs together,
// whatever order it came in.
QList<QList<qint64>> membership(const QList<QList<Album>> &groups) {
    QList<QList<qint64>> out;
    for (const QList<Album> &g : groups) {
        QList<qint64> one = ids(g);
        std::sort(one.begin(), one.end());
        out << one;
    }
    std::sort(out.begin(), out.end());
    return out;
}

QList<qint64> markedIds(const QList<Album> &albums) {
    QList<qint64> out;
    for (const Album &a : albums)
        if (a.titleShared) out << a.id;
    return out;
}

} // namespace

class TestRecordVersions : public QObject {
    Q_OBJECT

private slots:

    // ── what is one record ───────────────────────────────────────────────────

    // The pattern of a current release. The Dolby Atmos one leads the list and
    // is the most played, and still the explicit hi-res stereo one stands.
    void theSixProductsOfOneRecordAreOneEntry() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> six = {
            popular(atmos(explicitOne(product(900100001, t, 12, 2714))), 80),
            popular(product(900100002, t, 12, 2709), 40),
            popular(hiRes(product(900100003, t, 12, 2709)), 45),
            popular(explicitOne(product(900100004, t, 12, 2710)), 60),
            popular(hiRes(explicitOne(product(900100005, t, 12, 2710))), 70),
            popular(atmos(product(900100006, t, 12, 2713)), 30),
        };

        const QList<Album> out = oneEntryPerRecord(six);
        QVERIFY2(out.size() == 1,
                 qPrintable(QStringLiteral("six products of one record came out as %1 entries")
                            .arg(out.size())));
        QCOMPARE(out.at(0).id, qint64(900100005));
        QVERIFY(out.at(0).explicit_);
        QVERIFY(out.at(0).mediaTags.contains(QStringLiteral("HIRES_LOSSLESS")));
    }

    void explicitStandsBeforeClean() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> out = oneEntryPerRecord({
            popular(product(900101001, t, 12, 2709), 90),
            popular(explicitOne(product(900101002, t, 12, 2710)), 10),
        });
        QCOMPARE(ids(out), (QList<qint64>{900101002}));
    }

    // A version that cannot be played stands for nothing while one can.
    void onlyTheCleanOneStreamableIsChosen() {
        const QString t = QStringLiteral("Nachtfahrt");
        Album notReady = hiRes(explicitOne(product(900102003, t, 12, 2710)));
        notReady.streamReady = false;
        const QList<Album> out = oneEntryPerRecord({
            unstreamable(hiRes(explicitOne(product(900102001, t, 12, 2710)))),
            product(900102002, t, 12, 2709),
            notReady,
        });
        QCOMPARE(ids(out), (QList<qint64>{900102002}));
    }

    // Nothing is hidden behind a version that does not exist.
    void aDolbyAtmosOnlyRecordStaysAsItsOwnEntry() {
        const QList<Album> out = oneEntryPerRecord({
            product(900103001, QStringLiteral("Morgenrot"), 9, 2400),
            atmos(product(900103002, QStringLiteral("Nachtfahrt"), 12, 2713)),
        });
        QCOMPARE(ids(out), (QList<qint64>{900103001, 900103002}));
    }

    void stereoStandsBeforeDolbyAtmosOnly() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> out = oneEntryPerRecord({
            popular(atmos(product(900104001, t, 12, 2713)), 90),
            popular(product(900104002, t, 12, 2709), 10),
        });
        QCOMPARE(ids(out), (QList<qint64>{900104002}));
    }

    // A product that plays in both modes is a stereo product.
    void bothModesCountAsStereo() {
        const QString t = QStringLiteral("Nachtfahrt");
        Album both = product(900105001, t, 12, 2709);
        both.audioModes = {QStringLiteral("DOLBY_ATMOS"), QStringLiteral("STEREO")};
        const QList<Album> out = oneEntryPerRecord({
            popular(atmos(product(900105002, t, 12, 2713)), 90),
            popular(both, 10),
        });
        QCOMPARE(ids(out), (QList<qint64>{900105001}));
    }

    void hiResStandsBeforeLossless() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> out = oneEntryPerRecord({
            popular(product(900106001, t, 12, 2709), 90),
            popular(hiRes(product(900106002, t, 12, 2709)), 10),
        });
        QCOMPARE(ids(out), (QList<qint64>{900106002}));
    }

    void theMorePlayedOneBreaksATie() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> out = oneEntryPerRecord({
            popular(product(900107001, t, 12, 2709), 10),
            popular(product(900107002, t, 12, 2709), 90),
        });
        QCOMPARE(ids(out), (QList<qint64>{900107002}));
    }

    void theLowerIdBreaksTheLastTie() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> out = oneEntryPerRecord({
            product(900108002, t, 12, 2709),
            product(900108001, t, 12, 2709),
        });
        QCOMPARE(ids(out), (QList<qint64>{900108001}));
    }

    // A hi-res product can run 40 seconds longer than the 16-bit one over the
    // same six tracks.
    void lengthsWithinFivePercentAreOneRecord() {
        const QString t = QStringLiteral("Winterlieder");
        const QList<Album> out = oneEntryPerRecord({
            product(900109001, t, 6, 1147),
            hiRes(product(900109002, t, 6, 1187)),
        });
        QCOMPARE(ids(out), (QList<qint64>{900109002}));
    }

    // ── what is not ──────────────────────────────────────────────────────────

    // One title, three track counts: three records. The lengths are near
    // enough that only the count tells them apart.
    void anotherTrackCountStaysApart() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> out = oneEntryPerRecord({
            product(900110001, t, 12, 2709),
            product(900110002, t, 13, 2740),
            product(900110003, t, 14, 2765),
            hiRes(product(900110004, t, 13, 2740)),
        });
        QCOMPARE(ids(out), (QList<qint64>{900110001, 900110004, 900110003}));
    }

    // Same count, same length, another title: the title is the record's name.
    void aDeluxeTitleStaysApart() {
        const QList<Album> out = oneEntryPerRecord({
            product(900111001, QStringLiteral("Nachtfahrt"), 12, 2709),
            product(900111002, QStringLiteral("Nachtfahrt (Deluxe)"), 12, 2709),
        });
        QCOMPARE(ids(out), (QList<qint64>{900111001, 900111002}));
    }

    // Two singles of one title, two tracks each, minutes apart: two records.
    // Each still gathers its own products.
    void twoSinglesOfOneTitleWithFarDurationsStayApart() {
        const QString t = QStringLiteral("Zwei Lieder");
        const QList<Album> out = oneEntryPerRecord({
            single(product(900112001, t, 2, 702)),
            single(product(900112002, t, 2, 431)),
            single(hiRes(product(900112003, t, 2, 704))),
            single(hiRes(product(900112004, t, 2, 430))),
        });
        QCOMPARE(ids(out), (QList<qint64>{900112003, 900112004}));
    }

    // Two remixes under one title, 19 seconds apart on a four-minute track.
    void twoRemixesOfOneTitleStayApart() {
        const QString t = QStringLiteral("Nachtfahrt (Remix)");
        const QList<Album> out = oneEntryPerRecord({
            single(product(900113001, t, 1, 244)),
            single(product(900113002, t, 1, 263)),
        });
        QCOMPARE(out.size(), 2);
    }

    // Seven per cent apart over one title and track count: two records.
    void lengthsSevenPercentApartStayApart() {
        const QString t = QStringLiteral("Winterlieder");
        const QList<Album> out = oneEntryPerRecord({
            product(900126001, t, 6, 1100),
            hiRes(product(900126002, t, 6, 1183)),
        });
        QCOMPARE(ids(out), (QList<qint64>{900126001, 900126002}));
    }

    // The album's duration counts its videos, so a product that carries them
    // runs minutes longer over the same tracks.
    void videosDoNotSplitARecord() {
        const QString t = QStringLiteral("Nachtfahrt (Deluxe)");
        const QList<Album> out = oneEntryPerRecord({
            withVideos(product(900114001, t, 18, 7105), 5),
            hiRes(product(900114002, t, 18, 4930)),
        });
        QCOMPARE(ids(out), (QList<qint64>{900114002}));
    }

    // Durations compare between products with the same number of videos.
    void durationsCompareAmongEqualVideoCounts() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> out = oneEntryPerRecord({
            withVideos(product(900115001, t, 18, 7105), 5),
            withVideos(product(900115002, t, 18, 5300), 5),
        });
        QCOMPARE(out.size(), 2);
    }

    // A lead single often carries its album's title.
    void aSingleWithItsAlbumsTitleStaysInItsSection() {
        const QString t = QStringLiteral("Nachtfahrt");
        Album oneTrackAlbum = product(900116003, t, 1, 240);
        const QList<Album> out = oneEntryPerRecord({
            product(900116001, t, 12, 2709),
            single(product(900116002, t, 1, 240)),
            // Same count and length as the single, filed as an album.
            oneTrackAlbum,
        });
        QCOMPARE(ids(out), (QList<qint64>{900116001, 900116002, 900116003}));
    }

    void anAppearsOnEntryDoesNotMergeWithAnOwnRelease() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> out = oneEntryPerRecord({
            product(900117001, t, 12, 2709),
            guest(hiRes(explicitOne(product(900117002, t, 12, 2709)))),
        });
        QCOMPARE(ids(out), (QList<qint64>{900117001, 900117002}));
        QVERIFY(!out.at(0).featured);
        QVERIFY(out.at(1).featured);
    }

    // The products of a record somebody else made are one entry too.
    void appearsOnEntriesGatherAmongThemselves() {
        const QString t = QStringLiteral("Sammlung");
        const QList<Album> out = oneEntryPerRecord({
            guest(product(900118001, t, 20, 4800)),
            guest(explicitOne(product(900118002, t, 20, 4801))),
        });
        QCOMPARE(ids(out), (QList<qint64>{900118002}));
        QVERIFY(out.at(0).featured);
    }

    // A response that names no title names no record.
    void anEntryWithoutATitleIsNeverMerged() {
        const QList<Album> out = oneEntryPerRecord({
            product(900119001, QString(), 12, 2709),
            product(900119002, QString(), 12, 2709),
            product(900119003, QStringLiteral("   "), 12, 2709),
        });
        QCOMPARE(out.size(), 3);
    }

    // ── titles ───────────────────────────────────────────────────────────────

    void titlesThatDifferInCaseOnlyAreOne() {
        const QList<Album> out = oneEntryPerRecord({
            product(900120001, QStringLiteral("NACHTFAHRT über Land"), 12, 2709),
            hiRes(product(900120002, QStringLiteral("Nachtfahrt Über land"), 12, 2709)),
        });
        QCOMPARE(ids(out), (QList<qint64>{900120002}));
    }

    void titlesThatDifferInSpacingOnlyAreOne() {
        const QList<Album> out = oneEntryPerRecord({
            product(900120101, QStringLiteral("Nachtfahrt  über Land "), 12, 2709),
            hiRes(product(900120102, QStringLiteral("Nachtfahrt über Land"), 12, 2709)),
        });
        QCOMPARE(ids(out), (QList<qint64>{900120102}));
    }

    // ── where the entry sits ─────────────────────────────────────────────────

    // Each record takes the place of its first member, so the order the
    // server sent stays.
    void theOrderOfTheFirstMembersIsKept() {
        const QList<Album> out = oneEntryPerRecord({
            atmos(product(900121001, QStringLiteral("Drittes"), 12, 2713)),
            product(900121002, QStringLiteral("Zweites"), 10, 2000),
            product(900121003, QStringLiteral("Erstes"), 8, 1700),
            hiRes(explicitOne(product(900121004, QStringLiteral("Drittes"), 12, 2709))),
            hiRes(product(900121005, QStringLiteral("Erstes"), 8, 1700)),
        });
        QCOMPARE(ids(out), (QList<qint64>{900121004, 900121002, 900121005}));
    }

    // ── the groups themselves ────────────────────────────────────────────────

    // Best first, and nothing is lost: every entry is in exactly one group.
    void aGroupHoldsItsMembersBestFirst() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<QList<Album>> groups = recordVersions({
            atmos(product(900122001, t, 12, 2713)),
            product(900122002, t, 12, 2709),
            hiRes(explicitOne(product(900122003, t, 12, 2710))),
            product(900122004, QStringLiteral("Morgenrot"), 9, 2400),
            explicitOne(product(900122005, t, 12, 2710)),
        });
        QCOMPARE(groups.size(), 2);
        QCOMPARE(ids(groups.at(0)),
                 (QList<qint64>{900122003, 900122005, 900122002, 900122001}));
        QCOMPARE(ids(groups.at(1)), (QList<qint64>{900122004}));
    }

    // ── "within 5 %" is not transitive ───────────────────────────────────────

    // 1000, 1040 and 1080 seconds: each neighbour is near, the ends are far.
    // The best member is the measure, so the answer does not hang on the order
    // the entries came in.
    void aChainOfNearDurationsIsCutAtTheBestMember() {
        const QString t = QStringLiteral("Nachtfahrt");
        const Album best = hiRes(explicitOne(product(900123001, t, 12, 1000)));
        const Album mid  = product(900123002, t, 12, 1040);
        const Album far  = product(900123003, t, 12, 1080);
        const QList<QList<qint64>> want = {{900123001, 900123002}, {900123003}};

        const QList<QList<Album>> orders = {
            {best, mid, far}, {best, far, mid}, {mid, best, far},
            {mid, far, best}, {far, best, mid}, {far, mid, best},
        };
        for (const QList<Album> &order : orders) {
            const QList<QList<Album>> groups = recordVersions(order);
            QVERIFY2(membership(groups) == want,
                     qPrintable(QStringLiteral("the order %1, %2, %3 grouped otherwise")
                                .arg(order.at(0).id).arg(order.at(1).id).arg(order.at(2).id)));
            // The place is that of the first member all the same.
            QVERIFY(ids(groups.at(0)).contains(order.at(0).id));
        }
    }

    // With the middle one best, both ends are within reach of it.
    void aChainHeldByItsMiddleIsOneRecord() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> out = oneEntryPerRecord({
            product(900124001, t, 12, 1000),
            hiRes(explicitOne(product(900124002, t, 12, 1040))),
            product(900124003, t, 12, 1080),
        });
        QCOMPARE(ids(out), (QList<qint64>{900124002}));
    }

    // A product with videos has no like to be measured against. It goes to
    // the title's best record, whatever the order.
    void aProductWithVideosAloneGoesToTheBestRecord() {
        const QString t = QStringLiteral("Zwei Lieder");
        const Album longOne  = single(hiRes(product(900125001, t, 2, 702)));
        const Album shortOne = single(product(900125002, t, 2, 431));
        const Album videos   = single(withVideos(product(900125003, t, 2, 900), 1));
        const QList<QList<qint64>> want = {{900125001, 900125003}, {900125002}};

        QVERIFY(membership(recordVersions({longOne, shortOne, videos})) == want);
        QVERIFY(membership(recordVersions({videos, shortOne, longOne})) == want);
    }

    // ── a title that several entries of a row share ──────────────────────────

    // One stereo record and two Dolby Atmos only ones that differ in their
    // track lists: three entries of one title, each marked.
    void entriesOfOneTitleInOneRowAreMarked() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> out = oneEntryPerRecord({
            product(900110001, t, 14, 3400),
            atmos(product(900110002, t, 13, 3150)),
            product(900110003, QStringLiteral("Morgenrot"), 9, 2400),
            atmos(product(900110004, t, 12, 2900)),
        });
        QCOMPARE(ids(out), (QList<qint64>{900110001, 900110002, 900110003, 900110004}));
        QCOMPARE(markedIds(out), (QList<qint64>{900110001, 900110002, 900110004}));
    }

    // The rows are apart on the page, so a title in each of them is no clash.
    void oneTitleInThreeRowsMarksNone() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> out = oneEntryPerRecord({
            product(900111001, t, 12, 2710),
            single(product(900111002, t, 1, 215)),
            guest(product(900111003, t, 12, 2710)),
        });
        QCOMPARE(out.size(), 3);
        QCOMPARE(markedIds(out), QList<qint64>());
    }

    void caseAndSpacingDoNotMakeATitleOfItsOwn() {
        const QList<Album> out = oneEntryPerRecord({
            product(900112001, QStringLiteral("Die Nachtfahrt"), 12, 2710),
            product(900112002, QStringLiteral(" die  NACHTFAHRT "), 15, 3300),
        });
        QCOMPARE(markedIds(out), (QList<qint64>{900112001, 900112002}));
    }

    void aRecordAloneIsNotMarked() {
        const QList<Album> out = oneEntryPerRecord({
            product(900113001, QStringLiteral("Nachtfahrt"), 12, 2710),
            product(900113002, QStringLiteral("Morgenrot"), 12, 2710),
        });
        QCOMPARE(out.size(), 2);
        QCOMPARE(markedIds(out), QList<qint64>());
    }

    // The products folded into one entry are not on the page, so they share
    // nothing with it. Beside a second record they count once.
    void productsFoldedIntoOneEntryMarkNothing() {
        const QString t = QStringLiteral("Nachtfahrt");
        const QList<Album> folded = oneEntryPerRecord({
            product(900114001, t, 12, 2709),
            hiRes(explicitOne(product(900114002, t, 12, 2710))),
            atmos(explicitOne(product(900114003, t, 12, 2714))),
        });
        QCOMPARE(ids(folded), (QList<qint64>{900114002}));
        QCOMPARE(markedIds(folded), QList<qint64>());

        const QList<Album> beside = oneEntryPerRecord({
            product(900114001, t, 12, 2709),
            hiRes(explicitOne(product(900114002, t, 12, 2710))),
            atmos(explicitOne(product(900114003, t, 12, 2714))),
            product(900114004, t, 17, 3900),
        });
        QCOMPARE(ids(beside), (QList<qint64>{900114002, 900114004}));
        QCOMPARE(markedIds(beside), (QList<qint64>{900114002, 900114004}));
    }

    // An entry without a title is a candidate for no record, and for no
    // shared title either.
    void entriesWithoutATitleAreNotMarked() {
        const QList<Album> out = oneEntryPerRecord({
            product(900115001, QString(), 12, 2710),
            product(900115002, QStringLiteral("  "), 12, 2710),
        });
        QCOMPARE(out.size(), 2);
        QCOMPARE(markedIds(out), QList<qint64>());
    }

    // ── the three rows ───────────────────────────────────────────────────────

    void theRowOfARelease_data() {
        QTest::addColumn<QString>("type");
        QTest::addColumn<int>("tracks");
        QTest::addColumn<bool>("featured");
        QTest::addColumn<QString>("key");

        QTest::newRow("an album")              << "ALBUM"       << 11 << false << "a";
        QTest::newRow("a single")              << "SINGLE"      << 1  << false << "s";
        QTest::newRow("a four-track EP")       << "EP"          << 4  << false << "s";
        QTest::newRow("a long EP")             << "EP"          << 9  << false << "s";
        QTest::newRow("a one-track album")     << "ALBUM"       << 1  << false << "a";
        QTest::newRow("an own compilation")    << "COMPILATION" << 0  << false << "a";
        QTest::newRow("no type, nine tracks")  << ""            << 9  << false << "a";
        QTest::newRow("no type, four tracks")  << ""            << 4  << false << "a";
        QTest::newRow("no type, three tracks") << ""            << 3  << false << "s";
        QTest::newRow("no type, no count")     << ""            << 0  << false << "s";
        QTest::newRow("a guest album")         << "ALBUM"       << 12 << true  << "f";
        QTest::newRow("a guest single")        << "SINGLE"      << 1  << true  << "f";
        QTest::newRow("a guest compilation")   << "COMPILATION" << 20 << true  << "f";
    }

    void theRowOfARelease() {
        QFETCH(QString, type);
        QFETCH(int, tracks);
        QFETCH(bool, featured);
        QFETCH(QString, key);

        Album a;
        a.type      = type;
        a.numTracks = tracks;
        a.featured  = featured;
        QCOMPARE(recordSectionKey(a), key);
    }

    // The enum and the letter are one answer.
    void theLetterNamesTheRow() {
        Album a;
        a.type = QStringLiteral("ALBUM");
        QCOMPARE(recordSection(a), RecordSection::Albums);
        a.type = QStringLiteral("EP");
        QCOMPARE(recordSection(a), RecordSection::SinglesAndEps);
        a.featured = true;
        QCOMPARE(recordSection(a), RecordSection::AppearsOn);
    }
};

QTEST_GUILESS_MAIN(TestRecordVersions)
#include "tst_record_versions.moc"
