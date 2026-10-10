// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
// Joins the segments of a Tidal DASH manifest (LOSSLESS, HI_RES_LOSSLESS) into
// one fragmented MP4, which any ffmpeg build reads. libavformat's own DASH
// demuxer needs libxml2, and the ffmpeg bundled with the Qt installer has none.
// Header-only and no QObject, so no moc. It reports through a std::function
// and has no tr(): user-visible wording stays with the callers.
#include <QByteArray>
#include <QDebug>
#include <QDir>
#include <QLatin1String>
#include <QNetworkReply>
#include <QPointer>
#include <QString>
#include <QStringList>
#include <QTemporaryFile>
#include <QUrl>
#include <QVector>
#include <QXmlStreamReader>

#include <cmath>
#include <functional>
#include <memory>
#include <utility>

#include "api/TidalClient.h"

class DashFetcher {
public:
    // file is null exactly when the join failed; errorDetail may be empty.
    // Ownership of the file passes to the receiver. It is closed and its
    // autoRemove is off.
    using Done = std::function<void(QTemporaryFile *file, const QString &errorDetail)>;

    // Reported from the event loop each time the front of the file grows.
    // bytesReady is what a second reader of tempFilePath() can see. segmentsReady
    // counts the initialization segment, so 2 is the least that plays.
    using Progress = std::function<void(qint64 bytesReady, int segmentsReady)>;

    // Expands a DASH manifest into the URLs to fetch: [0] is the initialization
    // segment, the rest are the media segments in play order. Empty when the
    // manifest carries no SegmentTemplate this can expand.
    static QStringList parseSegmentUrls(const QString &mpdXml);

    DashFetcher(TidalClient *client, const QString &mpdXml)
        : m_client(client), m_urls(parseSegmentUrls(mpdXml))
    {
        m_parts.resize(m_urls.size());
        if (m_urls.isEmpty()) return;
        // Opened here so every synchronous failure is visible before the caller
        // commits. start() then only reports through the event loop.
        m_file = new QTemporaryFile(QDir::tempPath() + QStringLiteral("/tidal-wave-XXXXXX.mp4"));
        m_file->setAutoRemove(false);
        if (!m_file->open()) {
            delete m_file;
            m_file = nullptr;
        }
    }

    ~DashFetcher()
    {
        // First statement: each abort() below runs the reply's finished handler
        // synchronously, which calls back into the lambda in fetchAt().
        // Expiring the guard first makes that a no-op.
        m_alive.reset();
        for (const QPointer<QNetworkReply> &r : std::as_const(m_inFlight))
            if (!r.isNull()) r->abort();
        if (m_file) { m_file->remove(); delete m_file; }
    }

    DashFetcher(const DashFetcher &) = delete;
    DashFetcher &operator=(const DashFetcher &) = delete;

    // The manifest named at least one segment.
    bool isValid() const { return !m_urls.isEmpty(); }
    // The temp file the segments are joined into could be created.
    bool openedTempFile() const { return m_file != nullptr; }
    // Where the join is going; empty once the file is handed over or given up.
    QString tempFilePath() const { return m_file ? m_file->fileName() : QString(); }
    // Segments including the initialization segment.
    int partCount() const { return int(m_urls.size()); }

    // Bytes of the front of the file on disk. It only ever grows.
    qint64 bytesReady() const { return m_bytesReady; }
    // Segments on disk, counting the initialization segment.
    int segmentsReady() const { return m_writeCursor; }

    // Optional, set before start(). Called from the event loop, and the
    // receiver may delete this fetcher from inside it.
    void setProgress(Progress p) { m_progress = std::move(p); }

    // Call once, only when isValid() && openedTempFile(). done runs exactly
    // once, from the event loop, and never after this object is destroyed.
    void start(Done done)
    {
        m_done = std::move(done);
        for (int i = 0; i < kMaxParallel && m_nextToRequest < m_urls.size(); ++i)
            fetchAt(m_nextToRequest++);
    }

private:
    // ── manifest parsing ────────────────────────────────────────────────────

