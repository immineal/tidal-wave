// SPDX-License-Identifier: GPL-3.0-or-later

#include "Downloader.h"

#include <QNetworkReply>
#include <QProcess>
#include <QFileDialog>
#include <QFileInfo>
#include <QDir>
#include <QFile>
#include <QTemporaryFile>
#include "DashFetcher.h"
#include <QStandardPaths>
#include <QSettings>
#include <QTimer>
#include <QUrl>
#include <QStringList>
#include <QRegularExpression>
#include <QDebug>
#include <QDesktopServices>
#include <utility>
#if defined(Q_OS_LINUX) || defined(Q_OS_FREEBSD)
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#endif

namespace {
const QString kFolderKey = QStringLiteral("download/lastDir");
}

Downloader::Downloader(TidalClient *client, QObject *parent)
    : QObject(parent), m_client(client)
{
}

// Searched once PATH has come up empty. A process started from a .desktop
// entry inherits the session's PATH, which the user's shell profile never
// extends, so an ffmpeg installed elsewhere is invisible to the app.
QStringList Downloader::ffmpegFallbackDirs() {
    return {
        QStringLiteral("/usr/local/bin"),                  // built and installed by hand
        QDir::homePath() + QStringLiteral("/.local/bin"),  // installed for this user only
        QStringLiteral("/snap/bin"),                       // snap, which exports nothing to PATH
    };
}

// PATH first, so a user who deliberately put one ffmpeg in front keeps it.
QString Downloader::resolveFfmpeg(const QStringList &extraDirs) {
    const QString onPath = QStandardPaths::findExecutable(QStringLiteral("ffmpeg"));
    if (!onPath.isEmpty()) return onPath;
    // findExecutable() with an explicit list searches only that list, hence
    // the second call.
    return QStandardPaths::findExecutable(QStringLiteral("ffmpeg"), extraDirs);
}

// Asked per download, so an ffmpeg installed while the app runs is found
// without a restart.
QString Downloader::ffmpegPath() const {
    return resolveFfmpeg(ffmpegFallbackDirs());
}

Downloader::~Downloader() {
    qDeleteAll(m_collections);
    // Tear down cleanly so app-quit leaves no orphaned ffmpeg processes or temp files.
    for (DownloadJob *job : m_jobs) {
        if (job->reply)  { job->reply->disconnect();  job->reply->abort(); job->reply->deleteLater(); }
        delete job->dash;   // aborts whatever segments were still coming
        if (job->ffmpeg) { job->ffmpeg->disconnect(); if (job->ffmpeg->state() != QProcess::NotRunning) job->ffmpeg->kill(); job->ffmpeg->deleteLater(); }
        if (!job->audioTempPath.isEmpty()) QFile::remove(job->audioTempPath);
        if (!job->coverTempPath.isEmpty()) QFile::remove(job->coverTempPath);
        if (!job->writePath.isEmpty()) QFile::remove(job->writePath);
        delete job;
    }
    m_jobs.clear();
}

