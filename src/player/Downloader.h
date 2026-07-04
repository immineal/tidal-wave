#pragma once
#include <QObject>
#include <QHash>
#include <QString>
#include <QVariantMap>
#include "TidalClient.h"

class QNetworkReply;
class QProcess;

// Downloads a single track at the highest available quality and converts it to
// a user-chosen format (FLAC / MP3 / WAV) with ffmpeg, embedding tags and (for
// FLAC/MP3) the album cover. Exposed to QML as the `downloader` context property.
//
// The whole flow runs on the GUI thread: the network fetches (TidalClient) and
// the ffmpeg QProcess are asynchronous, and the native save dialog spins a
// nested event loop, so nothing blocks. Each in-flight download is a DownloadJob
// kept in m_jobs keyed by track id; every async callback re-looks-up its job by
// id and bails if it has been cancelled (mirrors Player's loadingTrackId guard).
class Downloader : public QObject {
    Q_OBJECT
public:
    explicit Downloader(TidalClient *client, QObject *parent = nullptr);
    ~Downloader() override;

    // Opens a native save dialog, then downloads/converts in the background.
    Q_INVOKABLE void downloadTrack(const QVariantMap &track);
    Q_INVOKABLE bool isDownloading(qlonglong id) const { return m_jobs.contains(id); }
    Q_INVOKABLE void cancelDownload(qlonglong id);

signals:
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
        bool      isMpd      = false;

        QString   audioTempPath;     // downloaded BTS bytes (.mp4) or DASH manifest (.mpd)
        QString   coverTempPath;     // downloaded cover (.jpg), empty if none

        QNetworkReply *reply  = nullptr;  // active network fetch (audio or cover)
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
    QString m_ffmpegPath;            // resolved ffmpeg executable, empty if not found
};
