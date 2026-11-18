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

bool durationMatches(int wanted, double got, double tolerance) {
    if (wanted <= 0 || got <= 0) return true;
    return std::abs(got - wanted) <= tolerance;
}

QString searchTitle(const QString &title) { return stripVersionParts(title); }

QString stripCreditLines(const QString &text) {
    static const QRegularExpression stamps(QStringLiteral("^(\\s*\\[[^\\]]*\\])*"));
    static const QRegularExpression credit(
        QStringLiteral("^\\s*(\\p{Han}{1,6}|lyrics by|lyricist|written by|composer|composed by|"
                       "producer|produced by|arranger|arranged by|mixed by|mastered by)\\s*[:\uff1a]"),
        QRegularExpression::CaseInsensitiveOption);
    // LRC header tags such as [ar:...] and [ti:...].
    static const QRegularExpression tagOnly(QStringLiteral("^\\s*\\[[A-Za-z]+:[^\\]]*\\]\\s*$"));
    QStringList out;
    for (const QString &line : text.split(u'\n')) {
        const QString words = QString(line).remove(stamps);
        if (credit.match(words).hasMatch() || tagOnly.match(line).hasMatch()) continue;
        out << line;
    }
    while (!out.isEmpty() && out.last().trimmed().isEmpty()) out.removeLast();
    return out.join(u'\n');
}

bool hasTimestamps(const QString &text) {
    static const QRegularExpression stamp(QStringLiteral("^\\[\\d{1,2}:\\d{2}[.:]\\d{2,3}\\]"),
                                          QRegularExpression::MultilineOption);
    return stamp.match(text).hasMatch();
}

// Lines that carry words once the timestamps and tags are taken off.
int wordLines(const QString &text) {
    static const QRegularExpression tags(QStringLiteral("\\[[^\\]]*\\]"));
    int n = 0;
    for (const QString &line : text.split(u'\n'))
        if (!QString(line).remove(tags).trimmed().isEmpty()) ++n;
    return n;
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
    // Genius last, so it is asked least.
    return { std::make_shared<LrclibProvider>(), std::make_shared<NeteaseProvider>(),
             std::make_shared<KugouProvider>(), std::make_shared<GeniusProvider>() };
}

} // namespace lyrics

// ── LRCLIB ──────────────────────────────────────────────────────────────────

LyricsStep LrclibProvider::fromRecord(const LyricsQuery &q, const QVariantMap &rec, double tolerance) {
    if (!lyrics::titleMatches(q.title, rec.value(QStringLiteral("trackName")).toString())
        || !lyrics::artistMatches(q.artists, rec.value(QStringLiteral("artistName")).toString())
        || !lyrics::durationMatches(q.duration, rec.value(QStringLiteral("duration")).toDouble(), tolerance))
        return LyricsStep::miss();
    if (rec.value(QStringLiteral("instrumental")).toBool()) return LyricsStep::instrumental();
    const QString synced = rec.value(QStringLiteral("syncedLyrics")).toString().trimmed();
    const QString plain = rec.value(QStringLiteral("plainLyrics")).toString().trimmed();
    if (synced.isEmpty() && plain.isEmpty()) return LyricsStep::miss();
    LyricsResult r;
    r.timed = !synced.isEmpty();
    r.text = r.timed ? synced : plain;
    r.source = QStringLiteral("LRCLIB");
    r.url = QUrl(QStringLiteral("https://lrclib.net/"));
    return LyricsStep::found(r);
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
            const QVariantMap rec = QJsonDocument::fromJson(reply.body).object().toVariantMap();
            const LyricsStep r = fromRecord(q, rec, 3.0);
            if (r.kind != LyricsStep::Miss) return r;
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
    LyricsStep best = LyricsStep::miss();
    double bestOff = 1e9;
    for (const QJsonValue &v : QJsonDocument::fromJson(reply.body).array()) {
        const QVariantMap rec = v.toObject().toVariantMap();
        const LyricsStep r = fromRecord(q, rec, 2.0);
        if (r.kind == LyricsStep::Miss) continue;
        const double off = q.duration > 0
            ? std::abs(rec.value(QStringLiteral("duration")).toDouble() - q.duration) : 0;
        // Words beat an instrumental, synced beats plain, then the closer length.
        auto rank = [](const LyricsStep &x) {
            return x.kind == LyricsStep::Miss ? 0 : x.kind == LyricsStep::Instrumental ? 1
                 : x.result.timed ? 3 : 2;
        };
        if (rank(r) > rank(best) || (rank(r) == rank(best) && off < bestOff)) {
            best = r; bestOff = off;
        }
    }
    return best;
}

// ── NetEase ─────────────────────────────────────────────────────────────────