QString Downloader::sanitizeFilename(QString name) {
    name.replace(QRegularExpression(QStringLiteral("[/\\\\:*?\"<>|]")), QStringLiteral("_"));
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

    if (ffmpegPath().isEmpty()) {
        emit downloadError(id, tr("ffmpeg was not found on PATH. Install ffmpeg to enable downloads."));
        return;
    }

    // Defer the modal dialog so the QML click handler returns first (avoids
    // re-entering the QML event loop mid-delivery).
    QTimer::singleShot(0, this, [this, track, id]() {
        if (m_jobs.contains(id)) return;

        const QString artist = track.value(QStringLiteral("artists")).toString();
        const QString title  = track.value(QStringLiteral("title")).toString();
        QString base = sanitizeFilename(artist.isEmpty() ? title : (artist + QStringLiteral(" - ") + title));

        const QString dir = folder();
        const QString suggested = dir + QStringLiteral("/") + base + QStringLiteral(".flac");
        QString selectedFilter;
        const QString filters = QStringLiteral("FLAC (*.flac);;MP3 (*.mp3);;WAV (*.wav)");
        QString path = QFileDialog::getSaveFileName(nullptr, tr("Save track"),
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
        setFolder(QFileInfo(path).absolutePath());

        DownloadJob *job = makeJob(track, path, fmt);
        m_jobs.insert(id, job);
        emit downloadStarted(id);
        startManifest(job);
    });
}

Downloader::DownloadJob *Downloader::makeJob(const QVariantMap &track, const QString &path,
                                             const QString &format) {
    auto *job = new DownloadJob;
    job->id          = track.value(QStringLiteral("id")).toLongLong();
    job->title       = track.value(QStringLiteral("title")).toString();
    job->artist      = track.value(QStringLiteral("artists")).toString();
    job->album       = track.value(QStringLiteral("albumTitle")).toString();
    job->trackNumber = track.value(QStringLiteral("trackNumber")).toInt();
    job->targetPath  = path;
    job->format      = format;

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
    return job;
}

void Downloader::startManifest(DownloadJob *job) {
    const qlonglong id = job->id;
    m_client->fetchStreamManifest(id, AudioQuality::HiResLossless,
        [this, id](StreamManifest manifest, QString err) {
            DownloadJob *job = m_jobs.value(id, nullptr);
            if (!job) return;   // cancelled
            if (!err.isEmpty()) {
                // TidalApi holds the endpoint when this was a 429.
                job->rateLimitedSecs = m_client->streamRequestsHeldFor(AudioQuality::HiResLossless);
                finish(job, tr("Could not start the download. %1").arg(err));
                return;
            }

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
    job->reply = m_client->fetchRaw(QUrl(url), [this, id](QByteArray data, QString err) {
        DownloadJob *job = m_jobs.value(id, nullptr);
        if (!job) return;
        job->reply = nullptr;
        if (!err.isEmpty() || data.isEmpty()) {
            finish(job, err.isEmpty()
                ? tr("Could not download the audio for this track. No data came back.")
                : tr("Could not download the audio for this track. %1").arg(err));
            return;
        }
        QTemporaryFile tmp(QDir::tempPath() + QStringLiteral("/tidal-wave-XXXXXX.mp4"));
        tmp.setAutoRemove(false);
        if (!tmp.open()) { finish(job, tr("Could not save the audio to a temporary file. "
                                        "Check that there is free disk space.")); return; }
        tmp.write(data); tmp.flush(); tmp.close();
        job->audioTempPath = tmp.fileName();
        fetchCoverThenConvert(job);
    });
}

void Downloader::handleMpd(DownloadJob *job, const QString &mpdXml) {
    // Joined here into an ordinary fragmented MP4, which every ffmpeg reads.
    // Handing ffmpeg the manifest needs its DASH demuxer, which is only built
    // with libxml2 and is missing from several builds.
    const qlonglong id = job->id;

    auto *fetcher = new DashFetcher(m_client, mpdXml);
    if (!fetcher->isValid() || !fetcher->openedTempFile()) {
        const bool manifestWasReadable = fetcher->isValid();
        delete fetcher;
        finish(job, manifestWasReadable
            ? tr("Could not save the audio to a temporary file. "
                 "Check that there is free disk space.")
            : tr("Could not read the lossless stream details for this track."));
        return;
    }
    job->dash = fetcher;
    if (!job->collectionKey.isEmpty()) {
        const QString key = job->collectionKey;
        const int parts = fetcher->partCount();
        fetcher->setProgress([this, key, id, parts](qint64, int segments) {
            for (Collection *c : std::as_const(m_collections)) {
                if (c->key != key || c->current != id) continue;
                c->currentDone = parts > 0 ? double(segments) / parts : 0.0;
                emit collectionChanged(key);
            }
        });
    }
    fetcher->start([this, id, fetcher](QTemporaryFile *file, const QString &dashErr) {
        // The fetcher reports from inside its own callback: delete it a turn later.
        QTimer::singleShot(0, this, [fetcher] { delete fetcher; });
        DownloadJob *job = m_jobs.value(id, nullptr);
        if (job && job->dash == fetcher) job->dash = nullptr;
        if (!job) {                 // cancelled while segments were in flight
            if (file) { file->remove(); delete file; }
            return;
        }
        if (!file) {
            job->rateLimitedSecs = fetcher->rateLimitedSecs();
            finish(job, dashErr.isEmpty()
                ? tr("Could not download the audio for this track. No data came back.")
                : tr("Could not download the audio for this track. %1").arg(dashErr));
            return;
        }
        // Keep the bytes and drop the handle: finish() removes the path.
        job->audioTempPath = file->fileName();
        delete file;
        fetchCoverThenConvert(job);
    });
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
    // The input is always a local file, DASH included, so no
    // -protocol_whitelist is needed.
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

    a << (job->writePath.isEmpty() ? job->targetPath : job->writePath);
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
        finish(job, tr("Could not start ffmpeg. Check that it is installed and that "
                        "you have permission to run it."));
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
                runFfmpeg(job, /*flacForceEncode=*/true);
            } else {
                // Drop partial/empty output.
                QFile::remove(job->writePath.isEmpty() ? job->targetPath : job->writePath);
                finish(job, tr("Could not convert the downloaded track. %1").arg(stderrTail.trimmed()));
            }
        });

    proc->start(ffmpegPath(), ffmpegArgs(job, flacForceEncode));
}

