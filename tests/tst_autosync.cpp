// AutoSync: plain lyrics timed on the worker thread against a track's audio
// file, the analysis kept and the result cached, holds around the file.
// The audio is a synthetic WAV written here.

#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QtEndian>
#include <cmath>

#include "lyricsync/Aligner.h"
#include "lyricsync/AutoSync.h"

using namespace lyricsync;

namespace {

// 16-bit stereo PCM at 44.1 kHz: harmonic bursts with gaps.
bool writeWav(const QString &path, double seconds) {
    const int n = int(seconds * 44100);
    QByteArray pcm(n * 4, '\0');
    auto *p = reinterpret_cast<qint16 *>(pcm.data());
    for (int i = 0; i < n; ++i) {
        const double t = i / 44100.0, q = t / 0.5;
        const long long k = (long long)std::floor(q);
        const double f0 = 180.0 + 40.0 * double(k % 5);
        const double env = (k % 4) != 3 ? 0.3 * std::sin(3.14159265358979 * (q - std::floor(q))) : 0.0;
        double s = 0;
        for (int h = 1; h <= 6; ++h) s += std::sin(2 * 3.14159265358979 * h * f0 * t) / h;
        const qint16 v = qint16(std::lround(s * env * 20000));
        p[2 * i] = qToLittleEndian(v);
        p[2 * i + 1] = qToLittleEndian(v);
    }
    QByteArray h;
    auto u32 = [&h](quint32 v) { v = qToLittleEndian(v); h.append(reinterpret_cast<const char *>(&v), 4); };
    auto u16 = [&h](quint16 v) { v = qToLittleEndian(v); h.append(reinterpret_cast<const char *>(&v), 2); };
    h += "RIFF"; u32(quint32(36 + pcm.size())); h += "WAVEfmt ";
    u32(16); u16(1); u16(2); u32(44100); u32(44100 * 4); u16(4); u16(16);
    h += "data"; u32(quint32(pcm.size()));
    QFile f(path);
    return f.open(QIODevice::WriteOnly) && f.write(h + pcm) == h.size() + pcm.size();
}

const QString kText = QStringLiteral("La la la\nOh na na na\nHey hey yeah\n");

} // namespace

class TestAutoSync : public QObject {
    Q_OBJECT

    QTemporaryDir m_dir;
    QString m_wav, m_long, m_junk;
    QHash<qint64, QString> m_paths;
    QStringList m_held, m_released;

    AutoSync *make(QObject *parent) {
        auto *a = new AutoSync(parent);
        a->setCacheDir(m_dir.path() + QStringLiteral("/cache"));
        a->setAudioSource([this](qint64 id) { return m_paths.value(id); });
        a->setFileHold([this](const QString &p) { m_held << p; }, [this](const QString &p) { m_released << p; });
        return a;
    }

private slots:
    void initTestCase() {
        QVERIFY(m_dir.isValid());
        m_wav = m_dir.filePath(QStringLiteral("song.wav"));
        m_long = m_dir.filePath(QStringLiteral("long.wav"));
        m_junk = m_dir.filePath(QStringLiteral("junk.wav"));
        QVERIFY(writeWav(m_wav, 16));
        QVERIFY(writeWav(m_long, 240));
        QFile j(m_junk);
        QVERIFY(j.open(QIODevice::WriteOnly));
        j.write(QByteArray(8192, 'x'));
    }

    void init() {
        m_paths.clear();
        m_held.clear();
        m_released.clear();
        QDir(m_dir.path() + QStringLiteral("/cache")).removeRecursively();
    }

    // No audio yet: the answer waits for the file, then comes once.
    void waitsForTheAudio() {
        QObject owner;
        AutoSync *a = make(&owner);
        int answers = 0;
        AutoSync::Result got;
        a->sync(5, kText, [&](const AutoSync::Result &r) { got = r; ++answers; });
        QTest::qWait(50);
        QCOMPARE(answers, 0);
        m_paths[5] = m_wav;
        a->audioReady(5, false);
        QTRY_COMPARE_WITH_TIMEOUT(answers, 1, 30000);
        QVERIFY2(got.ok, qPrintable(got.error));
        QCOMPARE(got.lrc.count(u'\n'), 3);
        QVERIFY(got.lrc.startsWith(QLatin1String("[00:")));
        QCOMPARE(m_held, QStringList{m_wav});
        QCOMPARE(m_released, QStringList{m_wav});
        QTest::qWait(50);
        QCOMPARE(answers, 1);
    }

