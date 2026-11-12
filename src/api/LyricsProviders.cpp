// SPDX-License-Identifier: GPL-3.0-or-later

#include "LyricsProviders.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QUrlQuery>
#include <cmath>

namespace {

// Words that mark a bracket or dash suffix as about the recording, not the song.
const QString kVersionWords = QStringLiteral(
    "feat|ft|featuring|with|prod|remaster|remastered|version|edit|mix|remix|live|"
    "mono|stereo|explicit|clean|deluxe|bonus|single|radio|acoustic|demo|extended|"
    "original|anniversary|instrumental|\\d{4}");

QString stripVersionParts(QString t) {
    static const QRegularExpression bracket(
        QStringLiteral("\\s*[\\(\\[]([^\\)\\]]*)[\\)\\]]"));
    static const QRegularExpression keyword(
        QStringLiteral("\\b(%1)\\b").arg(kVersionWords),
        QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression dashSuffix(
        QStringLiteral("\\s+[-\u2013\u2014]\\s+(.*)$"));
    static const QRegularExpression bareFeat(
        QStringLiteral("\\s+(feat\\.?|ft\\.?|featuring)\\s+.*$"),
        QRegularExpression::CaseInsensitiveOption);

    QString out;
    qsizetype from = 0;
    auto it = bracket.globalMatch(t);
    while (it.hasNext()) {
        const auto m = it.next();
        out += t.mid(from, m.capturedStart() - from);
        if (!keyword.match(m.captured(1)).hasMatch()) out += m.captured(0);
        from = m.capturedEnd();
    }
    out += t.mid(from);

    const auto d = dashSuffix.match(out);
    if (d.hasMatch() && keyword.match(d.captured(1)).hasMatch())
        out.truncate(d.capturedStart());
    out.remove(bareFeat);
    out = out.trimmed();
    return out.isEmpty() ? t.trimmed() : out;
}

QString fold(const QString &s) {
    const QString d = s.normalized(QString::NormalizationForm_KD).toLower();
    QString out;
    out.reserve(d.size());
    for (const QChar c : d) {
        if (c.category() == QChar::Mark_NonSpacing) continue;
        if (c == u'\'' || c == u'\u2019' || c == u'`') continue;
        if (c == u'&') { out += QStringLiteral(" and "); continue; }
        out += c.isLetterOrNumber() ? c : QChar(u' ');
    }
    return out.simplified();
}

QString firstArtist(const LyricsQuery &q) {
    return q.artists.isEmpty() ? QString() : q.artists.first();
}

QString decodeEntities(const QString &s) {
    static const QRegularExpression ent(QStringLiteral("&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"));
    QString out;
    qsizetype from = 0;
    auto it = ent.globalMatch(s);
    while (it.hasNext()) {
        const auto m = it.next();
        out += s.mid(from, m.capturedStart() - from);
        const QString e = m.captured(1);
        QString rep;
        if (e.startsWith(QLatin1String("#x")) || e.startsWith(QLatin1String("#X"))) {
            const char32_t c = e.mid(2).toUInt(nullptr, 16);
            rep = QString::fromUcs4(&c, 1);
        } else if (e.startsWith(u'#')) {
            const char32_t c = e.mid(1).toUInt();
            rep = QString::fromUcs4(&c, 1);
        } else if (e == QLatin1String("amp"))  { rep = QStringLiteral("&");
        } else if (e == QLatin1String("lt"))   { rep = QStringLiteral("<");
        } else if (e == QLatin1String("gt"))   { rep = QStringLiteral(">");
        } else if (e == QLatin1String("quot")) { rep = QStringLiteral("\"");
        } else if (e == QLatin1String("apos")) { rep = QStringLiteral("'");
        } else if (e == QLatin1String("nbsp")) { rep = QStringLiteral(" ");
        } else { rep = m.captured(0); }
        out += rep;
        from = m.capturedEnd();
    }
    out += s.mid(from);
    return out;
}

// Index just past the end tag that closes the element whose start tag begins
// at `open`, or -1. Counts nested elements of the same name.
qsizetype elementEnd(const QString &html, qsizetype open) {
    qsizetype p = open + 1;
    while (p < html.size() && html.at(p).isLetterOrNumber()) ++p;
    const QString name = html.mid(open + 1, p - open - 1).toLower();
    if (name.isEmpty()) return -1;
    const QString openTag = u'<' + name, closeTag = QStringLiteral("</") + name;
    int depth = 0;
    qsizetype i = open;
    while (i < html.size()) {
        const qsizetype lt = html.indexOf(u'<', i);
        if (lt < 0) return -1;
        const qsizetype gt = html.indexOf(u'>', lt);
        if (gt < 0) return -1;
        const QString tag = html.mid(lt, gt - lt + 1);
        auto boundary = [&](qsizetype len) {
            return tag.size() > len && !tag.at(len).isLetterOrNumber();
        };
        if (tag.startsWith(closeTag, Qt::CaseInsensitive) && boundary(closeTag.size())) {
            if (--depth == 0) return gt + 1;
        } else if (tag.startsWith(openTag, Qt::CaseInsensitive) && boundary(openTag.size())
                   && !tag.endsWith(QLatin1String("/>"))) {
            ++depth;
        }
        i = gt + 1;
    }
    return -1;
}

void removeElementsWith(QString &html, const QString &attr) {
    for (qsizetype at = html.indexOf(attr); at >= 0; at = html.indexOf(attr)) {
        const qsizetype open = html.lastIndexOf(u'<', at);
        const qsizetype end = open < 0 ? -1 : elementEnd(html, open);
        if (end < 0) { html.remove(at, attr.size()); continue; }
        html.remove(open, end - open);
    }
}

} // namespace

namespace lyrics {

QString normaliseTitle(const QString &title) { return fold(stripVersionParts(title)); }

QString normaliseArtist(const QString &artist) {
    QString a = fold(artist);
    if (a.startsWith(QLatin1String("the "))) a = a.mid(4);
    return a;
}

bool titleMatches(const QString &wanted, const QString &got) {
    const QString w = normaliseTitle(wanted);
    return !w.isEmpty() && w == normaliseTitle(got);
}

bool artistMatches(const QStringList &wanted, const QString &got) {
    const QString g = normaliseArtist(got);
    if (g.isEmpty()) return false;
    const QString gp = u' ' + g + u' ';
    for (const QString &w : wanted) {
        const QString n = normaliseArtist(w);
        if (n.isEmpty()) continue;
        if (n == g) return true;
        // "A and B" credited where the track names A, or the other way round.
        if (n.size() >= 2 && gp.contains(u' ' + n + u' ')) return true;
        if (g.size() >= 2 && (u' ' + n + u' ').contains(gp)) return true;
    }
    return false;
}

bool durationMatches(int wanted, double got) {
    if (wanted <= 0 || got <= 0) return true;
    return std::abs(got - wanted) <= 3.0;
}

bool looksLikeChallenge(const QByteArray &body) {
    static const char *const markers[] = {
        "<title>Just a moment...</title>", "cf_chl_opt", "id=\"challenge-form\"",
        "Attention Required! | Cloudflare", "cf-browser-verification",
    };
    const QByteArray head = body.left(64 * 1024);
    for (const char *m : markers)
        if (head.contains(m)) return true;
    return false;
}

QString geniusLyricsFromHtml(const QByteArray &bytes) {
    const QString html = QString::fromUtf8(bytes);
    const QString attr = QStringLiteral("data-lyrics-container=\"true\"");
    QStringList parts;
    for (qsizetype at = html.indexOf(attr); at >= 0;) {
        const qsizetype open = html.lastIndexOf(u'<', at);
        const qsizetype end = open < 0 ? -1 : elementEnd(html, open);
        if (end < 0) break;
        const qsizetype innerFrom = html.indexOf(u'>', at) + 1;
        const qsizetype innerTo = html.lastIndexOf(u'<', end - 1);
        parts << html.mid(innerFrom, innerTo - innerFrom);
        at = html.indexOf(attr, end);
    }
    if (parts.isEmpty()) return {};

    QString text = parts.join(QStringLiteral("<br>"));
    removeElementsWith(text, QStringLiteral("data-exclude-from-selection=\"true\""));
    static const QRegularExpression br(QStringLiteral("<br\\s*/?>"),
                                       QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression tag(QStringLiteral("<[^>]*>"));
    text.replace(br, QStringLiteral("\n"));
    text.remove(tag);
    text = decodeEntities(text);

    QStringList lines;
    for (const QString &raw : text.split(u'\n')) {
        const QString l = raw.trimmed();
        if (l.isEmpty() && (lines.isEmpty() || lines.last().isEmpty())) continue;
        lines << l;
    }
    while (!lines.isEmpty() && lines.last().isEmpty()) lines.removeLast();
    // Older pages put "12 Contributors...Title Lyrics" in front of the first line.
    static const QRegularExpression header(
        QStringLiteral("^\\d+\\s*Contributors?.*?Lyrics"));
    if (!lines.isEmpty()) {
        lines.first().remove(header);
        lines.first() = lines.first().trimmed();
        if (lines.first().isEmpty()) lines.removeFirst();
    }
    return lines.join(u'\n');
}

QList<std::shared_ptr<const LyricsProvider>> defaultProviders() {
    return { std::make_shared<LrclibProvider>(), std::make_shared<GeniusProvider>() };
}

} // namespace lyrics

// ── LRCLIB ──────────────────────────────────────────────────────────────────

bool LrclibProvider::fromRecord(const LyricsQuery &q, const QVariantMap &rec, LyricsResult *out) {
    if (rec.value(QStringLiteral("instrumental")).toBool()) return false;
    if (!lyrics::titleMatches(q.title, rec.value(QStringLiteral("trackName")).toString())) return false;
    if (!lyrics::artistMatches(q.artists, rec.value(QStringLiteral("artistName")).toString())) return false;
    if (!lyrics::durationMatches(q.duration, rec.value(QStringLiteral("duration")).toDouble())) return false;
    const QString synced = rec.value(QStringLiteral("syncedLyrics")).toString().trimmed();
    const QString plain = rec.value(QStringLiteral("plainLyrics")).toString().trimmed();
    if (synced.isEmpty() && plain.isEmpty()) return false;
    out->timed = !synced.isEmpty();
    out->text = out->timed ? synced : plain;
    out->source = QStringLiteral("LRCLIB");
    out->url = QUrl(QStringLiteral("https://lrclib.net/"));
    return true;
}

LyricsStep LrclibProvider::start(const LyricsQuery &q) const {
    QUrl u(QStringLiteral("https://lrclib.net/api/get"));
    QUrlQuery qq;
    qq.addQueryItem(QStringLiteral("artist_name"), firstArtist(q));
    qq.addQueryItem(QStringLiteral("track_name"), q.title);
    if (!q.album.isEmpty()) qq.addQueryItem(QStringLiteral("album_name"), q.album);
    if (q.duration > 0) qq.addQueryItem(QStringLiteral("duration"), QString::number(q.duration));
    u.setQuery(qq);
    return LyricsStep::request(u, Get);
}

LyricsStep LrclibProvider::next(const LyricsQuery &q, const LyricsStep &prev,
                                const LyricsReply &reply) const {
    if (prev.stage == Get) {
        if (reply.status == 200) {
            LyricsResult r;
            const QVariantMap rec = QJsonDocument::fromJson(reply.body).object().toVariantMap();
            if (fromRecord(q, rec, &r)) return LyricsStep::found(r);
        } else if (reply.status != 404) {
            return LyricsStep::failed();
        }
        QUrl u(QStringLiteral("https://lrclib.net/api/search"));
        QUrlQuery qq;
        qq.addQueryItem(QStringLiteral("track_name"), stripVersionParts(q.title));
        qq.addQueryItem(QStringLiteral("artist_name"), firstArtist(q));
        u.setQuery(qq);
        return LyricsStep::request(u, Search);
    }

    if (reply.status == 404) return LyricsStep::miss();
    if (reply.status != 200) return LyricsStep::failed();
    LyricsResult best;
    double bestOff = 1e9;
    bool have = false;
    for (const QJsonValue &v : QJsonDocument::fromJson(reply.body).array()) {
        const QVariantMap rec = v.toObject().toVariantMap();
        LyricsResult r;
        if (!fromRecord(q, rec, &r)) continue;
        const double off = q.duration > 0
            ? std::abs(rec.value(QStringLiteral("duration")).toDouble() - q.duration) : 0;
        // Synced beats plain, then the closer length wins.
        if (!have || (r.timed && !best.timed) || (r.timed == best.timed && off < bestOff)) {
            best = r; bestOff = off; have = true;
        }
    }
    return have ? LyricsStep::found(best) : LyricsStep::miss();
}

// ── Genius ──────────────────────────────────────────────────────────────────

QUrl GeniusProvider::pickHit(const LyricsQuery &q, const QByteArray &searchJson) {
    const QJsonObject resp = QJsonDocument::fromJson(searchJson).object()
                                 .value(QStringLiteral("response")).toObject();
    QJsonArray hits;
    for (const QJsonValue &s : resp.value(QStringLiteral("sections")).toArray())
        for (const QJsonValue &h : s.toObject().value(QStringLiteral("hits")).toArray())
            hits.append(h);
    for (const QJsonValue &h : resp.value(QStringLiteral("hits")).toArray()) hits.append(h);

    for (const QJsonValue &h : hits) {
        const QJsonObject r = h.toObject().value(QStringLiteral("result")).toObject();
        if (r.value(QStringLiteral("instrumental")).toBool()) continue;
        const QString state = r.value(QStringLiteral("lyrics_state")).toString();
        if (!state.isEmpty() && state != QLatin1String("complete")) continue;
        const bool titleOk =
            lyrics::titleMatches(q.title, r.value(QStringLiteral("title")).toString())
            || lyrics::titleMatches(q.title, r.value(QStringLiteral("title_with_featured")).toString());
        const bool artistOk =
            lyrics::artistMatches(q.artists, r.value(QStringLiteral("primary_artist")).toObject()
                                                 .value(QStringLiteral("name")).toString())
            || lyrics::artistMatches(q.artists, r.value(QStringLiteral("artist_names")).toString());
        if (!titleOk || !artistOk) continue;
        const QUrl url(r.value(QStringLiteral("url")).toString());
        if (url.scheme() == QLatin1String("https") && url.host() == QLatin1String("genius.com"))
            return url;
    }
    return {};
}

LyricsStep GeniusProvider::start(const LyricsQuery &q) const {
    QUrl u(QStringLiteral("https://genius.com/api/search/song"));
    QUrlQuery qq;
    qq.addQueryItem(QStringLiteral("q"), firstArtist(q) + u' ' + stripVersionParts(q.title));
    qq.addQueryItem(QStringLiteral("per_page"), QStringLiteral("5"));
    u.setQuery(qq);
    return LyricsStep::request(u, Search);
}

LyricsStep GeniusProvider::next(const LyricsQuery &q, const LyricsStep &prev,
                                const LyricsReply &reply) const {
    if (prev.stage == Search) {
        if (reply.status != 200) return LyricsStep::failed();
        const QUrl page = pickHit(q, reply.body);
        return page.isValid() ? LyricsStep::request(page, Page) : LyricsStep::miss();
    }
    if (reply.status == 404) return LyricsStep::miss();
    if (reply.status != 200) return LyricsStep::failed();
    LyricsResult r;
    r.text = lyrics::geniusLyricsFromHtml(reply.body);
    if (r.text.isEmpty()) return LyricsStep::miss();
    r.source = QStringLiteral("Genius");
    r.url = prev.url;
    return LyricsStep::found(r);
}
