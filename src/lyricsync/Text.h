// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QByteArray>
#include <QString>
#include <QStringList>
#include <vector>

// Lyric text as the reference reads it: text.plain_lines() for the sung
// lines and common.tokens() for their letters (a..z as 1..26).
namespace lyricsync {

// Code point to lower-case ASCII letters, generated from Unidecode.
class Translit {
public:
    bool load(const QByteArray &data, QString *err);
    bool isEmpty() const { return m_cps.empty(); }
    // The letters for one code point at or above 0x80, or nullptr.
    const char *lookup(char32_t c, int *len) const;

private:
    std::vector<char32_t> m_cps;
    std::vector<uint32_t> m_offsets;   // m_cps.size() + 1 entries into m_text
    QByteArray m_text;
};

// Non-empty lines, stripped, without [Section] headers.
QStringList plainLines(const QString &text);
// The CTC tokens of one line.
std::vector<int> tokens(const QString &line, const Translit &table);

} // namespace lyricsync
