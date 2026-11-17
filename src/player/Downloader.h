// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QElapsedTimer>
#include <QHash>
#include <QList>
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

    // A whole album or playlist (`kind` "album" or "playlist"), saved as FLAC
    // into a folder named after it. Asks for the parent folder once; a run
    // that stopped goes on in the same folder without asking.
    Q_INVOKABLE void downloadCollection(const QString &kind, const QString &id,
                                        const QString &title, const QVariantList &tracks);
    Q_INVOKABLE void cancelCollection(const QString &kind, const QString &id);
    // {state, total, saved, failed, position, progress, pauseSecs, error,
    // folder}; state is idle, waiting, running, done, cancelled or paused.
    Q_INVOKABLE QVariantMap collectionState(const QString &kind, const QString &id) const;
    // downloadCollection() once the parent folder is known. Public for the tests.
    void downloadCollectionInto(const QString &kind, const QString &id, const QString &title,
                                const QVariantList &tracks, const QString &parentDir);
    // The least time between two stream requests of a collection run: at
    // most three a minute, well inside what Tidal allows for playback.
    static constexpr int kCollectionSpacingMs = 20000;
    void setCollectionSpacingMs(int ms) { m_spacingMs = ms; }   // for the tests

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
    // The user stopped it; no error to show.
    void downloadCancelled(qlonglong id);
    // Anything collectionState() reports for this "kind:id" changed.
    void collectionChanged(const QString &key);

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
        QString   writePath;         // where ffmpeg writes; moved to targetPath after
        QString   collectionKey;     // the album or playlist run it belongs to, or ""
        int       rateLimitedSecs = 0;  // Tidal's 429 wait, when that ended it
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
    // Emits, cleans up temp files, deletes job.
    void finish(DownloadJob *job, const QString &err, bool cancelled = false);
    static QString sanitizeFilename(QString name);
    DownloadJob *makeJob(const QVariantMap &track, const QString &path, const QString &format);

    struct Collection {
        QString key, kind, title, folder;
        QVariantList tracks;
        QString state = QStringLiteral("waiting");
        int next = 0;                // the track to start next
        int saved = 0, failed = 0;
        qlonglong current = 0;       // the track downloading now, 0 for none
        double currentDone = 0.0;    // how far into it, 0 to 1
        int pauseSecs = 0;
        QString error;               // the last track's failure
    };
    void pumpCollections();
    void stepCollection(Collection *c);
    Collection *findCollection(const QString &key) const;
    void collectionTrackEnded(const QString &key, qlonglong id, bool ok, const QString &err,
                              int rateLimitedSecs);
    void pauseCollections(int secs);
    void endCollection(Collection *c, const QString &state);
    QString collectionFileName(const Collection *c, const QVariantMap &track) const;

    TidalClient *m_client;
    QHash<qlonglong, DownloadJob*> m_jobs;
    QHash<qlonglong, QString> m_saved;   // track id to the file it was saved as
    // Runs in the order asked for; only the first waiting or running one
    // goes, so two collections never spend Tidal's stream budget at once.
    QList<Collection*> m_collections;
    QElapsedTimer m_lastStreamRequest;
    int  m_spacingMs = kCollectionSpacingMs;
    bool m_stepPending = false;
};