    // "PT3.0S", "PT3M22.5S", "PT1H2M3S" -> milliseconds; 0 when unusable.
    static qint64 parseIsoDuration(const QString &s)
    {
        const int t = s.indexOf(QLatin1Char('T'));
        if (!s.startsWith(QLatin1Char('P')) || t < 0) return 0;
        double total = 0;
        QString digits;
        for (int i = t + 1; i < s.size(); ++i) {
            const QChar c = s.at(i);
            if (c.isDigit() || c == QLatin1Char('.')) { digits.append(c); continue; }
            bool ok = false;
            const double v = digits.toDouble(&ok);
            digits.clear();
            if (!ok) return 0;
            if      (c == QLatin1Char('H')) total += v * 3600.0;
            else if (c == QLatin1Char('M')) total += v * 60.0;
            else if (c == QLatin1Char('S')) total += v;
            else return 0;
        }
        return qint64(total * 1000.0 + 0.5);
    }

    // printf width inside a DASH identifier, e.g. the "05d" of $Number%05d$.
    static QString formatNumber(long long n, const QString &fmt, bool *ok)
    {
        if (fmt.isEmpty()) return QString::number(n);
        if (!fmt.endsWith(QLatin1Char('d'))) { *ok = false; return {}; }
        QString digits = fmt;
        digits.chop(1);
        const bool zeroPad = digits.startsWith(QLatin1Char('0'));
        if (zeroPad) digits.remove(0, 1);
        bool widthOk = false;
        const int width = digits.isEmpty() ? 0 : digits.toInt(&widthOk);
        if (!digits.isEmpty() && !widthOk) { *ok = false; return {}; }
        if (width <= 0) return QString::number(n);
        return QStringLiteral("%1").arg(n, width, 10,
                                       zeroPad ? QLatin1Char('0') : QLatin1Char(' '));
    }

    // Substitutes one DASH URL template. $$ is a literal '$'; $Number$ (with an
    // optional printf width), $RepresentationID$ and $Bandwidth$ are expanded.
    // Any other identifier sets *ok to false, so the whole manifest is refused.
    static QString expandTemplate(const QString &tpl, long long number,
                                  const QString &repId, const QString &bandwidth,
                                  bool *ok)
    {
        *ok = true;
        QString out;
        out.reserve(tpl.size() + 16);
        int i = 0;
        while (i < tpl.size()) {
            const QChar c = tpl.at(i);
            if (c != QLatin1Char('$')) { out.append(c); ++i; continue; }
            if (i + 1 < tpl.size() && tpl.at(i + 1) == QLatin1Char('$')) {
                out.append(QLatin1Char('$'));
                i += 2;
                continue;
            }
            const int close = tpl.indexOf(QLatin1Char('$'), i + 1);
            if (close < 0) { *ok = false; return {}; }       // unterminated $…
            const QString spec = tpl.mid(i + 1, close - i - 1);
            i = close + 1;

            const int pct     = spec.indexOf(QLatin1Char('%'));
            const QString id  = pct < 0 ? spec : spec.left(pct);
            const QString fmt = pct < 0 ? QString() : spec.mid(pct + 1);

            if (id == QLatin1String("Number")) {
                out.append(formatNumber(number, fmt, ok));
            } else if (id == QLatin1String("RepresentationID")) {
                if (!fmt.isEmpty()) { *ok = false; return {}; }  // not a number
                out.append(repId);
            } else if (id == QLatin1String("Bandwidth")) {
                bool bwOk = false;
                const long long bw = bandwidth.toLongLong(&bwOk);
                if (!bwOk) { *ok = false; return {}; }
                out.append(formatNumber(bw, fmt, ok));
            } else {
                *ok = false;
                return {};
            }
            if (!*ok) return {};
        }
        return out;
    }

