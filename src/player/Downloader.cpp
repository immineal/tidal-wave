#include "Downloader.h"

#include <QNetworkReply>
#include <QProcess>
#include <QFileDialog>
#include <QFileInfo>
#include <QDir>
#include <QFile>
#include <QTemporaryFile>
#include <QStandardPaths>
#include <QSettings>
#include <QTimer>
#include <QUrl>
#include <QStringList>
#include <QRegularExpression>
#include <QDebug>

Downloader::Downloader(TidalClient *client, QObject *parent)
    : QObject(parent), m_client(client)
{
    m_ffmpegPath = QStandardPaths::findExecutable(QStringLiteral("ffmpeg"));
}

Downloader::~Downloader() {
    // Tear down cleanly so app-quit leaves no orphaned ffmpeg processes or temp files.
    for (DownloadJob *job : m_jobs) {
        if (job->reply)  { job->reply->disconnect();  job->reply->abort(); job->reply->deleteLater(); }
        if (job->ffmpeg) { job->ffmpeg->disconnect(); if (job->ffmpeg->state() != QProcess::NotRunning) job->ffmpeg->kill(); job->ffmpeg->deleteLater(); }
        if (!job->audioTempPath.isEmpty()) QFile::remove(job->audioTempPath);
        if (!job->coverTempPath.isEmpty()) QFile::remove(job->coverTempPath);
        delete job;
    }
    m_jobs.clear();
}

QString Downloader::sanitizeFilename(QString name) {
    name.replace(QRegularExpression(QStringLiteral("[/\\\\:*?\"<>|]")), QStringLiteral("_"));
    // Strip control chars and collapse runs of whitespace.
    name.replace(QRegularExpression(QStringLiteral("[\\x00-\\x1f]")), QStringLiteral(" "));
    name.replace(QRegularExpression(QStringLiteral("\\s+")), QStringLiteral(" "));
    name = name.trimmed();
    if (name.size() > 200) name = name.left(200).trimmed();
    if (name.isEmpty()) name = QStringLiteral("track");
    return name;
}

void Downloader::downloadTrack(const QVariantMap &track) {
    const qlonglong id = track.value(QStringLiteral("id")).toLongLong();
    if (id <= 0) return;
    if (m_jobs.contains(id)) return;   // already downloading this track

    if (m_ffmpegPath.isEmpty()) {
        emit downloadError(id, QStringLiteral("ffmpeg was not found on PATH — install ffmpeg to enable downloads."));
        return;
    }

    // Defer the modal dialog so the QML click handler returns first (avoids
    // re-entering the QML event loop mid-delivery).
    QTimer::singleShot(0, this, [this, track, id]() {
        if (m_jobs.contains(id)) return;

        const QString artist = track.value(QStringLiteral("artists")).toString();
        const QString title  = track.value(QStringLiteral("title")).toString();
        QString base = sanitizeFilename(artist.isEmpty() ? title : (artist + QStringLiteral(" - ") + title));

        QSettings settings;
        QString dir = settings.value(QStringLiteral("download/lastDir")).toString();
        if (dir.isEmpty() || !QDir(dir).exists())
            dir = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
        if (dir.isEmpty())
            dir = QDir::homePath();

        const QString suggested = dir + QStringLiteral("/") + base + QStringLiteral(".flac");
        QString selectedFilter;
        const QString filters = QStringLiteral("FLAC (*.flac);;MP3 (*.mp3);;WAV (*.wav)");
        QString path = QFileDialog::getSaveFileName(nullptr, QStringLiteral("Save track"),
                                                    suggested, filters, &selectedFilter);
        if (path.isEmpty()) return;   // cancelled

        // Resolve format from the chosen suffix, falling back to the picked filter.
        QString fmt = QFileInfo(path).suffix().toLower();
        if (fmt != QStringLiteral("flac") && fmt != QStringLiteral("mp3") && fmt != QStringLiteral("wav")) {
            if      (selectedFilter.contains(QStringLiteral("mp3")))  fmt = QStringLiteral("mp3");
            else if (selectedFilter.contains(QStringLiteral("wav")))  fmt = QStringLiteral("wav");
            else                                                      fmt = QStringLiteral("flac");
            path += QStringLiteral(".") + fmt;
        }
        settings.setValue(QStringLiteral("download/lastDir"), QFileInfo(path).absolutePath());

        auto *job = new DownloadJob;
        job->id          = id;
        job->title       = title;
        job->artist      = artist;
        job->album       = track.value(QStringLiteral("albumTitle")).toString();
        job->trackNumber = track.value(QStringLiteral("trackNumber")).toInt();
        job->targetPath  = path;
        job->format      = fmt;

        // Build a high-res cover URL from the album cover UUID (same transform as
        // Album::coverUrl); fall back to the 320px url already in the map.
        const QString coverUuid = track.value(QStringLiteral("albumCover")).toString();
        if (!coverUuid.isEmpty()) {
            QString u = coverUuid;
            u.replace('-', '/');
            job->coverArtUrl = QStringLiteral("https://resources.tidal.com/images/%1/1280x1280.jpg").arg(u);
        } else {
            job->coverArtUrl = track.value(QStringLiteral("coverUrl")).toString();
        }

        m_jobs.insert(id, job);
        emit downloadStarted(id);
        startManifest(job);
    });
}