void Downloader::finish(DownloadJob *job, const QString &err, bool cancelled) {
    if (!job) return;
    const qlonglong id = job->id;
    m_jobs.remove(id);

    if (job->reply)  { job->reply->disconnect();  job->reply->abort(); job->reply->deleteLater(); job->reply = nullptr; }
    if (job->dash)   { DashFetcher *d = job->dash; job->dash = nullptr; QTimer::singleShot(0, this, [d] { delete d; }); }
    if (job->ffmpeg) { job->ffmpeg->disconnect(); if (job->ffmpeg->state() != QProcess::NotRunning) job->ffmpeg->kill(); job->ffmpeg->deleteLater(); job->ffmpeg = nullptr; }
    if (!job->audioTempPath.isEmpty()) QFile::remove(job->audioTempPath);
    if (!job->coverTempPath.isEmpty()) QFile::remove(job->coverTempPath);

    QString error = err;
    // A collection's track is written beside its name and moved there whole,
    // so a file under the final name is always a finished one.
    if (!job->writePath.isEmpty()) {
        if (error.isEmpty() && !cancelled) {
            QFile::remove(job->targetPath);
            if (!QFile::rename(job->writePath, job->targetPath))
                error = tr("Could not save the track in the download folder.");
        }
        QFile::remove(job->writePath);
    }

    const QString target = job->targetPath;
    const QString key = job->collectionKey;
    const int rateLimitedSecs = job->rateLimitedSecs;
    delete job;

    if (cancelled) {
        emit downloadCancelled(id);
    } else if (error.isEmpty()) {
        m_saved.insert(id, target);
        emit downloadFinished(id, target);
    } else {
        emit downloadError(id, error);
    }
    if (!key.isEmpty()) collectionTrackEnded(key, id, !cancelled && error.isEmpty(), error,
                                             rateLimitedSecs);
}

void Downloader::cancelDownload(qlonglong id) {
    DownloadJob *job = m_jobs.value(id, nullptr);
    if (!job) return;
    QFile::remove(job->targetPath);
    finish(job, tr("Download cancelled"));
}

// ── albums and playlists ────────────────────────────────────────────────────

namespace {
QString keyOf(const QString &kind, const QString &id) { return kind + QLatin1Char(':') + id; }
const QString kWaiting   = QStringLiteral("waiting");
const QString kRunning   = QStringLiteral("running");
const QString kDone      = QStringLiteral("done");
const QString kCancelled = QStringLiteral("cancelled");
const QString kPaused    = QStringLiteral("paused");
}

Downloader::Collection *Downloader::findCollection(const QString &key) const {
    for (Collection *c : m_collections)
        if (c->key == key) return c;
    return nullptr;
}

void Downloader::downloadCollection(const QString &kind, const QString &id,
                                    const QString &title, const QVariantList &tracks) {
    if (id.isEmpty() || tracks.isEmpty()) return;
    Collection *c = findCollection(keyOf(kind, id));
    if (c && (c->state == kWaiting || c->state == kRunning)) return;
    // Stopped partway: on in the same folder, past the tracks already there.
    if (c && c->state != kDone && QDir(c->folder).exists()) {
        downloadCollectionInto(kind, id, title, tracks, QFileInfo(c->folder).absolutePath());
        return;
    }
    // Deferred like the save dialog, so the click handler returns first.
    QTimer::singleShot(0, this, [this, kind, id, title, tracks] {
        const QString dir = QFileDialog::getExistingDirectory(nullptr, tr("Download to folder"), folder());
        if (dir.isEmpty()) return;
        setFolder(dir);
        downloadCollectionInto(kind, id, title, tracks, dir);
    });
}

void Downloader::downloadCollectionInto(const QString &kind, const QString &id,
                                        const QString &title, const QVariantList &tracks,
                                        const QString &parentDir) {
    const QString key = keyOf(kind, id);
    if (Collection *old = findCollection(key)) {
        if (old->state == kWaiting || old->state == kRunning) return;
        m_collections.removeOne(old);
        delete old;
    }
    auto *c = new Collection;
    c->key    = key;
    c->kind   = kind;
    c->title  = title;
    c->tracks = tracks;
    c->folder = QDir(parentDir).filePath(sanitizeFilename(title));
    m_collections.append(c);

    if (ffmpegPath().isEmpty()) {
        c->failed = int(tracks.size());
        c->error  = tr("ffmpeg was not found on PATH. Install ffmpeg to enable downloads.");
        c->state  = kDone;
    } else if (!QDir().mkpath(c->folder)) {
        c->failed = int(tracks.size());
        c->error  = tr("Could not make the folder %1.").arg(QDir::toNativeSeparators(c->folder));
        c->state  = kDone;
    }
    emit collectionChanged(key);
    pumpCollections();
}