    // ── fetching ────────────────────────────────────────────────────────────

    void fetchAt(int index)
    {
        std::weak_ptr<char> alive = m_alive;
        QNetworkReply *reply = m_client->fetchRaw(QUrl(m_urls.at(index)),
            [this, alive, index](QByteArray data, QString err) {
                if (alive.expired() || m_settled) return;

                if (!err.isEmpty() || data.isEmpty()) {
                    settle(nullptr, err);
                    return;
                }

                m_parts[index] = data;
                ++m_completed;

                // Written in play order as soon as the gap in front of a segment
                // closes, so at most kMaxParallel segments are ever in memory.
                const int cursorBefore = m_writeCursor;
                while (m_writeCursor < m_parts.size() && !m_parts[m_writeCursor].isEmpty()) {
                    if (m_file->write(m_parts[m_writeCursor]) != m_parts[m_writeCursor].size()) {
                        settle(nullptr, m_file->errorString());
                        return;
                    }
                    m_parts[m_writeCursor] = QByteArray();
                    ++m_writeCursor;
                }

                if (m_writeCursor != cursorBefore) {
                    // flush() as well as write(): QFile buffers, so until this
                    // runs a second reader of tempFilePath() sees a short file.
                    // A failure here is the disk filling up.
                    if (!m_file->flush()) {
                        settle(nullptr, m_file->errorString());
                        return;
                    }
                    m_bytesReady = m_file->pos();
                    if (m_progress) {
                        m_progress(m_bytesReady, m_writeCursor);
                        // The receiver may drop this fetcher from inside the
                        // report, so from here on this object may be gone.
                        if (alive.expired() || m_settled) return;
                    }
                }

                if (m_nextToRequest < m_urls.size())
                    fetchAt(m_nextToRequest++);

                if (m_completed == m_urls.size()) {
                    m_file->flush();
                    qInfo() << "[dash] joined" << m_urls.size() << "segments into"
                            << m_file->fileName() << m_file->size() << "bytes";
                    m_file->close();
                    QTemporaryFile *done = m_file;
                    m_file = nullptr;           // ownership leaves with settle()
                    settle(done, QString());
                }
            });

        // QNetworkAccessManager never emits finished() synchronously, so the
        // reply is still in flight here. QPointer: every reply is deleteLater()d
        // as it finishes, and a raw pointer would dangle for the destructor.
        if (reply && !m_settled) {
            m_inFlight.removeIf([](const QPointer<QNetworkReply> &r) { return r.isNull(); });
            m_inFlight.append(reply);
        }
    }

    void settle(QTemporaryFile *file, const QString &errorDetail)
    {
        if (m_settled) return;
        m_settled = true;
        m_parts.clear();
        if (!file && m_file) { m_file->remove(); delete m_file; m_file = nullptr; }
        // Abort the remaining replies before reporting: the callback is where
        // the owner drops this object.
        const auto replies = m_inFlight;
        m_inFlight.clear();
        for (const QPointer<QNetworkReply> &r : replies)
            if (!r.isNull()) r->abort();
        if (m_done) m_done(file, errorDetail);
    }

    TidalClient *m_client;
    QStringList  m_urls;             // [0] is the initialization segment
    QVector<QByteArray> m_parts;     // arrive out of order, written in order
    QVector<QPointer<QNetworkReply>> m_inFlight;
    QTemporaryFile *m_file = nullptr;
    Done m_done;
    Progress m_progress;
    qint64 m_bytesReady = 0;
    int  m_nextToRequest = 0;
    int  m_completed     = 0;
    int  m_writeCursor   = 0;
    bool m_settled       = false;

    // Expires with this object, which is how an in-flight reply's callback
    // learns it has nothing left to call into. Nothing is ever read through it.
    std::shared_ptr<char> m_alive = std::make_shared<char>();