void Downloader::startManifest(DownloadJob *job) {
    const qlonglong id = job->id;
    m_client->fetchStreamManifest(id, AudioQuality::HiResLossless,
        [this, id](StreamManifest manifest, QString err) {
            DownloadJob *job = m_jobs.value(id, nullptr);
            if (!job) return;   // cancelled
            if (!err.isEmpty()) { finish(job, QStringLiteral("Stream error: ") + err); return; }

            job->srcTier    = manifest.codec;
            job->sampleRate = manifest.sampleRate;
            job->bitDepth   = manifest.bitDepth;
            job->replayGainTrack = manifest.replayGainTrack;
            job->replayGainAlbum = manifest.replayGainAlbum;

            if (manifest.type == StreamManifest::BTS)
                handleBts(job, manifest.url);
            else
                handleMpd(job, manifest.url);
        });
}

void Downloader::handleBts(DownloadJob *job, const QString &url) {
    const qlonglong id = job->id;
    job->isMpd = false;
    job->reply = m_client->fetchRaw(QUrl(url), [this, id](QByteArray data, QString err) {
        DownloadJob *job = m_jobs.value(id, nullptr);
        if (!job) return;
        job->reply = nullptr;
        if (!err.isEmpty() || data.isEmpty()) {
            finish(job, QStringLiteral("Failed to download audio: ") + err);
            return;
        }
        QTemporaryFile tmp(QDir::tempPath() + QStringLiteral("/tidal-wave-XXXXXX.mp4"));
        tmp.setAutoRemove(false);
        if (!tmp.open()) { finish(job, QStringLiteral("Failed to write temp audio file")); return; }
        tmp.write(data); tmp.flush(); tmp.close();
        job->audioTempPath = tmp.fileName();
        fetchCoverThenConvert(job);
    });
}

void Downloader::handleMpd(DownloadJob *job, const QString &mpdXml) {
    job->isMpd = true;
    QTemporaryFile tmp(QDir::tempPath() + QStringLiteral("/tidal-wave-XXXXXX.mpd"));
    tmp.setAutoRemove(false);
    if (!tmp.open()) { finish(job, QStringLiteral("Failed to write temp manifest")); return; }
    tmp.write(mpdXml.toUtf8()); tmp.flush(); tmp.close();
    job->audioTempPath = tmp.fileName();
    fetchCoverThenConvert(job);
}

void Downloader::fetchCoverThenConvert(DownloadJob *job) {
    // WAV has no cover-art slot; skip the fetch entirely.
    if (job->format == QStringLiteral("wav") || job->coverArtUrl.isEmpty()) {
        runFfmpeg(job);
        return;
    }
    const qlonglong id = job->id;
    job->reply = m_client->fetchRaw(QUrl(job->coverArtUrl), [this, id](QByteArray data, QString err) {
        DownloadJob *job = m_jobs.value(id, nullptr);
        if (!job) return;
        job->reply = nullptr;
        if (err.isEmpty() && !data.isEmpty()) {
            QTemporaryFile tmp(QDir::tempPath() + QStringLiteral("/tidal-wave-cover-XXXXXX.jpg"));
            tmp.setAutoRemove(false);
            if (tmp.open()) {
                tmp.write(data); tmp.flush(); tmp.close();
                job->coverTempPath = tmp.fileName();
            }
        }
        // Cover is best-effort: convert regardless of whether it succeeded.
        runFfmpeg(job);
    });
}

