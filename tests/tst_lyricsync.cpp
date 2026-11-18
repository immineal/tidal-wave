// The lyrics aligner's parts against the reference pipeline it ports.
// Expected values come from the reference run on the same input; all audio
// here is synthetic.

#include <QAudioDecoder>
#include <QBuffer>
#include <QFile>
#include <QSignalSpy>
#include <QTest>
#include <cmath>
#include <memory>

#include "lyricsync/Aligner.h"
#include "lyricsync/AudioFeed.h"
#include "lyricsync/Decode.h"
#include "lyricsync/Dsp.h"
#include "lyricsync/Nets.h"
#include "lyricsync/Text.h"

#include "aac_fixture.inc"

using namespace lyricsync;

namespace {

QString letters(const std::vector<int> &tk) {
    QString s;
    for (int t : tk) s += QChar(u'a' + t - 1);
    return s;
}

// Harmonic bursts over a little hashed noise; the reference made its
// expected values from the same formula.
constexpr double kPi = 3.14159265358979323846;

std::vector<float> synth(double seconds) {
    const size_t n = size_t(seconds * 44100);
    std::vector<float> lr(2 * n);
    for (size_t i = 0; i < n; ++i) {
        const double t = double(i) / 44100;
        const double q = t / 0.5, fl = std::floor(q);
        const long long k = (long long)fl;
        const double f0 = 180.0 + 40.0 * double(k % 5);
        const double env = (k % 4) != 3 ? 0.3 * std::sin(kPi * (q - fl)) : 0.0;
        double s = 0;
        for (int h = 1; h <= 6; ++h) s += std::sin(2 * kPi * h * f0 * t) / h;
        s *= env;
        const uint64_t hsh = (uint64_t(i) * 2654435761ull) % (1ull << 32);
        const double noise = double(hsh) / 4294967296.0 - 0.5;
        lr[2 * i] = float(s + 0.02 * noise);
        lr[2 * i + 1] = float(s - 0.02 * noise);
    }
    return lr;
}

std::unique_ptr<QIODevice> bufferOf(const char *b64) {
    auto b = std::make_unique<QBuffer>();
    b->setData(QByteArray::fromBase64(QByteArray(b64)));
    b->open(QIODevice::ReadOnly);
    return b;
}

} // namespace

class TestLyricSync : public QObject {
    Q_OBJECT

    std::shared_ptr<const Models> m_models;

private slots:
    void initTestCase() {
        QString err;
        m_models = Models::builtin(&err);
        QVERIFY2(m_models, qPrintable(err));
    }

    void halfRoundsToNearestEven() {
        QCOMPARE(dsp::floatToHalf(1.0f), uint16_t(0x3C00));
        QCOMPARE(dsp::floatToHalf(1.0f + 1.0f / 2048), uint16_t(0x3C00));        // tie, to even
        QCOMPARE(dsp::floatToHalf(1.0f + 3.0f / 2048), uint16_t(0x3C02));        // tie, to even
        QCOMPARE(dsp::floatToHalf(65520.0f), uint16_t(0x7C00));                  // overflows to inf
        QCOMPARE(dsp::floatToHalf(-2.0f), uint16_t(0xC000));
        QCOMPARE(dsp::floatToHalf(6e-8f), uint16_t(0x0001));                     // subnormal
        // Straight from double, not through float (numpy does the same).
        QCOMPARE(dsp::doubleToHalf(1.0 + 1.0 / 2048 + 1e-12), uint16_t(0x3C01));
        QCOMPARE(dsp::halfToFloat(0x3555), 0.333251953125f);
    }