LyricsStep NeteaseProvider::start(const LyricsQuery &q) const {
    QUrl u(QStringLiteral("https://music.163.com/api/search/get"));
    QUrlQuery qq;
    qq.addQueryItem(QStringLiteral("s"), firstArtist(q) + u' ' + stripVersionParts(q.title));
    qq.addQueryItem(QStringLiteral("type"), QStringLiteral("1"));
    qq.addQueryItem(QStringLiteral("limit"), QStringLiteral("10"));
    qq.addQueryItem(QStringLiteral("offset"), QStringLiteral("0"));
    u.setQuery(qq);
    return LyricsStep::request(u, Search);
}

LyricsStep NeteaseProvider::next(const LyricsQuery &q, const LyricsStep &prev,
                                 const LyricsReply &reply) const {
    if (reply.status != 200) return LyricsStep::failed();
    const QJsonObject root = QJsonDocument::fromJson(reply.body).object();
    if (prev.stage == Search) {
        const QJsonArray songs = root.value(QStringLiteral("result")).toObject()
                                     .value(QStringLiteral("songs")).toArray();
        for (const QJsonValue &v : songs) {
            const QJsonObject song = v.toObject();
            QStringList names;
            for (const QJsonValue &a : song.value(QStringLiteral("artists")).toArray())
                names << a.toObject().value(QStringLiteral("name")).toString();
            double ms = song.value(QStringLiteral("duration")).toDouble();
            if (ms <= 0) ms = song.value(QStringLiteral("dt")).toDouble();
            if (!lyrics::titleMatches(q.title, song.value(QStringLiteral("name")).toString())
                || !lyrics::artistMatches(q.artists, names.join(QStringLiteral(", ")))
                || !lyrics::durationMatches(q.duration, ms / 1000.0))
                continue;
            const qint64 id = qint64(song.value(QStringLiteral("id")).toDouble());
            QUrl u(QStringLiteral("https://music.163.com/api/song/lyric"));
            u.setQuery(QStringLiteral("id=%1&lv=-1&kv=-1&tv=-1").arg(id));
            return LyricsStep::request(u, Lyric, id);
        }
        return LyricsStep::miss();
    }

    if (root.value(QStringLiteral("nolyric")).toBool() || root.value(QStringLiteral("pureMusic")).toBool())
        return LyricsStep::instrumental();
    const QString text = lyrics::stripCreditLines(
        root.value(QStringLiteral("lrc")).toObject().value(QStringLiteral("lyric")).toString()).trimmed();
    if (lyrics::wordLines(text) == 0) return LyricsStep::miss();
    LyricsResult r;
    r.text = text;
    r.timed = lyrics::hasTimestamps(text);
    r.source = QStringLiteral("NetEase Cloud Music");
    r.url = QUrl(QStringLiteral("https://music.163.com/#/song?id=%1").arg(prev.context.toLongLong()));
    return LyricsStep::found(r);
}

// ── KuGou ───────────────────────────────────────────────────────────────────

LyricsStep KugouProvider::start(const LyricsQuery &q) const {
    QUrl u(QStringLiteral("https://lyrics.kugou.com/search"));
    QUrlQuery qq;
    qq.addQueryItem(QStringLiteral("ver"), QStringLiteral("1"));
    qq.addQueryItem(QStringLiteral("man"), QStringLiteral("yes"));
    qq.addQueryItem(QStringLiteral("client"), QStringLiteral("pc"));
    qq.addQueryItem(QStringLiteral("keyword"), firstArtist(q) + QStringLiteral(" - ") + stripVersionParts(q.title));
    qq.addQueryItem(QStringLiteral("duration"), QString::number(qint64(q.duration) * 1000));
    qq.addQueryItem(QStringLiteral("hash"), QString());
    u.setQuery(qq);
    return LyricsStep::request(u, Search);
}