QStringList Downloader::ffmpegArgs(const DownloadJob *job, bool flacForceEncode) const {
    const bool srcIsFlac = (job->srcTier == QStringLiteral("LOSSLESS") ||
                            job->srcTier == QStringLiteral("HI_RES_LOSSLESS"));
    const bool hiRes     = (job->srcTier == QStringLiteral("HI_RES_LOSSLESS") || job->bitDepth > 16);
    const bool haveCover = !job->coverTempPath.isEmpty();

    QStringList a;
    a << QStringLiteral("-y") << QStringLiteral("-nostdin");
    // DASH input pulls remote segments — CLI ffmpeg needs the protocol whitelist
    // (must precede -i) or it refuses http/https and produces an empty file.
    if (job->isMpd)
        a << QStringLiteral("-protocol_whitelist")
          << QStringLiteral("file,crypto,data,http,https,tcp,tls");
    a << QStringLiteral("-i") << job->audioTempPath;
    if (haveCover)
        a << QStringLiteral("-i") << job->coverTempPath;

    a << QStringLiteral("-map") << QStringLiteral("0:a");
    if (haveCover)
        a << QStringLiteral("-map") << QStringLiteral("1:v")
          << QStringLiteral("-c:v") << QStringLiteral("mjpeg")
          << QStringLiteral("-disposition:v") << QStringLiteral("attached_pic");

    // Audio codec selection (delivered tier → chosen format).
    if (job->format == QStringLiteral("flac")) {
        if (srcIsFlac && !flacForceEncode)
            a << QStringLiteral("-c:a") << QStringLiteral("copy");
        else
            a << QStringLiteral("-c:a") << QStringLiteral("flac")
              << QStringLiteral("-compression_level") << QStringLiteral("8");
    } else if (job->format == QStringLiteral("mp3")) {
        a << QStringLiteral("-c:a") << QStringLiteral("libmp3lame")
          << QStringLiteral("-q:a") << QStringLiteral("0");
    } else { // wav
        a << QStringLiteral("-c:a") << (hiRes ? QStringLiteral("pcm_s24le") : QStringLiteral("pcm_s16le"));
    }

    // Replace any source metadata with our own clean tags.
    a << QStringLiteral("-map_metadata") << QStringLiteral("-1");
    if (!job->title.isEmpty())  a << QStringLiteral("-metadata") << (QStringLiteral("title=")  + job->title);
    if (!job->artist.isEmpty()) a << QStringLiteral("-metadata") << (QStringLiteral("artist=") + job->artist);
    if (!job->album.isEmpty())  a << QStringLiteral("-metadata") << (QStringLiteral("album=")  + job->album);
    if (job->trackNumber > 0)   a << QStringLiteral("-metadata") << (QStringLiteral("track=")  + QString::number(job->trackNumber));
    if (job->format != QStringLiteral("wav")) {
        if (job->replayGainTrack != 0.0)
            a << QStringLiteral("-metadata") << (QStringLiteral("REPLAYGAIN_TRACK_GAIN=%1 dB").arg(job->replayGainTrack));
        if (job->replayGainAlbum != 0.0)
            a << QStringLiteral("-metadata") << (QStringLiteral("REPLAYGAIN_ALBUM_GAIN=%1 dB").arg(job->replayGainAlbum));
    }
    if (job->format == QStringLiteral("mp3"))
        a << QStringLiteral("-id3v2_version") << QStringLiteral("3");

    a << job->targetPath;
    return a;
}

void Downloader::runFfmpeg(DownloadJob *job, bool flacForceEncode) {
    const qlonglong id = job->id;
    const bool srcIsFlac = (job->srcTier == QStringLiteral("LOSSLESS") ||
                            job->srcTier == QStringLiteral("HI_RES_LOSSLESS"));
    // A FLAC remux via stream-copy that fails is retried once as a real encode.
    const bool wasCopy = (job->format == QStringLiteral("flac") && srcIsFlac && !flacForceEncode);

    auto *proc = new QProcess(this);
    job->ffmpeg = proc;
    proc->setProcessChannelMode(QProcess::SeparateChannels);

    connect(proc, &QProcess::errorOccurred, this, [this, id, proc](QProcess::ProcessError e) {
        if (e != QProcess::FailedToStart) return;
        DownloadJob *job = m_jobs.value(id, nullptr);
        if (!job || job->ffmpeg != proc) return;
        finish(job, QStringLiteral("Failed to start ffmpeg"));
    });

    connect(proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
        [this, id, proc, wasCopy](int code, QProcess::ExitStatus status) {
            DownloadJob *job = m_jobs.value(id, nullptr);
            if (!job || job->ffmpeg != proc) return;

            if (status == QProcess::NormalExit && code == 0) {
                job->ffmpeg = nullptr;
                proc->deleteLater();
                finish(job, QString());   // success
                return;
            }
            const QString stderrTail = QString::fromUtf8(proc->readAllStandardError()).right(500);
            job->ffmpeg = nullptr;
            proc->deleteLater();

            if (wasCopy) {
                // stream-copy failed → retry as a real FLAC encode
                runFfmpeg(job, /*flacForceEncode=*/true);
            } else {
                QFile::remove(job->targetPath);  // drop partial/empty output
                finish(job, QStringLiteral("Conversion failed: ") + stderrTail.trimmed());
            }
        });

    proc->start(m_ffmpegPath, ffmpegArgs(job, flacForceEncode));
}

void Downloader::finish(DownloadJob *job, const QString &err) {
    if (!job) return;
    const qlonglong id = job->id;
    m_jobs.remove(id);

    if (job->reply)  { job->reply->disconnect();  job->reply->abort(); job->reply->deleteLater(); job->reply = nullptr; }
    if (job->ffmpeg) { job->ffmpeg->disconnect(); if (job->ffmpeg->state() != QProcess::NotRunning) job->ffmpeg->kill(); job->ffmpeg->deleteLater(); job->ffmpeg = nullptr; }
    if (!job->audioTempPath.isEmpty()) QFile::remove(job->audioTempPath);
    if (!job->coverTempPath.isEmpty()) QFile::remove(job->coverTempPath);

    const QString target = job->targetPath;
    delete job;

    if (err.isEmpty()) emit downloadFinished(id, target);
    else               emit downloadError(id, err);
}

void Downloader::cancelDownload(qlonglong id) {
    DownloadJob *job = m_jobs.value(id, nullptr);
    if (!job) return;
    QFile::remove(job->targetPath);
    finish(job, QStringLiteral("Download cancelled"));
}
