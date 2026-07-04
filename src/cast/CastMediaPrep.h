#pragma once
#include <QObject>
#include <QString>

class TidalClient;
class QProcess;
class QNetworkReply;

// Produces a Chromecast-friendly local audio file for a track (highest quality):
//  - AAC tiers (LOW/HIGH): the fetched MP4 is served as-is (audio/mp4).
//  - FLAC tiers (LOSSLESS/HI_RES): remuxed to native .flac via ffmpeg, and
//    downsampled to <=96 kHz if needed (Chromecast default-receiver FLAC limit).
// Emits ready(path, mime) exactly once per prepare(), or failed(msg).
class CastMediaPrep : public QObject {
    Q_OBJECT
public:
    explicit CastMediaPrep(TidalClient *client, QObject *parent = nullptr);
    ~CastMediaPrep() override;

    void prepare(qlonglong trackId);
    void cancel();

signals:
    void ready(const QString &path, const QString &mime);
    void failed(const QString &msg);

private:
    void remuxFlac(bool isMpd, int sampleRate);
    void cleanupInput();

    TidalClient   *m_client  = nullptr;
    QNetworkReply *m_reply   = nullptr;
    QProcess      *m_ffmpeg  = nullptr;
    QString        m_inputPath;    // temp input (mp4 / mpd)
    QString        m_outputPath;   // temp output (flac)
    qlonglong      m_trackId  = 0;
    quint64        m_gen      = 0; // bumped per prepare()/cancel() to drop stale callbacks
};