void Downloader::cancelCollection(const QString &kind, const QString &id) {
    Collection *c = findCollection(keyOf(kind, id));
    if (!c || (c->state != kWaiting && c->state != kRunning)) return;
    c->state = kCancelled;
    if (DownloadJob *job = c->current ? m_jobs.value(c->current, nullptr) : nullptr) {
        c->current = 0;
        if (job->collectionKey == c->key) finish(job, QString(), /*cancelled=*/true);
    }
    c->current = 0;
    c->currentDone = 0.0;
    emit collectionChanged(c->key);
    pumpCollections();
}

QVariantMap Downloader::collectionState(const QString &kind, const QString &id) const {
    const Collection *c = findCollection(keyOf(kind, id));
    if (!c) return {{QStringLiteral("state"), QStringLiteral("idle")}};
    const int total = int(c->tracks.size());
    const int ended = c->saved + c->failed;
    return {
        {QStringLiteral("state"),     c->state},
        {QStringLiteral("total"),     total},
        {QStringLiteral("saved"),     c->saved},
        {QStringLiteral("failed"),    c->failed},
        {QStringLiteral("position"),  qMin(total, ended + 1)},
        {QStringLiteral("progress"),  total > 0 ? qBound(0.0, (ended + c->currentDone) / total, 1.0) : 0.0},
        {QStringLiteral("pauseSecs"), c->pauseSecs},
        {QStringLiteral("error"),     c->error},
        {QStringLiteral("folder"),    c->folder},
    };
}

// The first run not yet ended goes; the others wait their turn.
void Downloader::pumpCollections() {
    for (Collection *c : std::as_const(m_collections)) {
        if (c->state == kRunning) { stepCollection(c); return; }
        if (c->state == kWaiting) {
            c->state = kRunning;
            emit collectionChanged(c->key);
            stepCollection(c);
            return;
        }
    }
}

QString Downloader::collectionFileName(const Collection *c, const QVariantMap &track) const {
    const QString title  = track.value(QStringLiteral("title")).toString();
    const QString artist = track.value(QStringLiteral("artists")).toString();
    if (c->kind != QLatin1String("album"))
        return sanitizeFilename(artist.isEmpty() ? title : artist + QStringLiteral(" - ") + title);
    bool discs = false;
    for (const QVariant &t : c->tracks)
        if (t.toMap().value(QStringLiteral("volumeNumber")).toInt() > 1) { discs = true; break; }
    QString number = QStringLiteral("%1").arg(track.value(QStringLiteral("trackNumber")).toInt(),
                                             2, 10, QLatin1Char('0'));
    if (discs)
        number = QString::number(qMax(1, track.value(QStringLiteral("volumeNumber")).toInt()))
               + QLatin1Char('-') + number;
    return sanitizeFilename(number + QLatin1Char(' ') + title);
}

// One track at a time, each stream request at least m_spacingMs after the
// last, and none while Tidal holds the endpoint: a long playlist must not
// spend the account's playback budget.
void Downloader::stepCollection(Collection *c) {
    if (c->current) return;
    while (c->next < c->tracks.size()) {
        const QVariantMap track = c->tracks.at(c->next).toMap();
        const qlonglong id = track.value(QStringLiteral("id")).toLongLong();
        const QString base = collectionFileName(c, track);
        const QString path = QDir(c->folder).filePath(base + QStringLiteral(".flac"));
        if (QFileInfo::exists(path)) {           // saved by an earlier run
            if (id > 0) m_saved.insert(id, path);
            ++c->saved;
            ++c->next;
            continue;
        }
        if (id <= 0 || m_jobs.contains(id)) {
            ++c->failed;
            ++c->next;
            continue;
        }
        const int held = m_client->streamRequestsHeldFor(AudioQuality::HiResLossless);
        if (held > 0) { pauseCollections(held); return; }
        if (m_lastStreamRequest.isValid() && m_lastStreamRequest.elapsed() < m_spacingMs) {
            if (!m_stepPending) {
                m_stepPending = true;
                QTimer::singleShot(int(m_spacingMs - m_lastStreamRequest.elapsed()), this, [this] {
                    m_stepPending = false;
                    pumpCollections();
                });
            }
            return;
        }
        DownloadJob *job = makeJob(track, path, QStringLiteral("flac"));
        job->writePath     = QDir(c->folder).filePath(base + QStringLiteral(".part.flac"));
        job->collectionKey = c->key;
        c->current     = id;
        c->currentDone = 0.0;
        m_jobs.insert(id, job);
        m_lastStreamRequest.start();
        emit downloadStarted(id);
        emit collectionChanged(c->key);
        startManifest(job);
        return;
    }
    endCollection(c, kDone);
}

