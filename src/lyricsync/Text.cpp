// SPDX-License-Identifier: GPL-3.0-or-later

#include "Text.h"

#include <algorithm>
#include <cstring>

namespace lyricsync {

namespace {

// Python's str.isspace() for the characters lyrics carry.
bool isSpace(char32_t c) {
    return (c >= 0x09 && c <= 0x0D) || (c >= 0x1C && c <= 0x20) || c == 0x85 || c == 0xA0 || c == 0x1680
        || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F
        || c == 0x3000;
}

// str.splitlines() boundaries; \r\n counts once.
bool isLineBreak(char32_t c) {
    return c == '\n' || c == '\r' || c == 0x0B || c == 0x0C || c == 0x1C || c == 0x1D || c == 0x1E
        || c == 0x85 || c == 0x2028 || c == 0x2029;
}

QString pyStrip(const QString &s) {
    const QList<uint> u = s.toUcs4();
    qsizetype a = 0, b = u.size();
    while (a < b && isSpace(u[a])) ++a;
    while (b > a && isSpace(u[b - 1])) --b;
    return QString::fromUcs4(reinterpret_cast<const char32_t *>(u.constData() + a), b - a);
}

// Genius marks copies with Cyrillic look-alikes inside Latin words.
char32_t unhomoglyph(char32_t c) {
    static const char32_t from[] = {0x430, 0x435, 0x43E, 0x440, 0x441, 0x445, 0x443, 0x456,
                                    0x410, 0x415, 0x41E, 0x420, 0x421, 0x425, 0x423, 0x406};
    static const char to[] = "aeopcxyiAEOPCXYI";
    for (int i = 0; i < 16; ++i)
        if (from[i] == c) return char32_t(to[i]);
    return c;
}

bool isAsciiLetter(char32_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }

} // namespace

bool Translit::load(const QByteArray &data, QString *err) {
    m_cps.clear(); m_offsets.clear(); m_text.clear();
    if (data.size() < 12 || std::memcmp(data.constData(), "LSYNTRL1", 8) != 0) {
        if (err) *err = QStringLiteral("not a transliteration table");
        return false;
    }
    uint32_t n = 0;
    std::memcpy(&n, data.constData() + 8, 4);
    qsizetype at = 12;
    m_cps.reserve(n);
    m_offsets.reserve(size_t(n) + 1);
    for (uint32_t i = 0; i < n; ++i) {
        if (at + 5 > data.size()) break;
        uint32_t cp = 0;
        std::memcpy(&cp, data.constData() + at, 4);
        const int len = static_cast<unsigned char>(data.at(at + 4));
        at += 5;
        if (at + len > data.size() || (!m_cps.empty() && cp <= m_cps.back())) break;
        m_cps.push_back(cp);
        m_offsets.push_back(uint32_t(m_text.size()));
        m_text.append(data.constData() + at, len);
        at += len;
    }
    m_offsets.push_back(uint32_t(m_text.size()));
    if (m_cps.size() != n || at != data.size()) {
        if (err) *err = QStringLiteral("transliteration table is damaged");
        m_cps.clear(); m_offsets.clear(); m_text.clear();
        return false;
    }
    return true;
}

const char *Translit::lookup(char32_t c, int *len) const {
    const auto it = std::lower_bound(m_cps.begin(), m_cps.end(), c);
    if (it == m_cps.end() || *it != c) return nullptr;
    const size_t i = size_t(it - m_cps.begin());
    *len = int(m_offsets[i + 1] - m_offsets[i]);
    return m_text.constData() + m_offsets[i];
}

QStringList plainLines(const QString &text) {
    QStringList out;
    const QList<uint> u = text.toUcs4();
    qsizetype from = 0;
    auto take = [&](qsizetype to) {
        const QString s = pyStrip(QString::fromUcs4(reinterpret_cast<const char32_t *>(u.constData() + from), to - from));
        // A line that is all "[...]" is a section header, not sung.
        const bool header = s.size() >= 2 && s.startsWith(u'[') && s.endsWith(u']')
                         && !s.mid(1, s.size() - 2).contains(u']');
        if (!s.isEmpty() && !header) out << s;
    };
    for (qsizetype i = 0; i < u.size(); ++i) {
        if (!isLineBreak(u[i])) continue;
        take(i);
        if (u[i] == '\r' && i + 1 < u.size() && u[i + 1] == '\n') ++i;
        from = i + 1;
    }
    if (from < u.size()) take(u.size());
    return out;
}

std::vector<int> tokens(const QString &line, const Translit &table) {
    // text.norm(): look-alikes folded in words with Latin letters, lower case,
    // NFKD; then unidecode, keeping a..z. Marks and symbols carry no letters.
    QList<uint> u = line.toUcs4();
    for (qsizetype i = 0; i < u.size();) {
        if (isSpace(u[i])) { ++i; continue; }
        qsizetype j = i;
        bool latin = false;
        for (; j < u.size() && !isSpace(u[j]); ++j)
            if (isAsciiLetter(u[j])) latin = true;
        if (latin)
            for (qsizetype k = i; k < j; ++k) u[k] = unhomoglyph(u[k]);
        i = j;
    }
    const QString folded = QString::fromUcs4(reinterpret_cast<const char32_t *>(u.constData()), u.size())
                               .toLower()
                               .normalized(QString::NormalizationForm_KD);
    std::vector<int> out;
    for (const uint c : folded.toUcs4()) {
        if (c < 0x80) {
            if (isAsciiLetter(c)) out.push_back(int((c | 0x20) - 'a') + 1);
            continue;
        }
        int len = 0;
        const char *p = table.lookup(c, &len);
        for (int k = 0; p && k < len; ++k) out.push_back(p[k] - 'a' + 1);
    }
    return out;
}

} // namespace lyricsync
