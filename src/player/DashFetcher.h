#pragma once
//
// Turning Tidal's DASH manifest into something QMediaPlayer can actually open.
//
// LOSSLESS and HI_RES_LOSSLESS arrive as MPEG-DASH: a manifest plus one URL per
// segment. The old code wrote that manifest to a .mpd and handed the file to
// QMediaPlayer, expecting the backend to fetch the segments itself. That only
// works where libavformat was built with libxml2, because libxml2 is what its
// DASH demuxer is gated on:
//
//     ldd ~/Qt/6.12.0/gcc_64/lib/libavformat.so.61 | grep -c xml2  -> 0
//     ldd /usr/lib/libavformat.so.61                         | grep -c xml2  -> 1
//
// The Qt installer's bundled ffmpeg has no libxml2, and the ffmpeg media plugin
// resolves libavformat through its own $ORIGIN/../../lib, so on any build made
// against the Qt installer the bundled copy always wins and every DASH track is
// rejected as InvalidMedia with "Invalid data found when processing input" —
// silently, in under a millisecond, with nothing audible to show for it. Whether
// lossless played came down to which Qt the packager happened to have.
//
// A DASH segment is a plain fragmented-MP4 piece, so the initialization segment
// followed by every media segment in order *is* an ordinary fragmented MP4. Any
// ffmpeg build reads that, libxml2 or not, which is the whole point: joining the
// segments here needs no demuxer that might be missing. It also lands the result
// in exactly the shape the BTS (AAC) path already produces — one local temp file
// — so playback stays a single code path.
//
// Header-only and deliberately not a QObject: no Q_OBJECT means no moc, and no
// moc means the class needs no entry in CMakeLists.txt's SOURCES/HEADERS to be
// compiled into the static library. The cost is that it reports through a
// std::function rather than a signal, which is also what TidalClient::fetchRaw
// takes, so nothing is lost. There is no tr() here either: the user-visible
// wording stays with the callers, which already have translation contexts.
//
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
    // file is null exactly when the join failed; errorDetail is then whatever
    // the network said, which may be empty. Ownership of the file passes to the
    // receiver, it is closed, and its autoRemove is off: take fileName() and
    // delete it, or keep it and let its destructor leave the bytes behind.
    using Done = std::function<void(QTemporaryFile *file, const QString &errorDetail)>;

    // Expands a DASH manifest into the URLs to fetch: [0] is the initialization
    // segment, the rest are the media segments in play order. Empty when the
    // manifest carries no SegmentTemplate this can expand — see expandTemplate()
    // below for why an identifier it does not know refuses the whole manifest
    // rather than leaving itself in a URL.
    static QStringList parseSegmentUrls(const QString &mpdXml);

    DashFetcher(TidalClient *client, const QString &mpdXml)
        : m_client(client), m_urls(parseSegmentUrls(mpdXml))
    {
        m_parts.resize(m_urls.size());
        if (m_urls.isEmpty()) return;
        // Opened here rather than in start() so that every synchronous failure
        // is visible to the caller *before* it commits to this object. start()
        // then only ever reports through the event loop, which means a caller
        // can store the fetcher first and clear it from inside the callback
        // without destroying an object that is still running.
        m_file = new QTemporaryFile(QDir::tempPath() + QStringLiteral("/tidal-wave-XXXXXX.mp4"));
        m_file->setAutoRemove(false);
        if (!m_file->open()) {
            delete m_file;
            m_file = nullptr;
        }
    }

    ~DashFetcher()
    {
        // First statement, not last. Each abort() below runs the reply's
        // finished handler synchronously, which calls straight back into the
        // lambda in fetchAt(); expiring the guard here is what turns that into
        // a no-op instead of a use of a half-destroyed object.
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
    // Where the join is going, while it is still going there; empty once the
    // file has been handed over or given up on.
    QString tempFilePath() const { return m_file ? m_file->fileName() : QString(); }
    // Segments including the initialization segment, so one more than the
    // manifest's media-segment count.
    int partCount() const { return int(m_urls.size()); }

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

    // Substitutes one DASH URL template. $$ is a literal '$'. $Number$ (with an
    // optional printf width), $RepresentationID$ and $Bandwidth$ are what Tidal
    // and the usual packagers emit.
    //
    // Anything else sets *ok to false and yields nothing, rather than leaving
    // the identifier in the URL. A URL with a live $Time$ in it would fetch, 404
    // and surface as "the audio would not download", sending whoever reads that
    // after the network. Refusing the manifest outright makes the one thing that
    // is actually wrong — a manifest shape this does not expand — the thing the
    // user is told about.
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
                // Holding the whole track would be tens of megabytes for CD
                // audio and a few hundred for a long hi-res one.
                while (m_writeCursor < m_parts.size() && !m_parts[m_writeCursor].isEmpty()) {
                    if (m_file->write(m_parts[m_writeCursor]) != m_parts[m_writeCursor].size()) {
                        settle(nullptr, m_file->errorString());
                        return;
                    }
                    m_parts[m_writeCursor] = QByteArray();
                    ++m_writeCursor;
                }

                if (m_nextToRequest < m_urls.size())
                    fetchAt(m_nextToRequest++);

                if (m_completed == m_urls.size()) {
                    m_file->flush();
                    // One line per lossless track, because the thing this class
                    // exists to fix used to fail with nothing in the log at all.
                    qInfo() << "[dash] joined" << m_urls.size() << "segments into"
                            << m_file->fileName() << m_file->size() << "bytes";
                    m_file->close();
                    QTemporaryFile *done = m_file;
                    m_file = nullptr;           // ownership leaves with settle()
                    settle(done, QString());
                }
            });

        // QNetworkAccessManager never emits finished() synchronously, so the
        // callback above has not run yet and this reply is still in flight; the
        // m_settled check is only insurance against a fetchRaw that one day does
        // answer from cache. QPointer rather than a raw pointer because every
        // reply is deleteLater()d as it finishes, so a plain list would fill with
        // dangling entries for the destructor to walk.
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
        // Peers are still downloading segments nobody wants any more. Abort
        // before reporting, because the callback is where the owner drops this
        // object, and a reply that finishes after that is a reply whose handler
        // finds an expired guard — correct, but it has already spent the
        // bandwidth.
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
    int  m_nextToRequest = 0;
    int  m_completed     = 0;
    int  m_writeCursor   = 0;
    bool m_settled       = false;

    // Expires with this object, which is how an in-flight reply's callback
    // learns it has nothing left to call into. Nothing is ever read through it.
    std::shared_ptr<char> m_alive = std::make_shared<char>();

    // Segments are small and independent, so a few run at once. One at a time
    // would add a round trip per segment — around fifty on a normal track —
    // before the first note.
    static constexpr int kMaxParallel = 6;

    // A count no real track comes near: ten hours of two-second segments is
    // 18000. It stops two things, both driven by a number that arrives over the
    // network. A manifest whose r= attributes add up past what an int holds is
    // signed overflow, which is not a thing to find out about later; and a
    // duration fallback whose arithmetic comes out absurd would otherwise have
    // this reserve and fill a list of millions of URLs before failing.
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
        // The other half of SegmentTemplate: a fixed segment duration, with the
        // count implied by how long the whole thing is.
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