LyricsStep KugouProvider::next(const LyricsQuery &q, const LyricsStep &prev,
                               const LyricsReply &reply) const {
    if (reply.status != 200) return LyricsStep::failed();
    const QJsonObject root = QJsonDocument::fromJson(reply.body).object();
    if (prev.stage == Search) {
        for (const QJsonValue &v : root.value(QStringLiteral("candidates")).toArray()) {
            const QJsonObject c = v.toObject();
            if (!lyrics::titleMatches(q.title, c.value(QStringLiteral("song")).toString())
                || !lyrics::artistMatches(q.artists, c.value(QStringLiteral("singer")).toString())
                || !lyrics::durationMatches(q.duration, c.value(QStringLiteral("duration")).toDouble() / 1000.0))
                continue;
            QUrl u(QStringLiteral("https://lyrics.kugou.com/download"));
            QUrlQuery qq;
            qq.addQueryItem(QStringLiteral("ver"), QStringLiteral("1"));
            qq.addQueryItem(QStringLiteral("client"), QStringLiteral("pc"));
            qq.addQueryItem(QStringLiteral("id"), c.value(QStringLiteral("id")).toVariant().toString());
            qq.addQueryItem(QStringLiteral("accesskey"), c.value(QStringLiteral("accesskey")).toString());
            qq.addQueryItem(QStringLiteral("fmt"), QStringLiteral("lrc"));
            qq.addQueryItem(QStringLiteral("charset"), QStringLiteral("utf8"));
            u.setQuery(qq);
            return LyricsStep::request(u, Download);
        }
        return LyricsStep::miss();
    }

    const QByteArray lrc = QByteArray::fromBase64(root.value(QStringLiteral("content")).toString().toLatin1());
    const QString text = lyrics::stripCreditLines(QString::fromUtf8(lrc)).trimmed();
    // A handful of lines is a placeholder ("pure music, enjoy"), not lyrics.
    if (lyrics::wordLines(text) <= 3) return LyricsStep::miss();
    LyricsResult r;
    r.text = text;
    r.timed = lyrics::hasTimestamps(text);
    r.source = QStringLiteral("KuGou");
    r.url = QUrl(QStringLiteral("https://www.kugou.com/"));
    return LyricsStep::found(r);
}

// ── Genius ──────────────────────────────────────────────────────────────────

namespace {

QString geniusSlugPart(const QString &in) {
    QString out;
    for (const QChar c : in.normalized(QString::NormalizationForm_KD)) {
        if (c == u'&') { out += QStringLiteral(" and "); continue; }
        if (c.unicode() > 127) continue;
        if (c.isLetterOrNumber() || c == u' ' || c == u'-') out += c;
    }
    static const QRegularExpression gaps(QStringLiteral("[\\s-]+"));
    out.replace(gaps, QStringLiteral("-"));
    while (out.startsWith(u'-')) out.remove(0, 1);
    while (out.endsWith(u'-')) out.chop(1);
    return out.toLower();
}

QString geniusTitle(const QString &title) {
    static const QRegularExpression brackets(QStringLiteral("\\s*[\\(\\[][^\\)\\]]*[\\)\\]]"));
    QString t = QString(title).remove(brackets);
    const qsizetype dash = t.indexOf(QStringLiteral(" - "));
    if (dash > 0) t.truncate(dash);
    return t.trimmed();
}

} // namespace

QUrl GeniusProvider::pageUrl(const LyricsQuery &q) {
    const QString artist = geniusSlugPart(firstArtist(q));
    const QString title = geniusSlugPart(geniusTitle(q.title));
    if (artist.isEmpty() || title.isEmpty()) return {};
    QString slug = artist + u'-' + title;
    slug[0] = slug.at(0).toUpper();
    return QUrl(QStringLiteral("https://genius.com/") + slug + QStringLiteral("-lyrics"));
}

bool GeniusProvider::pageIsFor(const LyricsQuery &q, const QByteArray &bytes) {
    static const QRegularExpression titleTag(QStringLiteral("<title[^>]*>(.*?)</title>"),
                                             QRegularExpression::DotMatchesEverythingOption
                                             | QRegularExpression::CaseInsensitiveOption);
    const auto m = titleTag.match(QString::fromUtf8(bytes.left(256 * 1024)));
    if (!m.hasMatch()) return false;
    QString t = decodeEntities(m.captured(1)).simplified();
    static const QRegularExpression tail(QStringLiteral("\\s*\\|\\s*Genius Lyrics$"));
    static const QRegularExpression lyricsWord(QStringLiteral("\\s+Lyrics$"));
    t.remove(tail);
    t.remove(lyricsWord);
    const qsizetype dash = t.indexOf(QStringLiteral(" \u2013 "));
    if (dash <= 0) return false;
    return lyrics::artistMatches(q.artists, t.left(dash))
        && lyrics::titleMatches(q.title, t.mid(dash + 3));
}

LyricsStep GeniusProvider::start(const LyricsQuery &q) const {
    const QUrl u = pageUrl(q);
    return u.isValid() && !u.isEmpty() ? LyricsStep::request(u, 0) : LyricsStep::miss();
}

LyricsStep GeniusProvider::next(const LyricsQuery &q, const LyricsStep &prev,
                                const LyricsReply &reply) const {
    if (reply.status == 404) return LyricsStep::miss();
    if (reply.status != 200) return LyricsStep::failed();
    if (!pageIsFor(q, reply.body)) return LyricsStep::miss();
    LyricsResult r;
    r.text = lyrics::geniusLyricsFromHtml(reply.body);
    if (r.text.isEmpty()) return LyricsStep::miss();
    r.source = QStringLiteral("Genius");
    r.url = prev.url;
    return LyricsStep::found(r);
}
