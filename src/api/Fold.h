// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QString>

namespace Tidal {

// The form text is matched in, as music apps match: case and accents do not
// count, and a sharp s is "ss". Decomposed, with the combining marks dropped.
inline QString foldForMatch(const QString &s) {
    // Most titles are plain ASCII, where lower case is the whole fold.
    bool ascii = true;
    for (const QChar c : s)
        if (c.unicode() >= 0x80) { ascii = false; break; }
    if (ascii) return s.toLower();
    const QString decomposed = s.normalized(QString::NormalizationForm_D);
    QString out;
    out.reserve(decomposed.size());
    for (const QChar c : decomposed) {
        switch (c.category()) {
        case QChar::Mark_NonSpacing:
        case QChar::Mark_SpacingCombining:
        case QChar::Mark_Enclosing:
            continue;
        default:
            out.append(c);
        }
    }
    // Case folding leaves the sharp s alone.
    return out.toCaseFolded().replace(QChar(0x00DF), QLatin1String("ss"));
}

} // namespace Tidal
