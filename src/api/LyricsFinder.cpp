// SPDX-License-Identifier: GPL-3.0-or-later

#include "LyricsFinder.h"
#include "ui/UpdateCheck.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSaveFile>
#include <QRandomGenerator>
#include <QStandardPaths>
#include <algorithm>

// ── transport ───────────────────────────────────────────────────────────────

int NetworkLyricsTransport::get(const QUrl &url, Done done) {
    if (!m_nam) m_nam = new QNetworkAccessManager(this);
    QNetworkRequest req(url);
    req.setRawHeader("User-Agent", UpdateCheck::userAgent());
    req.setRawHeader("Accept", "application/json, text/html;q=0.9");
    req.setTransferTimeout(15000);
    QNetworkReply *reply = m_nam->get(req);
    const int handle = m_nextHandle++;
    m_replies.insert(handle, reply);
    connect(reply, &QNetworkReply::finished, this, [this, reply, handle, done = std::move(done)] {
        reply->deleteLater();
        if (!m_replies.contains(handle)) return;
        m_replies.remove(handle);
        LyricsReply r;
        r.status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        r.body = reply->read(8 * 1024 * 1024);
        r.retryAfter = reply->rawHeader("Retry-After");
        done(r);
    });
    return handle;
}

void NetworkLyricsTransport::abort(int handle) {
    const QPointer<QNetworkReply> reply = m_replies.take(handle);
    if (reply) reply->abort();
}

// ── pacing ──────────────────────────────────────────────────────────────────

bool HostPacing::blocked(const QString &host, qint64 now) const {
    return now < m_hosts.value(host).blockedUntil;
}

qint64 HostPacing::waitMs(const QString &host, qint64 now) const {
    const Host h = m_hosts.value(host);
    if (h.lastSent < 0) return 0;
    return std::max<qint64>(0, h.lastSent + kMinIntervalMs - now);
}

bool HostPacing::busy(const QString &host) const { return m_hosts.value(host).busy; }

void HostPacing::sent(const QString &host, qint64 now) {
    Host &h = m_hosts[host];
    h.lastSent = now;
    h.busy = true;
}

void HostPacing::answered(const QString &host) { m_hosts[host].busy = false; }

void HostPacing::refused(const QString &host, qint64 now, const QByteArray &retryAfter) {
    Host &h = m_hosts[host];
    h.busy = false;
    qint64 pause = -1;
    const QByteArray ra = retryAfter.trimmed();
    if (!ra.isEmpty()) {
        bool ok = false;
        const qint64 secs = ra.toLongLong(&ok);
        if (ok && secs >= 0) {
            pause = secs * 1000;
        } else {
            // HTTP dates end in "GMT", which Qt's RFC 2822 parser refuses.
            QString date = QString::fromLatin1(ra);
            if (date.endsWith(QLatin1String(" GMT"))) {
                date.chop(3);
                date += QStringLiteral("+0000");
            }
            const QDateTime at = QDateTime::fromString(date, Qt::RFC2822Date);
            if (at.isValid()) pause = std::max<qint64>(0, at.toMSecsSinceEpoch() - now);
        }
    }
    if (pause < 0) pause = kFirstBackoffMs << std::min(h.strikes, 6);
    ++h.strikes;
    const double j = m_jitter ? m_jitter() : QRandomGenerator::global()->generateDouble();
    pause += qint64(double(pause) * kMaxJitter * std::clamp(j, 0.0, 1.0));
    h.blockedUntil = now + std::min(pause, kMaxBackoffMs);
}

qint64 HostPacing::blockedUntil(const QString &host) const {
    return m_hosts.value(host).blockedUntil;
}

// ── cache ───────────────────────────────────────────────────────────────────

QString LyricsCache::defaultDir() {
    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
           + QStringLiteral("/lyrics");
}

QString LyricsCache::path(qint64 trackId) const {
    return m_dir + u'/' + QString::number(trackId) + QStringLiteral(".json");
}

LyricsCache::Hit LyricsCache::lookup(qint64 trackId, qint64 now, LyricsResult *out) const {
    QFile f(path(trackId));
    if (!f.open(QIODevice::ReadOnly)) return Hit::None;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    if (o.isEmpty()) return Hit::None;
    if (o.value(QStringLiteral("instrumental")).toBool()) {
        out->instrumental = true;
        return Hit::Instrumental;
    }
    if (!o.value(QStringLiteral("found")).toBool()) {
        const qint64 at = qint64(o.value(QStringLiteral("at")).toDouble());
        return (at <= now && now - at < kMissTtlMs) ? Hit::Miss : Hit::None;
    }
    out->text = o.value(QStringLiteral("text")).toString();
    out->timed = o.value(QStringLiteral("timed")).toBool();
    out->source = o.value(QStringLiteral("source")).toString();
    out->url = QUrl(o.value(QStringLiteral("url")).toString());
    return out->text.isEmpty() ? Hit::None : Hit::Found;
}

void LyricsCache::write(qint64 trackId, const QByteArray &json) const {
    QDir().mkpath(m_dir);
    QSaveFile f(path(trackId));
    if (!f.open(QIODevice::WriteOnly)) return;
    f.write(json);
    f.commit();
}

void LyricsCache::storeFound(qint64 trackId, const LyricsResult &r, qint64 now) const {
    QJsonObject o{{QStringLiteral("found"), true}, {QStringLiteral("text"), r.text},
                  {QStringLiteral("timed"), r.timed}, {QStringLiteral("source"), r.source},
                  {QStringLiteral("url"), r.url.toString()}, {QStringLiteral("at"), double(now)}};
    write(trackId, QJsonDocument(o).toJson(QJsonDocument::Compact));
}

