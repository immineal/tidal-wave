#include "CastMediaPrep.h"
#include "api/TidalClient.h"
#include "api/Models.h"
#include "player/DashFetcher.h"

#include <QProcess>
#include <QNetworkReply>
#include <QTemporaryFile>
#include <QTimer>
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
    // Deleted in place rather than deferred: m_dash is only ever non-null while
    // the fetcher has not reported yet, because the callback below clears it as
    // its first act. So nothing reached from here is mid-callback, and the
    // destructor - which also comes through here - must not leave the delete to
    // an event loop turn that will never run for this object.
    if (m_dash) { DashFetcher *d = m_dash; m_dash = nullptr; delete d; }
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
            if (!err.isEmpty()) {
                emit failed(tr("Could not load this track for casting. %1").arg(err));
                return;
            }
            prepareFromManifest(manifest);
        });
}

void CastMediaPrep::prepareFromManifest(const Tidal::StreamManifest &manifest) {
    const quint64 gen = m_gen;

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
                    emit failed(e2.isEmpty()
                        ? tr("Could not download the audio for casting. No data came back.")
                        : tr("Could not download the audio for casting. %1").arg(e2));
                    return;
                }
                QTemporaryFile tmp(QDir::tempPath() + QStringLiteral("/tidal-wave-cast-XXXXXX.mp4"));
                tmp.setAutoRemove(false);
                if (!tmp.open()) {
                    emit failed(tr("Could not save the audio to a temporary file. "
                                   "Check that there is free disk space."));
                    return;
                }
                tmp.write(data); tmp.flush(); tmp.close();
                m_inputPath = tmp.fileName();
                if (aac) {
                    // AAC-in-MP4 is directly playable by the receiver.
                    emit ready(m_inputPath, QStringLiteral("audio/mp4"));
                } else {
                    remuxFlac(sr);
                }
            });
        return;
    }

    // DASH (lossless). This used to write the manifest out to a .mpd and hand it
    // to the CLI ffmpeg behind -protocol_whitelist, leaving ffmpeg to pull the
    // segments itself. That needs ffmpeg's DASH demuxer, which is only built
    // when libxml2 is present - see DashFetcher.h, and the same shape was the
    // release blocker on the playback path. Joining the segments here hands
    // ffmpeg an ordinary fragmented MP4 instead, which every build reads, and
    // the bytes come down the app's own authenticated requests rather than a
    // second HTTP client with its own ideas about headers, redirects, proxies
    // and timeouts.
    auto *fetcher = new DashFetcher(m_client, manifest.url);
    if (!fetcher->isValid() || !fetcher->openedTempFile()) {
        const bool manifestWasReadable = fetcher->isValid();
        delete fetcher;
        emit failed(manifestWasReadable
            ? tr("Could not save the audio to a temporary file. "
                 "Check that there is free disk space.")
            : tr("Could not read the lossless stream details for this track."));
        return;
    }
    m_dash = fetcher;
    fetcher->start([this, gen, fetcher, sr](QTemporaryFile *file, const QString &dashErr) {
        // The fetcher is reporting from inside its own callback, so it cannot be
        // deleted here; one event loop turn later it has nothing in flight left.
        // Clearing the member first is what lets cancel() delete in place.
        if (m_dash == fetcher) m_dash = nullptr;
        QTimer::singleShot(0, this, [fetcher] { delete fetcher; });
        if (gen != m_gen) {           // superseded or cancelled mid-flight
            if (file) { file->remove(); delete file; }
            return;
        }
        if (!file) {
            emit failed(dashErr.isEmpty()
                ? tr("Could not download the audio for casting. No data came back.")
                : tr("Could not download the audio for casting. %1").arg(dashErr));
            return;
        }
        // Keep the bytes and drop the handle: cleanupInput() removes the path.
        m_inputPath = file->fileName();
        delete file;
        remuxFlac(sr);
    });
}

void CastMediaPrep::remuxFlac(int sampleRate) {
    const QString ffmpeg = QStandardPaths::findExecutable(QStringLiteral("ffmpeg"));
    if (ffmpeg.isEmpty()) {
        emit failed(tr("ffmpeg was not found on PATH. Install ffmpeg to cast this track."));
        return;
    }

    QTemporaryFile out(QDir::tempPath() + QStringLiteral("/tidal-wave-cast-XXXXXX.flac"));
    out.setAutoRemove(false);
    if (!out.open()) {
        emit failed(tr("Could not create a temporary file for the converted audio. "
                       "Check that there is free disk space."));
        return;
    }
    m_outputPath = out.fileName();
    out.close();

    QStringList a;
    a << QStringLiteral("-y") << QStringLiteral("-nostdin");
    // No -protocol_whitelist any more: the input is always a local file whose
    // bytes are already here, DASH included, so ffmpeg has nothing remote to
    // fetch and no manifest to demux.
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
            else           emit failed(tr("Could not convert the audio for casting. "
                                          "ffmpeg exited with code %1.").arg(code));
        });
    m_ffmpeg->start(ffmpeg, a);
}
