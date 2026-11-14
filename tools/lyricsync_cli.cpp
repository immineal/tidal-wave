// SPDX-License-Identifier: GPL-3.0-or-later
//
// Runs the lyrics aligner on one file:
//     lyricsync-cli <audio> <lyrics.txt> <out.lrc> [--dump <dir>]
// An <audio> ending in .f32 is read as raw interleaved stereo float at 44.1 kHz.
// Writes <out.lrc> and <out.lrc>.json (confidence, kept, seconds per stage),
// the same files as the reference predict.py. --dump writes each stage's
// output as raw float32 for comparison with the reference.

#include "lyricsync/Aligner.h"
#include "lyricsync/AudioFeed.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTextStream>
#include <chrono>
#include <ctime>
#include <memory>

using namespace lyricsync;

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    QStringList args = app.arguments().mid(1);
    QString dumpDir;
    const qsizetype di = args.indexOf(QStringLiteral("--dump"));
    if (di >= 0 && di + 1 < args.size()) {
        dumpDir = args.at(di + 1);
        args.remove(di, 2);
    }
    QTextStream err(stderr);
    if (args.size() != 3) {
        err << "usage: lyricsync-cli <audio> <lyrics.txt> <out.lrc> [--dump <dir>]\n";
        return 2;
    }
    QString why;
    const std::shared_ptr<const Models> models = Models::builtin(&why);
    if (!models) { err << "models: " << why << "\n"; return 1; }
    QFile lyricsFile(args.at(1));
    if (!lyricsFile.open(QIODevice::ReadOnly)) { err << "cannot read " << args.at(1) << "\n"; return 1; }
    const QString lyrics = QString::fromUtf8(lyricsFile.readAll());
    auto audio = std::make_unique<QFile>(args.at(0));
    if (!audio->open(QIODevice::ReadOnly)) { err << "cannot read " << args.at(0) << "\n"; return 1; }

    const std::clock_t c0 = std::clock();
    const auto w0 = std::chrono::steady_clock::now();
    FrontEnd fe;
    if (args.at(0).endsWith(QLatin1String(".f32"))) {
        const QByteArray raw = audio->readAll();
        fe.push(reinterpret_cast<const float *>(raw.constData()), size_t(raw.size()) / (2 * sizeof(float)));
    } else {
        AudioFeed feed;
        bool ok = false;
        QObject::connect(&feed, &AudioFeed::finished, &app, [&](bool good, const QString &e) {
            ok = good;
            if (!good) err << "decode: " << e << "\n";
            app.quit();
        });
        if (!feed.start(std::move(audio), &fe)) { err << "no audio decoder\n"; return 1; }
        app.exec();
        if (!ok) return 1;
    }
    const double decodeCpu = double(std::clock() - c0) / CLOCKS_PER_SEC;
    const double decodeWall = std::chrono::duration<double>(std::chrono::steady_clock::now() - w0).count();

    DumpFn dump;
    if (!dumpDir.isEmpty()) {
        QDir().mkpath(dumpDir);
        dump = [&](const char *name, const std::vector<float> &v, int) {
            QFile f(dumpDir + u'/' + QLatin1String(name) + QStringLiteral(".f32"));
            if (f.open(QIODevice::WriteOnly))
                f.write(reinterpret_cast<const char *>(v.data()), qint64(v.size() * sizeof(float)));
        };
    }
    Timing t;
    const std::clock_t c1 = std::clock();
    const Analysis a = fe.finish(*models, &t, dump);
    const Alignment al = align(a, lyrics, *models, &t);
    const double alignCpu = double(std::clock() - c1) / CLOCKS_PER_SEC;

    QFile out(args.at(2));
    if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate)) { err << "cannot write " << args.at(2) << "\n"; return 1; }
    out.write(toLrc(al).toUtf8());
    out.close();
    QJsonObject stages{{QStringLiteral("decode_wall"), decodeWall}, {QStringLiteral("decimate"), t.decimate},
                       {QStringLiteral("features"), t.features}, {QStringLiteral("detector"), t.detector},
                       {QStringLiteral("ctc_net"), t.ctc}, {QStringLiteral("align"), t.align}};
    QJsonObject j{{QStringLiteral("confidence"), al.confidence}, {QStringLiteral("kept"), al.kept},
                  {QStringLiteral("threshold"), models->threshold()}, {QStringLiteral("frames"), a.frames},
                  {QStringLiteral("seconds"), stages}, {QStringLiteral("cpu_decode_s"), decodeCpu},
                  {QStringLiteral("cpu_analyse_align_s"), alignCpu},
                  {QStringLiteral("cpu_total_s"), decodeCpu + alignCpu}};
    QFile jf(args.at(2) + QStringLiteral(".json"));
    if (jf.open(QIODevice::WriteOnly | QIODevice::Truncate)) jf.write(QJsonDocument(j).toJson());
    QTextStream(stdout) << al.lines.size() << " lines  confidence " << QString::number(al.confidence, 'f', 3)
                        << (al.kept ? " (kept)" : " (below threshold)") << "  CPU "
                        << QString::number(decodeCpu + alignCpu, 'f', 2) << " s\n";
    return 0;
}
