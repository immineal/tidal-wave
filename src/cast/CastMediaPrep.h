#pragma once
#include <QObject>
#include <QString>

class TidalClient;
class QProcess;
class QNetworkReply;
class DashFetcher;
// In its own namespace, not the global one: TidalClient.h carries a
// `using namespace Tidal;`, so a second global StreamManifest here is ambiguous
// in every translation unit that includes both.
namespace Tidal { struct StreamManifest; }

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

    // Everything prepare() does once a manifest is in hand. Split out because
    // this is the half that does the work - the DASH join and the ffmpeg remux -
    // and the half that needs no Tidal session to drive, so it can be measured
    // against a manifest of known shape. prepare() is the app's only caller.
    void prepareFromManifest(const Tidal::StreamManifest &manifest);

    void cancel();

signals:
    void ready(const QString &path, const QString &mime);
    void failed(const QString &msg);

private:
    void remuxFlac(int sampleRate);
    void cleanupInput();

    TidalClient   *m_client  = nullptr;
    QNetworkReply *m_reply   = nullptr;
    DashFetcher   *m_dash    = nullptr; // active DASH segment join (lossless)
    QProcess      *m_ffmpeg  = nullptr;
    // Always a plain .mp4 by the time ffmpeg sees it: BTS downloads one, and
    // DASH is joined out of its segments by DashFetcher. It used to be able to
    // be a .mpd manifest, which is what remuxFlac()'s -protocol_whitelist
    // argument was for.
    QString        m_inputPath;
    QString        m_outputPath;   // temp output (flac)
    qlonglong      m_trackId  = 0;
    quint64        m_gen      = 0; // bumped per prepare()/cancel() to drop stale callbacks
};
