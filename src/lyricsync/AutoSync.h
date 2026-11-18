// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>
#include <QThread>
#include <atomic>
#include <functional>
#include <list>
#include <memory>

namespace lyricsync {

struct Analysis;
class Models;

// Times plain lyrics against a track's audio file, on one low-priority
// worker thread. The audio part runs once per track and is kept for a few
// tracks; results are cached on disk next to the lyrics.
class AutoSync : public QObject {
    Q_OBJECT
public:
    struct Result {
        bool ok = false;          // an alignment was made
        bool kept = false;        // confident enough to show
        double confidence = 0;
        QString lrc;              // [mm:ss.xx]line per sung line
        QString error;
    };
    using Done = std::function<void(const Result &)>;

    static constexpr int kKeptAnalyses = 3;
    // Longer audio is not analysed: a mix or a whole album side.
    static constexpr int kMaxSeconds = 25 * 60;

    explicit AutoSync(QObject *parent = nullptr);
    ~AutoSync() override;

    // The track's audio on disk, or "" when there is none yet.
    void setAudioSource(std::function<QString(qint64 trackId)> pathFor) { m_pathFor = std::move(pathFor); }
    // Called around the worker's use of a file, so its owner does not delete it meanwhile.
    void setFileHold(std::function<void(const QString &)> hold, std::function<void(const QString &)> release);
    void setEnabled(std::function<bool()> on) { m_enabled = std::move(on); }
    // Whether a track already has real timings somewhere cheap to ask, such
    // as the lyrics-site cache; such a track is not analysed ahead.
    void setHasTimings(std::function<bool(qint64 trackId)> has) { m_hasTimings = std::move(has); }
    // Tidal gave synced lyrics for the track: no look-ahead for it this run.
    void noteRealTimings(qint64 trackId);
    void setCacheDir(const QString &dir) { m_cacheDir = dir; }
    // Default: the built-in ones, loaded on the worker at first use.
    void setModels(std::shared_ptr<const Models> m);

    // `done` comes once, on this object's thread, unless a newer sync() or
    // cancel() comes first. It waits for the audio when there is none yet.
    // A newer sync() or cancel() also stops the older track's analysis,
    // unless that track is the next one, analysed ahead.
    void sync(qint64 trackId, const QString &plainText, Done done);
    void cancel();
    // Analyse the next track's audio as soon as it is on disk.
    void setLookAhead(bool on);
    bool lookAhead() const { return m_lookAhead; }
    // The track's audio is on disk now; `ahead` for the next track's. A track
    // whose analysis failed for a passing reason is tried again then.
    void audioReady(qint64 trackId, bool ahead);

    QString cacheFile(qint64 trackId) const;
    bool hasAnalysisForTest(qint64 trackId) const;
    bool busyForTest() const { return m_analysing != 0 || m_aligning; }
    void setMaxSecondsForTest(int s) { m_maxSeconds = s; }
    // A failure that may pass (no file yet, a stalled decoder) is retried on
    // the track's next audio, or after kRetryMs while a sync() waits for it,
    // this many times in all.
    static constexpr int kMaxTries = 3;
    static constexpr int kRetryMs = 10000;
    void setRetryMsForTest(int ms) { m_retryMs = ms; }

signals:
    void analysed(qint64 trackId, bool ok);

private:
    enum class Outcome { Ok, Cancelled, Transient, Permanent, TooLong };
    struct Pending { qint64 trackId = 0; QString text; Done done; quint64 gen = 0; };
    struct Failure { bool permanent = false; int tries = 0; bool armed = false; QString error; };
    struct Kept { qint64 trackId; std::shared_ptr<const Analysis> a; };

    void pump();
    void startAnalysis(qint64 trackId, const QString &path);
    void onAnalysed(qint64 trackId, const QString &path, std::shared_ptr<const Analysis> a, const QString &err,
                    Outcome outcome);
    void dropPending();
    bool blocked(qint64 trackId) const;
    bool skipAhead(qint64 trackId) const;
    bool cachedSync(qint64 trackId) const;
    void writeTooLong(qint64 trackId) const;
    void onAligned(qint64 trackId, quint64 gen, const Result &r);
    void retry(qint64 trackId);
    std::shared_ptr<const Analysis> analysisFor(qint64 trackId);
    bool readCache(qint64 trackId, const QString &text, Result *out) const;

    QThread  m_thread;
    QObject *m_worker = nullptr;          // lives on m_thread
    std::shared_ptr<std::atomic<bool>> m_stop;     // raised on destruction
    std::shared_ptr<std::atomic<bool>> m_jobStop;  // the analysis under way
    std::shared_ptr<std::shared_ptr<const Models>> m_models;   // touched on the worker only

    std::function<QString(qint64)> m_pathFor;
    std::function<void(const QString &)> m_hold, m_release;
    std::function<bool()> m_enabled;
    std::function<bool(qint64)> m_hasTimings;
    QString m_cacheDir;

    Pending m_pending;
    quint64 m_gen = 0;
    bool    m_lookAhead = false;
    qint64  m_aheadId = 0;
    bool    m_aheadSkip = false;
    int     m_maxSeconds = kMaxSeconds;
    int     m_retryMs = kRetryMs;
    qint64  m_analysing = 0;
    bool    m_aligning = false;
    QHash<qint64, Failure> m_failed;
    QSet<qint64> m_realTimings;           // from noteRealTimings()
    std::list<Kept> m_kept;               // most recent first
};

} // namespace lyricsync
