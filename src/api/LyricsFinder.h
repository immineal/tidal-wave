// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QHash>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <functional>
#include <memory>

#include "LyricsProviders.h"

class QNetworkAccessManager;
class QNetworkReply;

// The only door to the lyrics sites. Replaced by a fake in tests.
class LyricsTransport : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    using Done = std::function<void(const LyricsReply &)>;
    // Returns a handle for abort(). `done` is never called after abort().
    virtual int  get(const QUrl &url, Done done) = 0;
    virtual void abort(int handle) = 0;
};

class NetworkLyricsTransport : public LyricsTransport {
    Q_OBJECT
public:
    using LyricsTransport::LyricsTransport;
    int  get(const QUrl &url, Done done) override;
    void abort(int handle) override;
    bool hasNetwork() const { return m_nam != nullptr; }

private:
    QNetworkAccessManager *m_nam = nullptr;
    QHash<int, QPointer<QNetworkReply>> m_replies;
    int m_nextHandle = 1;
};

// Per host: a minimum gap between requests, and a pause after a refusal.
class HostPacing {
public:
    static constexpr qint64 kMinIntervalMs  = 1000;
    static constexpr double kMaxJitter      = 0.3;
    static constexpr qint64 kFirstBackoffMs = 15 * 60 * 1000;
    static constexpr qint64 kMaxBackoffMs   = 24 * 60 * 60 * 1000;

    bool   blocked(const QString &host, qint64 now) const;
    // How long until a request may go, 0 when it may go now.
    qint64 waitMs(const QString &host, qint64 now) const;
    bool   busy(const QString &host) const;
    void   sent(const QString &host, qint64 now);
    void   answered(const QString &host);
    // Retry-After is honoured, as seconds or an HTTP date. Without one the
    // pause doubles from kFirstBackoffMs with each refusal. Either way up to
    // kMaxJitter of it is added, so clients do not come back in step.
    void   refused(const QString &host, qint64 now, const QByteArray &retryAfter);
    qint64 blockedUntil(const QString &host) const;
    // Returns [0, 1). Replaced in tests.
    void   setJitter(std::function<double()> j) { m_jitter = std::move(j); }

private:
    std::function<double()> m_jitter;
    struct Host { qint64 lastSent = -1; qint64 blockedUntil = 0; int strikes = 0; bool busy = false; };
    QHash<QString, Host> m_hosts;
};

// One JSON file per Tidal track id. A hit is kept, a miss expires.
class LyricsCache {
public:
    static constexpr qint64 kMissTtlMs = 30LL * 24 * 60 * 60 * 1000;
    enum class Hit { None, Found, Miss, Instrumental };

    explicit LyricsCache(const QString &dir) : m_dir(dir) {}
    static QString defaultDir();

    Hit  lookup(qint64 trackId, qint64 now, LyricsResult *out) const;
    void storeFound(qint64 trackId, const LyricsResult &r, qint64 now) const;
    void storeMiss(qint64 trackId, qint64 now) const;
    void storeInstrumental(qint64 trackId, qint64 now) const;

private:
    QString path(qint64 trackId) const;
    void    write(qint64 trackId, const QByteArray &json) const;
    QString m_dir;
};

class LyricsFinder : public QObject {
    Q_OBJECT
public:
    static constexpr int kSettleMs = 3000;
    // An empty text with an empty error means no site had them.
    using Done = std::function<void(const LyricsResult &, const QString &err)>;

    explicit LyricsFinder(QObject *parent = nullptr);
    ~LyricsFinder() override;

    void setEnabledSource(std::function<bool()> enabled) { m_enabled = std::move(enabled); }
    void setProviders(QList<std::shared_ptr<const LyricsProvider>> p) { m_providers = std::move(p); }
    // Not owned. Without one, a NetworkLyricsTransport is made on first need.
    void setTransport(LyricsTransport *t) { m_transport = t; }
    void setCacheDir(const QString &dir) { m_cache = std::make_unique<LyricsCache>(dir); }
    void setClock(std::function<qint64()> now) { m_now = std::move(now); }
    void setSettleMs(int ms) { m_settleMs = ms; }
    void setJitter(std::function<double()> j) { m_pacing.setJitter(std::move(j)); }

    // A newer find() drops the older one, whose `done` is then never called.
    void find(const LyricsQuery &q, Done done);
    void cancel();

    const HostPacing &pacing() const { return m_pacing; }
    bool hasTransportForTest() const { return m_transport != nullptr; }
    bool timerActiveForTest() const { return m_timer.isActive(); }
    int  timerIntervalForTest() const { return m_timer.interval(); }
    void fireTimerForTest() { m_timer.stop(); onTimer(); }

private:
    void onTimer();
    void advance();
    void nextProvider();
    void onReply(quint64 gen, const LyricsReply &reply);
    void finish(const LyricsResult &r, const QString &err, bool cacheMiss);
    LyricsTransport *transport();
    LyricsCache     &cache();

    std::function<bool()>   m_enabled;
    std::function<qint64()> m_now;
    QList<std::shared_ptr<const LyricsProvider>> m_providers;
    LyricsTransport *m_transport = nullptr;
    std::unique_ptr<LyricsCache> m_cache;
    HostPacing m_pacing;
    QTimer     m_timer;
    int        m_settleMs = kSettleMs;

    quint64     m_gen = 0;
    bool        m_active = false;
    bool        m_settled = false;
    bool        m_incomplete = false;
    int         m_providerIdx = 0;
    int         m_handle = -1;
    QString     m_host;
    LyricsQuery m_query;
    LyricsStep  m_step;
    Done        m_done;
};