void Downloader::collectionTrackEnded(const QString &key, qlonglong id, bool ok,
                                      const QString &err, int rateLimitedSecs) {
    Collection *c = findCollection(key);
    if (!c || c->current != id) return;      // cancelled: cancelCollection() says so
    c->current = 0;
    c->currentDone = 0.0;
    if (ok) {
        ++c->saved;
        ++c->next;
    } else if (rateLimitedSecs > 0) {
        // Stopped, not skipped: the track goes again when the run does.
        pauseCollections(rateLimitedSecs);
        return;
    } else {
        ++c->failed;
        ++c->next;
        c->error = err;
    }
    emit collectionChanged(key);
    // A turn later: finish() is still on the stack.
    QTimer::singleShot(0, this, [this] { pumpCollections(); });
}

// Tidal asked for a pause: every run stops, and none asks again by itself.
void Downloader::pauseCollections(int secs) {
    for (Collection *c : std::as_const(m_collections)) {
        if (c->state != kWaiting && c->state != kRunning) continue;
        c->state     = kPaused;
        c->pauseSecs = secs;
        emit collectionChanged(c->key);
    }
}

void Downloader::endCollection(Collection *c, const QString &state) {
    c->state = state;
    emit collectionChanged(c->key);
    pumpCollections();
}

QString Downloader::folder() const {
    const QString dir = QSettings().value(kFolderKey).toString();
    if (!dir.isEmpty() && QDir(dir).exists()) return dir;
    const QString music = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
    return music.isEmpty() ? QDir::homePath() : music;
}

void Downloader::setFolder(const QString &dir) {
    if (dir.isEmpty()) return;
    const QString clean = QDir::cleanPath(dir);
    const QString before = folder();
    QSettings().setValue(kFolderKey, clean);
    if (folder() != before) emit folderChanged();
}

void Downloader::chooseFolder() {
    QTimer::singleShot(0, this, [this] {
        const QString dir = QFileDialog::getExistingDirectory(nullptr, tr("Download folder"), folder());
        if (!dir.isEmpty()) setFolder(dir);
    });
}

QString Downloader::savedPath(qlonglong id) const {
    const QString path = m_saved.value(id);
    return (!path.isEmpty() && QFileInfo::exists(path)) ? path : QString();
}

// Each desktop's own way to point at a file. Where none answers, the folder
// opens with nothing selected.
void Downloader::showInFolder(const QString &path) {
    const QFileInfo info(path);
    if (path.isEmpty() || !info.exists()) return;
    const QUrl folderUrl = QUrl::fromLocalFile(info.absolutePath());
#if defined(Q_OS_WIN)
    if (QProcess::startDetached(QStringLiteral("explorer.exe"),
            { QStringLiteral("/select,") + QDir::toNativeSeparators(info.absoluteFilePath()) }))
        return;
    QDesktopServices::openUrl(folderUrl);
#elif defined(Q_OS_MACOS)
    if (QProcess::startDetached(QStringLiteral("open"),
            { QStringLiteral("-R"), info.absoluteFilePath() }))
        return;
    QDesktopServices::openUrl(folderUrl);
#elif defined(Q_OS_LINUX) || defined(Q_OS_FREEBSD)
    // org.freedesktop.FileManager1, which Dolphin, Nautilus, Nemo, Thunar
    // and others implement. Asked async, so a missing one never blocks.
    QDBusMessage call = QDBusMessage::createMethodCall(
        QStringLiteral("org.freedesktop.FileManager1"), QStringLiteral("/org/freedesktop/FileManager1"),
        QStringLiteral("org.freedesktop.FileManager1"), QStringLiteral("ShowItems"));
    call << QStringList{ QUrl::fromLocalFile(info.absoluteFilePath()).toString() } << QString();
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected()) { QDesktopServices::openUrl(folderUrl); return; }
    auto *watcher = new QDBusPendingCallWatcher(bus.asyncCall(call, 5000), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [folderUrl](QDBusPendingCallWatcher *w) {
        if (QDBusPendingReply<>(*w).isError()) QDesktopServices::openUrl(folderUrl);
        w->deleteLater();
    });
#else
    QDesktopServices::openUrl(folderUrl);
#endif
}
