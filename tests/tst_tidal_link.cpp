// Tidal links as the desktop, a browser or a share sheet hands them over,
// reduced to the page they open. Ids here are made up.

#include <QTest>

#include "ui/TidalLink.h"

class TestTidalLink : public QObject {
    Q_OBJECT

private slots:
    void shapes_data() {
        QTest::addColumn<QString>("url");
        QTest::addColumn<QString>("kind");
        QTest::addColumn<QString>("id");

        const QString uuid = QStringLiteral("0b5d6c1e-1a2b-4c3d-8e9f-0123456789ab");
        const QString mix  = QStringLiteral("0a1b2c3d4e5f60718293a4b5c6d7e8");

        // The share links tidal.com hands out, old and new.
        QTest::newRow("browse track")     << "https://tidal.com/browse/track/1234" << "track" << "1234";
        QTest::newRow("browse track ?u")  << "https://tidal.com/browse/track/1234?u" << "track" << "1234";
        QTest::newRow("track /u")         << "https://tidal.com/track/1234/u" << "track" << "1234";
        QTest::newRow("track")            << "https://tidal.com/track/1234" << "track" << "1234";
        QTest::newRow("www")              << "https://www.tidal.com/browse/album/77" << "album" << "77";
        QTest::newRow("browse album")     << "https://tidal.com/browse/album/77" << "album" << "77";
        QTest::newRow("album")            << "https://tidal.com/album/77/u" << "album" << "77";
        QTest::newRow("browse artist")    << "https://tidal.com/browse/artist/9" << "artist" << "9";
        QTest::newRow("artist")           << "https://tidal.com/artist/9" << "artist" << "9";
        QTest::newRow("browse playlist")  << "https://tidal.com/browse/playlist/" + uuid << "playlist" << uuid;
        QTest::newRow("playlist /u")      << "https://tidal.com/playlist/" + uuid + "/u" << "playlist" << uuid;
        QTest::newRow("playlist upper")   << "https://tidal.com/playlist/" + uuid.toUpper() << "playlist" << uuid;
        QTest::newRow("browse mix")       << "https://tidal.com/browse/mix/" + mix << "mix" << mix;
        QTest::newRow("mix")              << "https://tidal.com/mix/" + mix << "mix" << mix;
        QTest::newRow("http")             << "http://tidal.com/browse/track/1234" << "track" << "1234";

        // The web player.
        QTest::newRow("listen track")     << "https://listen.tidal.com/track/1234" << "track" << "1234";
        QTest::newRow("listen album track") << "https://listen.tidal.com/album/77/track/1234" << "track" << "1234";
        QTest::newRow("listen album")     << "https://listen.tidal.com/album/77" << "album" << "77";
        QTest::newRow("listen artist")    << "https://listen.tidal.com/artist/9" << "artist" << "9";
        QTest::newRow("listen playlist")  << "https://listen.tidal.com/playlist/" + uuid << "playlist" << uuid;
        QTest::newRow("listen mix")       << "https://listen.tidal.com/mix/" + mix << "mix" << mix;

        // The app scheme.
        QTest::newRow("tidal track")      << "tidal://track/1234" << "track" << "1234";
        QTest::newRow("tidal album")      << "tidal://album/77" << "album" << "77";
        QTest::newRow("tidal artist")     << "tidal://artist/9" << "artist" << "9";
        QTest::newRow("tidal playlist")   << "tidal://playlist/" + uuid << "playlist" << uuid;
        QTest::newRow("tidal mix")        << "tidal://mix/" + mix << "mix" << mix;
        QTest::newRow("tidal browse")     << "tidal://browse/album/77" << "album" << "77";
        QTest::newRow("tidal upper")      << "TIDAL://Album/77" << "album" << "77";
        QTest::newRow("whitespace")       << "  tidal://track/1234\n" << "track" << "1234";
    }
    void shapes() {
        QFETCH(QString, url);
        QFETCH(QString, kind);
        QFETCH(QString, id);
        const TidalLink link = TidalLink::parse(url);
        QVERIFY2(link.isValid(), qPrintable(url));
        QCOMPARE(link.kind, kind);
        QCOMPARE(link.id, id);
    }

    void junk_data() {
        QTest::addColumn<QString>("url");
        QTest::newRow("empty")          << "";
        QTest::newRow("words")          << "not a link";
        QTest::newRow("other host")     << "https://example.com/browse/track/1234";
        QTest::newRow("look-alike")     << "https://tidal.com.example.com/track/1234";
        QTest::newRow("suffix host")    << "https://eviltidal.com/track/1234";
        QTest::newRow("user info")      << "https://tidal.com@example.com/track/1234";
        QTest::newRow("file")           << "file:///home/x/track/1234";
        QTest::newRow("ftp")            << "ftp://tidal.com/track/1234";
        QTest::newRow("home page")      << "https://tidal.com/";
        QTest::newRow("kind only")      << "https://tidal.com/browse/track";
        QTest::newRow("video")          << "https://tidal.com/browse/video/1234";
        QTest::newRow("unknown kind")   << "tidal://login/auth";
        QTest::newRow("letters id")     << "https://tidal.com/track/abc";
        QTest::newRow("negative id")    << "https://tidal.com/track/-5";
        QTest::newRow("zero id")        << "https://tidal.com/album/0";
        QTest::newRow("huge id")        << "https://tidal.com/album/123456789012345678901234";
        QTest::newRow("bad uuid")       << "https://tidal.com/playlist/1234";
        QTest::newRow("uuid as album")  << "https://tidal.com/album/0b5d6c1e-1a2b-4c3d-8e9f-0123456789ab";
        QTest::newRow("mix punctuation") << "https://tidal.com/mix/ab;cd";
        QTest::newRow("bad album track") << "https://listen.tidal.com/album/77/track/x";
    }
    void junk() {
        QFETCH(QString, url);
        QVERIFY2(!TidalLink::parse(url).isValid(), qPrintable(url));
    }
};

QTEST_GUILESS_MAIN(TestTidalLink)
#include "tst_tidal_link.moc"