    // The same words again come from the disk cache; other words reuse the
    // kept analysis; a cache entry of another aligner version is not used.
    void cachedAndKept() {
        QObject owner;
        AutoSync *a = make(&owner);
        QSignalSpy analysed(a, &AutoSync::analysed);
        m_paths[6] = m_wav;
        AutoSync::Result first;
        bool done = false;
        a->sync(6, kText, [&](const AutoSync::Result &r) { first = r; done = true; });
        QTRY_VERIFY_WITH_TIMEOUT(done, 30000);
        QCOMPARE(analysed.count(), 1);
        QVERIFY(QFile::exists(a->cacheFile(6)));

        AutoSync *b = make(&owner);
        QSignalSpy analysedB(b, &AutoSync::analysed);
        done = false;
        AutoSync::Result again;
        b->sync(6, kText, [&](const AutoSync::Result &r) { again = r; done = true; });
        QTRY_VERIFY(done);
        QCOMPARE(again.lrc, first.lrc);
        QCOMPARE(again.kept, first.kept);
        QCOMPARE(analysedB.count(), 0);

        done = false;
        a->sync(6, QStringLiteral("Other words\nhere\n"), [&](const AutoSync::Result &r) { again = r; done = true; });
        QTRY_VERIFY_WITH_TIMEOUT(done, 10000);
        QCOMPARE(again.lrc.count(u'\n'), 2);
        QCOMPARE(analysed.count(), 1);

        QFile f(a->cacheFile(6));
        QVERIFY(f.open(QIODevice::ReadWrite));
        QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        o[QStringLiteral("v")] = Models::kVersion + 1;
        f.resize(0);
        f.write(QJsonDocument(o).toJson());
        f.close();
        AutoSync *c = make(&owner);
        QSignalSpy analysedC(c, &AutoSync::analysed);
        done = false;
        c->sync(6, QStringLiteral("Other words\nhere\n"), [&](const AutoSync::Result &) { done = true; });
        QTRY_VERIFY_WITH_TIMEOUT(done, 30000);
        QCOMPARE(analysedC.count(), 1);
    }

    void newerSyncDropsTheOlder() {
        QObject owner;
        AutoSync *a = make(&owner);
        m_paths[7] = m_wav;
        m_paths[8] = m_wav;
        int older = 0, newer = 0;
        a->sync(7, kText, [&](const AutoSync::Result &) { ++older; });
        a->sync(8, kText, [&](const AutoSync::Result &) { ++newer; });
        QTRY_COMPARE_WITH_TIMEOUT(newer, 1, 60000);
        QTest::qWait(100);
        QCOMPARE(older, 0);
        a->cancel();
    }

    void offAnswersOff() {
        QObject owner;
        AutoSync *a = make(&owner);
        a->setEnabled([] { return false; });
        m_paths[9] = m_wav;
        QString err;
        a->sync(9, kText, [&](const AutoSync::Result &r) { err = r.error; });
        QTRY_COMPARE(err, QStringLiteral("off"));
        QVERIFY(m_held.isEmpty());
    }

    void badAudioFailsOnce() {
        QObject owner;
        AutoSync *a = make(&owner);
        QSignalSpy analysed(a, &AutoSync::analysed);
        m_paths[10] = m_junk;
        AutoSync::Result got;
        bool done = false;
        a->sync(10, kText, [&](const AutoSync::Result &r) { got = r; done = true; });
        QTRY_VERIFY_WITH_TIMEOUT(done, 30000);
        QVERIFY(!got.ok);
        QVERIFY(!got.error.isEmpty());
        QCOMPARE(m_released, QStringList{m_junk});
        done = false;
        a->sync(10, kText, [&](const AutoSync::Result &r) { got = r; done = true; });
        QTRY_VERIFY(done);
        QCOMPARE(analysed.count(), 1);
    }

    // The next track is analysed ahead only with look-ahead on.
    void looksAheadWhenAsked() {
        QObject owner;
        AutoSync *a = make(&owner);
        QSignalSpy analysed(a, &AutoSync::analysed);
        m_paths[11] = m_wav;
        a->audioReady(11, true);
        QTest::qWait(100);
        QCOMPARE(analysed.count(), 0);
        a->setLookAhead(true);
        QTRY_COMPARE_WITH_TIMEOUT(analysed.count(), 1, 30000);
        QVERIFY(a->hasAnalysisForTest(11));
    }

    // Quitting does not wait for a long analysis to finish.
    void destroyedMidAnalysisQuickly() {
        auto *a = make(nullptr);
        m_paths[12] = m_long;
        a->sync(12, kText, [](const AutoSync::Result &) {});
        QTRY_VERIFY_WITH_TIMEOUT(!m_held.isEmpty(), 5000);
        QTest::qWait(300);
        QElapsedTimer t;
        t.start();
        delete a;
        QVERIFY2(t.elapsed() < 3000, qPrintable(QString::number(t.elapsed())));
    }
};

QTEST_GUILESS_MAIN(TestAutoSync)
#include "tst_autosync.moc"