void LyricsCache::storeInstrumental(qint64 trackId, qint64 now) const {
    QJsonObject o{{QStringLiteral("found"), false}, {QStringLiteral("instrumental"), true},
                  {QStringLiteral("at"), double(now)}};
    write(trackId, QJsonDocument(o).toJson(QJsonDocument::Compact));
}

void LyricsCache::storeMiss(qint64 trackId, qint64 now) const {
    QJsonObject o{{QStringLiteral("found"), false}, {QStringLiteral("at"), double(now)}};
    write(trackId, QJsonDocument(o).toJson(QJsonDocument::Compact));
}

// ── finder ──────────────────────────────────────────────────────────────────

LyricsFinder::LyricsFinder(QObject *parent)
    : QObject(parent)
    , m_enabled([] { return false; })
    , m_now([] { return QDateTime::currentMSecsSinceEpoch(); })
    , m_providers(lyrics::defaultProviders())
{
    m_timer.setSingleShot(true);
    connect(&m_timer, &QTimer::timeout, this, &LyricsFinder::onTimer);
}

LyricsFinder::~LyricsFinder() = default;

LyricsTransport *LyricsFinder::transport() {
    if (!m_transport) m_transport = new NetworkLyricsTransport(this);
    return m_transport;
}

LyricsCache &LyricsFinder::cache() {
    if (!m_cache) m_cache = std::make_unique<LyricsCache>(LyricsCache::defaultDir());
    return *m_cache;
}

void LyricsFinder::find(const LyricsQuery &q, Done done) {
    cancel();
    if (!m_enabled()) { done({}, QStringLiteral("off")); return; }
    if (q.trackId <= 0 || q.title.isEmpty() || q.artists.isEmpty()) { done({}, {}); return; }

    LyricsResult cached;
    switch (cache().lookup(q.trackId, m_now(), &cached)) {
    case LyricsCache::Hit::Found:
    case LyricsCache::Hit::Instrumental: done(cached, {}); return;
    case LyricsCache::Hit::Miss:  done({}, {}); return;
    case LyricsCache::Hit::None:  break;
    }

    m_active = true;
    m_settled = false;
    m_incomplete = false;
    m_providerIdx = 0;
    m_step = LyricsStep::miss();
    m_query = q;
    m_done = std::move(done);
    m_timer.start(m_settleMs);
}

void LyricsFinder::cancel() {
    ++m_gen;
    m_timer.stop();
    if (m_handle >= 0) {
        if (m_transport) m_transport->abort(m_handle);
        m_pacing.answered(m_host);
        m_handle = -1;
    }
    m_active = false;
    m_done = nullptr;
}

void LyricsFinder::onTimer() {
    if (!m_active) return;
    m_settled = true;
    advance();
}

void LyricsFinder::nextProvider() {
    ++m_providerIdx;
    m_step = LyricsStep::miss();
}

void LyricsFinder::advance() {
    if (!m_active || !m_settled || m_handle >= 0) return;
    if (!m_enabled()) { finish({}, QStringLiteral("off"), false); return; }
    for (;;) {
        if (m_step.kind != LyricsStep::Request) {
            if (m_providerIdx >= m_providers.size()) { finish({}, {}, !m_incomplete); return; }
            m_step = m_providers.at(m_providerIdx)->start(m_query);
            if (m_step.kind != LyricsStep::Request) { nextProvider(); continue; }
        }
        const QString host = m_step.url.host();
        const qint64 now = m_now();
        if (m_pacing.blocked(host, now)) {
            m_incomplete = true;
            nextProvider();
            continue;
        }
        const qint64 wait = m_pacing.waitMs(host, now);
        if (wait > 0) { m_timer.start(int(wait)); return; }

        m_pacing.sent(host, now);
        m_host = host;
        const quint64 gen = m_gen;
        // Queued, so a transport that answers inside get() cannot re-enter.
        m_handle = transport()->get(m_step.url, [this, gen](const LyricsReply &r) {
            QMetaObject::invokeMethod(this, [this, gen, r] { onReply(gen, r); },
                                      Qt::QueuedConnection);
        });
        return;
    }
}

void LyricsFinder::onReply(quint64 gen, const LyricsReply &reply) {
    if (gen != m_gen || !m_active) return;
    m_handle = -1;
    m_pacing.answered(m_host);
    const int s = reply.status;
    if (s == 429 || s == 403 || s == 503 || lyrics::looksLikeChallenge(reply.body)) {
        m_pacing.refused(m_host, m_now(), reply.retryAfter);
        m_incomplete = true;
        nextProvider();
        advance();
        return;
    }
    if (s == 0) {
        m_incomplete = true;
        nextProvider();
        advance();
        return;
    }
    const LyricsStep step = m_providers.at(m_providerIdx)->next(m_query, m_step, reply);
    switch (step.kind) {
    case LyricsStep::Found:
        cache().storeFound(m_query.trackId, step.result, m_now());
        finish(step.result, {}, false);
        return;
    case LyricsStep::Instrumental: {
        cache().storeInstrumental(m_query.trackId, m_now());
        LyricsResult r;
        r.instrumental = true;
        r.source = m_providers.at(m_providerIdx)->name();
        finish(r, {}, false);
        return;
    }
    case LyricsStep::Failed:
        m_incomplete = true;
        [[fallthrough]];
    case LyricsStep::Miss:
        nextProvider();
        break;
    case LyricsStep::Request:
        m_step = step;
        break;
    }
    advance();
}

void LyricsFinder::finish(const LyricsResult &r, const QString &err, bool cacheMiss) {
    if (cacheMiss) cache().storeMiss(m_query.trackId, m_now());
    Done done = std::move(m_done);
    m_active = false;
    m_done = nullptr;
    m_timer.stop();
    if (done) done(r, err);
}
