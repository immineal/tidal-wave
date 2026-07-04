#include "CastMediaPrep.h"
#include "api/TidalClient.h"
#include "api/Models.h"

#include <QProcess>
#include <QNetworkReply>
#include <QTemporaryFile>
#include <QDir>
#include <QFile>
#include <QStandardPaths>

CastMediaPrep::CastMediaPrep(TidalClient *client, QObject *parent)
    : QObject(parent), m_client(client) {}

CastMediaPrep::~CastMediaPrep() {
    cancel();
}

void CastMediaPrep::cancel() {
    ++m_gen;
    if (m_reply) { m_reply->abort(); m_reply = nullptr; }
    if (m_ffmpeg) { m_ffmpeg->kill(); m_ffmpeg->deleteLater(); m_ffmpeg = nullptr; }
    cleanupInput();
    if (!m_outputPath.isEmpty()) { QFile::remove(m_outputPath); m_outputPath.clear(); }
}

void CastMediaPrep::cleanupInput() {
    if (!m_inputPath.isEmpty()) { QFile::remove(m_inputPath); m_inputPath.clear(); }
}

void CastMediaPrep::prepare(qlonglong trackId) {
    cancel();
    m_trackId = trackId;
    const quint64 gen = m_gen;

    m_client->fetchStreamManifest(trackId, AudioQuality::HiResLossless,
        [this, gen](StreamManifest manifest, QString err) {
            if (gen != m_gen) return;   // superseded/cancelled
            if (!err.isEmpty()) { emit failed(QStringLiteral("Stream error: ") + err); return; }

            const bool aac = (manifest.codec == QStringLiteral("LOW") ||
                              manifest.codec == QStringLiteral("HIGH"));
            const int  sr  = manifest.sampleRate;

            if (manifest.type == StreamManifest::BTS) {
                // Fetch the direct URL to a temp file.
                m_reply = m_client->fetchRaw(QUrl(manifest.url),
                    [this, gen, aac, sr](QByteArray data, QString e2) {
                        if (gen != m_gen) return;
                        m_reply = nullptr;
                        if (!e2.isEmpty() || data.isEmpty()) {
                            emit failed(QStringLiteral("Failed to fetch audio: ") + e2);
                            return;
                        }
                        QTemporaryFile tmp(QDir::tempPath() + QStringLiteral("/tidal-wave-cast-XXXXXX.mp4"));
                        tmp.setAutoRemove(false);
                        if (!tmp.open()) { emit failed(QStringLiteral("Temp file error")); return; }
                        tmp.write(data); tmp.flush(); tmp.close();
                        m_inputPath = tmp.fileName();
                        if (aac) {
                            // AAC-in-MP4 is directly playable by the receiver.
                            emit ready(m_inputPath, QStringLiteral("audio/mp4"));
                        } else {
                            remuxFlac(/*isMpd=*/false, sr);
                        }
                    });
            } else {
                // MPD: write the DASH XML to a temp file; ffmpeg pulls the segments.
                QTemporaryFile tmp(QDir::tempPath() + QStringLiteral("/tidal-wave-cast-XXXXXX.mpd"));
                tmp.setAutoRemove(false);
                if (!tmp.open()) { emit failed(QStringLiteral("Temp file error")); return; }
                tmp.write(manifest.url.toUtf8()); tmp.flush(); tmp.close();
                m_inputPath = tmp.fileName();
                remuxFlac(/*isMpd=*/true, sr);
            }
        });
}

void CastMediaPrep::remuxFlac(bool isMpd, int sampleRate) {
    const QString ffmpeg = QStandardPaths::findExecutable(QStringLiteral("ffmpeg"));
    if (ffmpeg.isEmpty()) { emit failed(QStringLiteral("ffmpeg not found")); return; }

    QTemporaryFile out(QDir::tempPath() + QStringLiteral("/tidal-wave-cast-XXXXXX.flac"));
    out.setAutoRemove(false);
    if (!out.open()) { emit failed(QStringLiteral("Temp file error")); return; }
    m_outputPath = out.fileName();
    out.close();

    QStringList a;
    a << QStringLiteral("-y") << QStringLiteral("-nostdin");
    if (isMpd)
        a << QStringLiteral("-protocol_whitelist")
          << QStringLiteral("file,crypto,data,http,https,tcp,tls");
    a << QStringLiteral("-i") << m_inputPath << QStringLiteral("-map") << QStringLiteral("0:a");
    // Chromecast's default receiver caps FLAC at 96 kHz; downsample if higher,
    // otherwise stream-copy the FLAC bitstream unchanged.
    if (sampleRate > 96000)
        a << QStringLiteral("-c:a") << QStringLiteral("flac")
          << QStringLiteral("-ar") << QStringLiteral("96000")
          << QStringLiteral("-compression_level") << QStringLiteral("5");
    else
        a << QStringLiteral("-c:a") << QStringLiteral("copy");
    a << m_outputPath;

    const quint64 gen = m_gen;
    m_ffmpeg = new QProcess(this);
    connect(m_ffmpeg, &QProcess::finished, this,
        [this, gen](int code, QProcess::ExitStatus) {
            if (gen != m_gen) return;
            if (m_ffmpeg) { m_ffmpeg->deleteLater(); m_ffmpeg = nullptr; }
            cleanupInput();
            if (code == 0) emit ready(m_outputPath, QStringLiteral("audio/flac"));
            else           emit failed(QStringLiteral("ffmpeg failed (exit %1)").arg(code));
        });
    m_ffmpeg->start(ffmpeg, a);
}
