// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QHash>
#include <QString>
#include <QVariantMap>
#include "TidalClient.h"

class QNetworkReply;
class QProcess;
class QTemporaryFile;
class DashFetcher;

// Downloads one track at the highest available quality and converts it with
// ffmpeg to FLAC, MP3 or WAV. Runs on the GUI thread; every async callback
// looks its DownloadJob up again by track id and bails if it was cancelled.
class Downloader : public QObject {
    Q_OBJECT
    // Where the save dialog opens: set in Settings, and moved by a save made
    // elsewhere. The last folder used, else Music, else home.
    Q_PROPERTY(QString folder READ folder WRITE setFolder NOTIFY folderChanged)
public:
    explicit Downloader(TidalClient *client, QObject *parent = nullptr);
    ~Downloader() override;

    // Opens a native save dialog, then downloads/converts in the background.
    Q_INVOKABLE void downloadTrack(const QVariantMap &track);
    Q_INVOKABLE bool isDownloading(qlonglong id) const { return m_jobs.contains(id); }
    Q_INVOKABLE void cancelDownload(qlonglong id);

    QString folder() const;
    void setFolder(const QString &dir);
    // A folder picker, deferred like the save dialog; a pick sets `folder`.
    Q_INVOKABLE void chooseFolder();

    // The file saved for this track since launch, or "" once it is gone.
    Q_INVOKABLE QString savedPath(qlonglong id) const;
    // Opens the file manager on the file's folder with the file selected.
    Q_INVOKABLE void showInFolder(const QString &path);

    // Where ffmpeg is right now, or empty. Looked up on every call.
    // Public for the tests.
    QString ffmpegPath() const;

    // The two halves of that lookup; `extraDirs` is searched after PATH.
    static QStringList ffmpegFallbackDirs();
    static QString     resolveFfmpeg(const QStringList &extraDirs);

signals:
    void folderChanged();
    void downloadStarted(qlonglong id);
    void downloadFinished(qlonglong id, const QString &path);
    void downloadError(qlonglong id, const QString &msg);

private:
    struct DownloadJob {
        qlonglong id = 0;
        QString   title;
        QString   artist;
        QString   album;
        int       trackNumber = 0;
        QString   coverArtUrl;       // 1280px cover URL, empty if none
        double    replayGainTrack = 0.0;
        double    replayGainAlbum = 0.0;

        QString   targetPath;        // final output file chosen by the user
        QString   format;            // "flac" | "mp3" | "wav"

        QString   srcTier;           // delivered tier: LOW/HIGH/LOSSLESS/HI_RES_LOSSLESS
        int       sampleRate = 44100;
        int       bitDepth   = 16;

        // Always a plain .mp4 by the time ffmpeg sees it: BTS downloads one, and
        // DASH is joined out of its segments by DashFetcher.
        QString   audioTempPath;
        QString   coverTempPath;     // downloaded cover (.jpg), empty if none

        QNetworkReply *reply  = nullptr;  // active network fetch (audio or cover)
        DashFetcher   *dash   = nullptr;  // active DASH segment join (lossless)
        QProcess      *ffmpeg = nullptr;  // active conversion
        bool      flacCopyTried = false;  // FLAC: tried `-c:a copy`, may retry with `-c:a flac`
    };

    void startManifest(DownloadJob *job);
    void handleBts(DownloadJob *job, const QString &url);
    void handleMpd(DownloadJob *job, const QString &mpdXml);
    void fetchCoverThenConvert(DownloadJob *job);
    void runFfmpeg(DownloadJob *job, bool flacForceEncode = false);
    QStringList ffmpegArgs(const DownloadJob *job, bool flacForceEncode) const;
    void finish(DownloadJob *job, const QString &err);   // emits, cleans up temp files, deletes job
    static QString sanitizeFilename(QString name);

    TidalClient *m_client;
    QHash<qlonglong, DownloadJob*> m_jobs;
    QHash<qlonglong, QString> m_saved;   // track id to the file it was saved as
};