    // Segments are small and independent, so a few run at once. One at a time
    // would add a round trip per segment before the first note.
    static constexpr int kMaxParallel = 6;

    // A count no real track comes near. It bounds numbers that arrive over the
    // network: r= attributes that would overflow an int, and a duration
    // fallback that would reserve a list of millions of URLs.
    static constexpr int kMaxSegments = 20000;
};

inline QStringList DashFetcher::parseSegmentUrls(const QString &mpdXml)
{
    QString initTpl, mediaTpl, repId, bandwidth;
    long long timescale   = 1;
    long long segDuration = 0;   // SegmentTemplate@duration, when there is no timeline
    qint64    totalMs     = 0;   // MPD@mediaPresentationDuration
    int  startNumber  = 1;
    int  segmentCount = 0;
    bool haveTemplate = false;
    bool haveTimeline = false;

    QXmlStreamReader xml(mpdXml);
    while (!xml.atEnd() && !xml.hasError()) {
        xml.readNext();
        if (xml.isStartElement()) {
            const auto name = xml.name();
            const auto at   = xml.attributes();
            if (name == QLatin1String("MPD")) {
                totalMs = parseIsoDuration(
                    at.value(QLatin1String("mediaPresentationDuration")).toString());
            } else if (!haveTemplate && name == QLatin1String("Representation")) {
                // The enclosing Representation of the SegmentTemplate below,
                // for $RepresentationID$ / $Bandwidth$.
                repId     = at.value(QLatin1String("id")).toString();
                bandwidth = at.value(QLatin1String("bandwidth")).toString();
            } else if (!haveTemplate && name == QLatin1String("SegmentTemplate")) {
                haveTemplate = true;
                initTpl     = at.value(QLatin1String("initialization")).toString();
                mediaTpl    = at.value(QLatin1String("media")).toString();
                segDuration = at.value(QLatin1String("duration")).toLongLong();
                timescale   = at.value(QLatin1String("timescale")).toLongLong();
                if (timescale <= 0) timescale = 1;
                startNumber = at.value(QLatin1String("startNumber")).toInt();
                if (startNumber <= 0) startNumber = 1;
            } else if (haveTemplate && name == QLatin1String("S")) {
                // <S d="…" r="n"/> covers n+1 segments; r is absent for a single
                // one and negative only in a live manifest, which has no end to
                // join up to.
                const int r = at.value(QLatin1String("r")).toInt();
                if (r < 0) return {};
                if (r > kMaxSegments || segmentCount > kMaxSegments - 1 - r) return {};
                haveTimeline = true;
                segmentCount += 1 + r;
            }
        } else if (haveTemplate && xml.isEndElement()
                   && xml.name() == QLatin1String("SegmentTemplate")) {
            break;   // Tidal sends one audio Representation; ignore any later one
        }
    }
    if (xml.hasError()) return {};
    if (!haveTemplate || initTpl.isEmpty() || mediaTpl.isEmpty()) return {};

    if (!haveTimeline) {
        // No timeline: a fixed segment duration, the count implied by the total.
        if (segDuration <= 0 || totalMs <= 0) return {};
        const double segMs = (double(segDuration) * 1000.0) / double(timescale);
        if (segMs <= 0.0) return {};
        const double count = std::ceil(double(totalMs) / segMs);
        if (count <= 0.0 || count > double(kMaxSegments)) return {};
        segmentCount = int(count);
    }
    if (segmentCount <= 0) return {};

    bool ok = false;
    const QString init = expandTemplate(initTpl, startNumber, repId, bandwidth, &ok);
    if (!ok || init.isEmpty()) return {};

    QStringList urls;
    urls.reserve(segmentCount + 1);
    urls << init;
    for (int n = startNumber; n < startNumber + segmentCount; ++n) {
        const QString u = expandTemplate(mediaTpl, n, repId, bandwidth, &ok);
        if (!ok || u.isEmpty()) return {};
        urls << u;
    }
    return urls;
}
