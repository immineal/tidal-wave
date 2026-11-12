// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QByteArray>
#include <QList>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QVariant>
#include <memory>

// Lyrics from sites other than Tidal. Providers are pure: they turn a query
// into requests and replies into results, and LyricsFinder does all I/O.

struct LyricsQuery {
    qint64      trackId = 0;
    QString     title;
    QStringList artists;    // primary artist first
    QString     album;
    int         duration = 0;   // seconds, 0 when unknown
};

struct LyricsResult {
    QString text;           // LRC when timed, else plain lines
    bool    timed = false;
    QString source;         // display name, e.g. "LRCLIB"
    QUrl    url;            // page the lyrics came from
    bool    instrumental = false;   // a source said the track has no words
};

struct LyricsReply {
    int        status = 0;  // HTTP status, 0 when no answer came
    QByteArray body;
    QByteArray retryAfter;
};

struct LyricsStep {
    // Instrumental ends the chain like Found: a source knows the song and
    // says it has no words.
    enum Kind { Request, Found, Miss, Failed, Instrumental };
    Kind         kind = Miss;
    QUrl         url;       // Request
    int          stage = 0; // Request: handed back to next()
    QVariant     context;   // Request: handed back to next()
    LyricsResult result;    // Found

    static LyricsStep request(const QUrl &u, int stage, const QVariant &ctx = {}) {
        LyricsStep s; s.kind = Request; s.url = u; s.stage = stage; s.context = ctx; return s;
    }
    static LyricsStep found(const LyricsResult &r) { LyricsStep s; s.kind = Found; s.result = r; return s; }
    static LyricsStep miss()   { return LyricsStep{}; }
    static LyricsStep failed() { LyricsStep s; s.kind = Failed; return s; }
    static LyricsStep instrumental() { LyricsStep s; s.kind = Instrumental; return s; }
};

class LyricsProvider {
public:
    virtual ~LyricsProvider() = default;
    virtual QString    name() const = 0;
    virtual LyricsStep start(const LyricsQuery &q) const = 0;
    // `prev` is the Request step the reply answers. Only called with a reply
    // the finder did not classify as a refusal.
    virtual LyricsStep next(const LyricsQuery &q, const LyricsStep &prev,
                            const LyricsReply &reply) const = 0;
};

namespace lyrics {

QString normaliseTitle(const QString &title);
QString normaliseArtist(const QString &artist);
bool    titleMatches(const QString &wanted, const QString &got);
bool    artistMatches(const QStringList &wanted, const QString &got);
// A source that gives no duration passes with got <= 0.
bool    durationMatches(int wanted, double got, double tolerance = 3.0);
// The title without bracketed or dashed version parts, case kept.
QString searchTitle(const QString &title);
// Drops credit lines ("作词 : ...", "Lyrics by: ...") and LRC header tags.
QString stripCreditLines(const QString &lyrics);
bool    hasTimestamps(const QString &lyrics);

// A body that is an anti-bot interstitial rather than the page asked for.
bool    looksLikeChallenge(const QByteArray &body);

// The lyrics in a Genius song page, or "" when there are none.
QString geniusLyricsFromHtml(const QByteArray &html);

// The usual chain, best source first.
QList<std::shared_ptr<const LyricsProvider>> defaultProviders();

} // namespace lyrics

class LrclibProvider : public LyricsProvider {
public:
    enum Stage { Get = 0, Search = 1 };
    QString    name() const override { return QStringLiteral("LRCLIB"); }
    LyricsStep start(const LyricsQuery &q) const override;
    LyricsStep next(const LyricsQuery &q, const LyricsStep &prev,
                    const LyricsReply &reply) const override;

    // Public for tests: Found, Instrumental or Miss for one record.
    static LyricsStep fromRecord(const LyricsQuery &q, const QVariantMap &rec, double tolerance);
};

class NeteaseProvider : public LyricsProvider {
public:
    enum Stage { Search = 0, Lyric = 1 };
    QString    name() const override { return QStringLiteral("NetEase Cloud Music"); }
    LyricsStep start(const LyricsQuery &q) const override;
    LyricsStep next(const LyricsQuery &q, const LyricsStep &prev,
                    const LyricsReply &reply) const override;
};

class KugouProvider : public LyricsProvider {
public:
    enum Stage { Search = 0, Download = 1 };
    QString    name() const override { return QStringLiteral("KuGou"); }
    LyricsStep start(const LyricsQuery &q) const override;
    LyricsStep next(const LyricsQuery &q, const LyricsStep &prev,
                    const LyricsReply &reply) const override;
};

// Asks for the song page by its address only: robots.txt allows the pages
// and disallows the search API.
class GeniusProvider : public LyricsProvider {
public:
    QString    name() const override { return QStringLiteral("Genius"); }
    LyricsStep start(const LyricsQuery &q) const override;
    LyricsStep next(const LyricsQuery &q, const LyricsStep &prev,
                    const LyricsReply &reply) const override;

    // Empty when artist and title fold to nothing in ASCII.
    static QUrl pageUrl(const LyricsQuery &q);
    // Whether the page's <title> reads "Artist – Title Lyrics" for this song.
    static bool pageIsFor(const LyricsQuery &q, const QByteArray &html);
};
