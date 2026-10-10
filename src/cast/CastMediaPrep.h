// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QString>

class TidalClient;
class QProcess;
class QNetworkReply;
class DashFetcher;
// Declared in its namespace: TidalClient.h carries a `using namespace Tidal;`,
// so a second global StreamManifest here is ambiguous in every translation
// unit that includes both.
namespace Tidal { struct StreamManifest; }

// Produces a Chromecast-friendly local audio file for a track. AAC tiers are
// served as fetched; FLAC tiers are remuxed to .flac and downsampled to the
// receiver's 96 kHz limit. Emits ready() once per prepare(), or failed().
class CastMediaPrep : public QObject {
    Q_OBJECT
public:
    explicit CastMediaPrep(TidalClient *client, QObject *parent = nullptr);
    ~CastMediaPrep() override;

    void prepare(qlonglong trackId);

    // Everything prepare() does once a manifest is in hand. Needs no Tidal
    // session, so a test can drive it with a manifest of known shape.
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
    // DASH is joined out of its segments by DashFetcher.
    QString        m_inputPath;
    QString        m_outputPath;   // temp output (flac)
    qlonglong      m_trackId  = 0;
    quint64        m_gen      = 0; // bumped per prepare()/cancel() to drop stale callbacks
};