    void statisticsMatchNumpy() {
        QCOMPARE(dsp::median({3.f, 1.f, 2.f, 4.f}), 2.5f);
        QCOMPARE(dsp::percentile({1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, 10), 1.9);
        const dsp::Quartiles q = dsp::quartiles({1, 2, 3, 4, 5});
        QCOMPARE(q.median, 3.f);
        QCOMPARE(q.scale, 2.0);
        QCOMPARE(dsp::quartiles({2, 2, 2}).scale, 1e-3);
    }

    void plainLinesDropHeadersAndBlanks() {
        const QStringList l = plainLines(QStringLiteral("  [Verse 1]\r\nHello  \n\n[x] y\n last"));
        QCOMPARE(l, (QStringList{QStringLiteral("Hello"), QStringLiteral("[x] y"), QStringLiteral("last")}));
    }

    void tokens_data() {
        QTest::addColumn<QString>("line");
        QTest::addColumn<QString>("expected");
        // The reference's output for each line.
        QTest::newRow("latin, several words") << QStringLiteral("Hé, hi there!") << QStringLiteral("hehithere");
        QTest::newRow("greek") << QStringLiteral("Μέρα νύχτα") << QStringLiteral("meranukhta");
        QTest::newRow("cyrillic") << QStringLiteral("Да да") << QStringLiteral("dada");
        QTest::newRow("look-alikes in latin words") << QStringLiteral("lаla mаma") << QStringLiteral("lalamama");
        QTest::newRow("look-alikes left alone") << QStringLiteral("Да lа") << QStringLiteral("dala");
        QTest::newRow("han") << QStringLiteral("日本") << QStringLiteral("riben");
        QTest::newRow("sharp s") << QStringLiteral("Straße") << QStringLiteral("strasse");
        QTest::newRow("compatibility forms") << QStringLiteral("ﬁne ½") << QStringLiteral("fine");
        QTest::newRow("polish") << QStringLiteral("ąę łódź") << QStringLiteral("aelodz");
        QTest::newRow("kana") << QStringLiteral("こんにちは") << QStringLiteral("konnichiha");
        QTest::newRow("hangul") << QStringLiteral("안녕") << QStringLiteral("annyeong");
        QTest::newRow("hebrew") << QStringLiteral("שלום") << QStringLiteral("shlvm");
        QTest::newRow("no letters") << QStringLiteral("… !") << QString();
    }

    void tokens() {
        QFETCH(QString, line);
        QFETCH(QString, expected);
        QCOMPARE(letters(lyricsync::tokens(line, translit())), expected);
    }

    void fillTimesInterpolatesAndHolds() {
        const double nan = std::nan("");
        const std::vector<double> t = fillTimes({nan, 1, nan, 3, nan}, 10);
        QCOMPARE(t, (std::vector<double>{1, 1, 2, 3, 3}));
        QCOMPARE(fillTimes({nan, nan, nan}, 10), (std::vector<double>{0, 4.5, 9}));
    }

    // A made-up letter track: "ab" sung at frame 100, "cd" at frame 250.
    void decodeFindsTheLetters() {
        const int T = 400, V = 27;
        std::vector<float> lp(size_t(T) * V, std::log(0.03f / 26));
        for (int t = 0; t < T; ++t) lp[size_t(t) * V] = std::log(0.97f);
        auto sing = [&](int t, int letter) {
            for (int v = 0; v < V; ++v) lp[size_t(t) * V + v] = std::log(v == letter ? 0.97f : 0.03f / 26);
        };
        sing(100, 1); sing(104, 2); sing(250, 3); sing(254, 4);
        const std::vector<float> start(T / 4, -5.f), vocal(T / 4, 1.f);
        LineTargets lines;
        lines.tokens = {1, 2, 3, 4};
        lines.first = {0, 2};
        const Decoded d = decodeSong(lp, T, dsp::kFps, start, vocal, lines, DecodeParams{});
        QVERIFY(d.ok);
        QCOMPARE(d.a.tf, (std::vector<long long>{100, 104, 250, 254}));
        QCOMPARE(d.a.t[1], 250 / dsp::kFps);
        QVERIFY(!d.switched);
        QCOMPARE(d.f.size(), size_t(15));   // the 14 the confidence reads, and the switch
    }

    void decodeSkipsSongsTooLongToAlign() {
        const int T = 120000, V = 27;
        std::vector<float> lp(size_t(T) * V, -3.f);
        LineTargets lines;
        lines.tokens.assign(3000, 1);
        lines.first = {0};
        QVERIFY(!decodeSong(lp, T, dsp::kFps, std::vector<float>(T / 4, 0.f), std::vector<float>(T / 4, 1.f),
                            lines, DecodeParams{}).ok);
    }

    void brokenModelFilesAreRefused() {
        QFile f(QStringLiteral(":/lyricsync/ctc.f16.bin"));
        QVERIFY(f.open(QIODevice::ReadOnly));
        const QByteArray ctc = f.readAll();
        QFile g(QStringLiteral(":/lyricsync/detector.f16.bin"));
        QVERIFY(g.open(QIODevice::ReadOnly));
        const QByteArray det = g.readAll();
        QFile h(QStringLiteral(":/lyricsync/translit.bin"));
        QVERIFY(h.open(QIODevice::ReadOnly));
        const QByteArray tr = h.readAll();
        QString err;
        QVERIFY(Models::fromData(ctc, det, tr, &err));
        QVERIFY(!Models::fromData(ctc.left(ctc.size() - 2), det, tr, &err));
        QVERIFY(!Models::fromData(ctc, det.left(100), tr, &err));
        QVERIFY(!Models::fromData(ctc, det, tr.left(tr.size() - 1), &err));
        QVERIFY(!Models::fromData(det, ctc, tr, &err));
    }

    // The nets' outputs on synthetic audio, against the reference's.
    void analysisMatchesTheReference() {
        const std::vector<float> lr = synth(16.0);
        FrontEnd fe;
        for (size_t at = 0; at < lr.size() / 2; at += 4096)
            fe.push(lr.data() + 2 * at, std::min<size_t>(4096, lr.size() / 2 - at));
        const Analysis a = fe.finish(*m_models);
        QCOMPARE(a.frames, 686);
        QCOMPARE(a.vocal.size(), size_t(171));
        static const double lpMean[27] = {
            -0.19748, -6.63927, -8.51617, -8.24081, -6.4571, -5.07514, -8.11499, -7.31135, -5.77895,
            -6.57163, -10.90838, -8.67688, -6.93223, -7.08787, -6.50474, -6.41912, -8.57585, -12.60257,
            -6.5787, -6.69433, -5.84352, -7.53962, -9.51098, -7.48216, -13.42058, -6.59686, -11.41333};
        for (int v = 0; v < 27; ++v) {
            double s = 0;
            for (int t = 0; t < a.frames; ++t) s += a.lp[size_t(t) * 27 + v];
            QVERIFY2(std::abs(s / a.frames - lpMean[v]) < 0.01, qPrintable(QString::number(v)));
        }
        static const double vocal[9] = {0.027, -0.1867, 1.9226, 2.213, -0.4551, -1.3755, 0.055, 1.9748, 1.3049};
        for (int i = 0; i < 9; ++i) QVERIFY(std::abs(a.vocal[size_t(i) * 20] - vocal[i]) < 0.05);
    }

    void tooShortAudioGivesPlainTimes() {
        const std::vector<float> lr = synth(0.5);
        FrontEnd fe;
        fe.push(lr.data(), lr.size() / 2);
        const Analysis a = fe.finish(*m_models);
        QCOMPARE(a.frames, 0);
        const Alignment al = align(a, QStringLiteral("one\ntwo"), *m_models);
        QCOMPARE(al.lines.size(), 2);
        QCOMPARE(al.times.size(), size_t(2));
        QVERIFY(!al.aligned);
        QVERIFY(!al.kept);
    }

    void alignsEveryLineOfALongText() {
        const std::vector<float> lr = synth(16.0);
        FrontEnd fe;
        fe.push(lr.data(), lr.size() / 2);
        const Analysis a = fe.finish(*m_models);
        // Several Latin words a line: the tokeniser once looped forever here.
        const Alignment al = align(a, QStringLiteral("La la la\nOh na na na\n[Chorus]\nHey hey yeah\n"), *m_models);
        QVERIFY(al.aligned);
        QCOMPARE(al.times.size(), size_t(3));
        QVERIFY(al.times[0] <= al.times[1] && al.times[1] <= al.times[2]);
        QVERIFY(std::isfinite(al.confidence));
        QVERIFY(toLrc(al).startsWith(QLatin1String("[00:")));
    }

    // A raised stop flag ends the analysis and the alignment early.
    void stopFlagEndsEveryStage() {
        const std::vector<float> lr = synth(16.0);
        std::atomic<bool> stop{true};
        FrontEnd stopped;
        stopped.setStop(&stop);
        stopped.push(lr.data(), lr.size() / 2);
        QCOMPARE(stopped.finish(*m_models).frames, 0);
        FrontEnd fe;
        fe.push(lr.data(), lr.size() / 2);
        const Analysis a = fe.finish(*m_models);
        QVERIFY(a.frames > 0);
        const QString text = QStringLiteral("La la la\nOh na na na\nHey hey yeah\n");
        QVERIFY(align(a, text, *m_models).aligned);
        QVERIFY(!align(a, text, *m_models, nullptr, &stop).aligned);
        QFile df(QStringLiteral(":/lyricsync/detector.f16.bin"));
        QVERIFY(df.open(QIODevice::ReadOnly));
        Detector det;
        QString err;
        QVERIFY2(det.load(df.readAll(), &err), qPrintable(err));
        std::vector<float> v, o, x(size_t(det.inputs()) * 64, 0.f);
        QVERIFY(det.forward(x.data(), 64, v, o));
        QVERIFY(!det.forward(x.data(), 64, v, o, &stop));
    }

    void decodesBothAacProfiles_data() {
        QTest::addColumn<QByteArray>("b64");
        QTest::newRow("lc") << QByteArray(kAacLcB64);
        QTest::newRow("he") << QByteArray(kHeAacB64);
    }

    void decodesBothAacProfiles() {
        QFETCH(QByteArray, b64);
        FrontEnd fe;
        AudioFeed feed;
        QSignalSpy done(&feed, &AudioFeed::finished);
        if (!feed.start(bufferOf(b64.constData()), &fe)) QSKIP("no audio decoder");
        QVERIFY(done.wait(20000));
        QVERIFY2(done.at(0).at(0).toBool(), qPrintable(done.at(0).at(1).toString()));
        // FFmpeg versions differ in how much HE-AAC priming they drop: Qt 6.4's
        // on Debian 12 drops about 4100 frames more than Qt 6.12's.
        const qint64 expect = qint64(kAacDurationMs) * 44100 / 1000;
        QVERIFY2(std::abs(qint64(fe.framesIn()) - expect) < 8192, qPrintable(QString::number(fe.framesIn())));
    }

    void undecodableAudioFails() {
        FrontEnd fe;
        AudioFeed feed;
        QSignalSpy done(&feed, &AudioFeed::finished);
        auto b = std::make_unique<QBuffer>();
        b->setData(QByteArray(4096, 'x'));
        b->open(QIODevice::ReadOnly);
        if (!feed.start(std::move(b), &fe)) QSKIP("no audio decoder");
        // Qt 6.4 neither decodes nor reports this: the stall watchdog ends it.
        QTRY_COMPARE_WITH_TIMEOUT(done.count(), 1, AudioFeed::kStallMs + 10000);
        QVERIFY(!done.at(0).at(0).toBool());
    }

    // An error the decoder posted before it was let go arrives after the end.
    void errorAfterTheEndIsIgnored() {
        FrontEnd fe;
        AudioFeed feed;
        QSignalSpy done(&feed, &AudioFeed::finished);
        if (!feed.start(bufferOf(kAacLcB64), &fe)) QSKIP("no audio decoder");
        auto *dec = feed.findChild<QAudioDecoder *>();
        QVERIFY(dec);
        emit dec->finished();
        emit dec->error(QAudioDecoder::ResourceError);
        QTRY_COMPARE(done.count(), 1);
        QTest::qWait(50);
        QCOMPARE(done.count(), 1);
    }

private:
    static const Translit &translit() {
        static Translit t = [] {
            Translit x;
            QFile f(QStringLiteral(":/lyricsync/translit.bin"));
            if (f.open(QIODevice::ReadOnly)) x.load(f.readAll(), nullptr);
            return x;
        }();
        return t;
    }
};

QTEST_GUILESS_MAIN(TestLyricSync)
#include "tst_lyricsync.moc"
