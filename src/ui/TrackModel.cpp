// SPDX-License-Identifier: GPL-3.0-or-later

#include "TrackModel.h"
#include "api/Fold.h"
#include "api/TrackRows.h"

#include <QCollator>
#include <QCollatorSortKey>
#include <QRegularExpression>

#include <algorithm>
#include <climits>
#include <cmath>
#include <optional>

namespace {

constexpr int kFields = 3;

// Number(x) || 0, as the JS sort reads a figure.
double figure(const QVariant &v, double otherwise = 0) {
    bool ok = false;
    const double d = v.toDouble(&ok);
    return ok && !std::isnan(d) && d != 0 ? d : otherwise;
}

} // namespace

TrackModel::TrackModel(QObject *parent) : QAbstractListModel(parent) {}

int TrackModel::rowCount(const QModelIndex &parent) const {
    return parent.isValid() ? 0 : int(m_shown.size());
}

QVariant TrackModel::data(const QModelIndex &index, int role) const {
    if (!index.isValid() || index.row() >= m_shown.size()) return {};
    const int src = m_order.at(m_shown.at(index.row()));
    if (role == PlaceRole) return src;
    if (role != RowRole) return {};
    QJSValue &js = m_js[src];
    if (js.isUndefined()) {
        QJSEngine *engine = qjsEngine(this);
        if (!engine) return m_rows.at(src);
        js = engine->toScriptValue(m_rows.at(src));
    }
    return QVariant::fromValue(js);
}

// modelData, as a JS array's rows are named, and each row's place in the source.
QHash<int, QByteArray> TrackModel::roleNames() const {
    return {{RowRole, QByteArrayLiteral("modelData")}, {PlaceRole, QByteArrayLiteral("place")}};
}

// A new list is new rows, so this is a reset, as a new JS array was. A JS
// array arrives as a QJSValue, its rows as maps once converted.
void TrackModel::setSource(const QVariant &source) {
    QVariantList rows;
    if (source.metaType() == QMetaType::fromType<TrackRows>())
        rows = source.value<TrackRows>().rows;
    else if (source.metaType() == QMetaType::fromType<QJSValue>())
        rows = source.value<QJSValue>().toVariant().toList();
    else
        rows = source.toList();
    for (QVariant &row : rows)
        if (row.metaType() == QMetaType::fromType<QJSValue>()) row = row.value<QJSValue>().toVariant();
    const int before = count();
    beginResetModel();
    m_source = source;
    m_rows = rows;
    m_keys.clear();
    m_js = QList<QJSValue>(m_rows.size());
    resort();
    m_match = matching();
    m_shown = m_match;
    endResetModel();
    emit sourceChanged();
    if (count() != before) emit countChanged();
}

void TrackModel::setSortKey(const QString &key) {
    if (key == m_sortKey) return;
    m_sortKey = key;
    beginResetModel();
    resort();
    m_match = matching();
    m_shown = m_match;
    endResetModel();
    emit sortKeyChanged();
}

void TrackModel::setDescending(bool d) {
    if (d == m_descending) return;
    m_descending = d;
    if (!m_sortKey.isEmpty()) {
        beginResetModel();
        resort();
        m_match = matching();
        m_shown = m_match;
        endResetModel();
    }
    emit descendingChanged();
}

// TrackListHeader.Sort.order(): stable, and a row with no date added goes last
// either way. Strings compare as JS localeCompare does, in the app's locale.
void TrackModel::resort() {
    const qsizetype n = m_rows.size();
    m_order.resize(n);
    for (qsizetype i = 0; i < n; ++i) m_order[i] = int(i);
    const QString &k = m_sortKey;
    const bool byText = k == QLatin1String("title") || k == QLatin1String("album");
    const bool byFigure = k == QLatin1String("added") || k == QLatin1String("duration");
    if (!byText && !byFigure) return;

    const QString field = k == QLatin1String("title") ? QStringLiteral("title")
                        : k == QLatin1String("album") ? QStringLiteral("albumTitle")
                        : k == QLatin1String("added") ? QStringLiteral("addedAt")
                                                      : QStringLiteral("duration");
    QCollator collator;
    QList<QCollatorSortKey> texts;
    QList<double> figures;
    if (byText) {
        texts.reserve(n);
        for (const QVariant &row : std::as_const(m_rows))
            texts << collator.sortKey(row.toMap().value(field).toString().toLower());
    } else {
        figures.reserve(n);
        for (const QVariant &row : std::as_const(m_rows)) figures << figure(row.toMap().value(field));
    }
    const bool album = k == QLatin1String("album"), added = k == QLatin1String("added");
    const bool desc = m_descending;
    std::stable_sort(m_order.begin(), m_order.end(), [&](int a, int b) {
        if (added && (figures[a] == 0) != (figures[b] == 0)) return figures[b] == 0;
        double c = byText ? texts[a].compare(texts[b]) : figures[a] - figures[b];
        if (c == 0 && album) {
            const QVariantMap ta = m_rows[a].toMap(), tb = m_rows[b].toMap();
            c = figure(ta.value(QStringLiteral("volumeNumber")), 1) - figure(tb.value(QStringLiteral("volumeNumber")), 1);
            if (c == 0) c = figure(ta.value(QStringLiteral("trackNumber"))) - figure(tb.value(QStringLiteral("trackNumber")));
        }
        return desc ? c > 0 : c < 0;
    });
}

// Folded once per row, and only once a pattern is typed.
void TrackModel::ensureKeys() const {
    if (!m_keys.isEmpty() || m_rows.isEmpty()) return;
    m_keys.reserve(m_rows.size() * kFields);
    static const QString fields[kFields] = {QStringLiteral("title"), QStringLiteral("artists"),
                                            QStringLiteral("albumTitle")};
    for (const QVariant &row : std::as_const(m_rows)) {
        const QVariantMap t = row.toMap();
        for (const QString &f : fields) m_keys << Tidal::foldForMatch(t.value(f).toString());
    }
}

bool TrackModel::matches(int src) const {
    const qsizetype at = qsizetype(src) * kFields;
    for (const QString &w : m_words) {
        bool found = false;
        for (int f = 0; f < kFields && !found; ++f) found = m_keys.at(at + f).contains(w);
        if (!found) return false;
    }
    return true;
}

QList<int> TrackModel::matching() const {
    QList<int> out;
    out.reserve(m_order.size());
    if (m_words.isEmpty()) {
        for (qsizetype p = 0; p < m_order.size(); ++p) out << int(p);
        return out;
    }
    ensureKeys();
    for (qsizetype p = 0; p < m_order.size(); ++p)
        if (matches(m_order.at(p))) out << int(p);
    return out;
}

void TrackModel::setPattern(const QString &pattern) {
    if (pattern == m_pattern) return;
    m_pattern = pattern;
    refilter();
    emit patternChanged();
}

void TrackModel::setEveryWord(bool on) {
    if (on == m_everyWord) return;
    m_everyWord = on;
    refilter();
    emit everyWordChanged();
}

// A key only removes and inserts rows, so the rows that stay keep their delegates.
void TrackModel::refilter() {
    QStringList words;
    if (m_everyWord) {
        static const QRegularExpression space(QStringLiteral("\\s+"));
        words = Tidal::foldForMatch(m_pattern).split(space, Qt::SkipEmptyParts);
    } else {
        const QString needle = Tidal::foldForMatch(m_pattern.trimmed());
        if (!needle.isEmpty()) words << needle;
    }
    if (words == m_words) return;
    m_words = words;
    const QList<int> next = matching();
    const bool resized = next.size() != m_match.size();
    m_match = next;
    if (m_live) applyShown(m_match);
    if (resized) emit countChanged();
}

// As RowFilter::applyShown: both lists ascend, so one walk finds each run that
// goes and each that arrives, and the model reads what the signals said so far.
void TrackModel::applyShown(const QList<int> &next) {
    qsizetype pos = 0, j = 0;
    while (pos < m_shown.size() || j < next.size()) {
        const bool haveOld = pos < m_shown.size();
        const bool haveNew = j < next.size();
        if (haveOld && haveNew && m_shown.at(pos) == next.at(j)) {
            ++pos;
            ++j;
        } else if (!haveNew || (haveOld && m_shown.at(pos) < next.at(j))) {
            const int limit = haveNew ? next.at(j) : INT_MAX;
            qsizetype end = pos;
            while (end < m_shown.size() && m_shown.at(end) < limit) ++end;
            beginRemoveRows({}, int(pos), int(end - 1));
            m_shown.remove(pos, end - pos);
            endRemoveRows();
        } else {
            const int limit = haveOld ? m_shown.at(pos) : INT_MAX;
            qsizetype end = j;
            while (end < next.size() && next.at(end) < limit) ++end;
            const qsizetype n = end - j;
            beginInsertRows({}, int(pos), int(pos + n - 1));
            m_shown.insert(pos, n, 0);
            for (qsizetype k = 0; k < n; ++k) m_shown[pos + k] = next.at(j + k);
            endInsertRows();
            pos += n;
            j = end;
        }
    }
}

void TrackModel::setLive(bool live) {
    if (live == m_live) return;
    m_live = live;
    if (m_live) applyShown(m_match);
    emit liveChanged();
}

QStringList TrackModel::leadCovers() const {
    QStringList out;
    for (const QVariant &row : std::as_const(m_rows)) {
        const QString c = row.toMap().value(QStringLiteral("coverUrl")).toString();
        if (c.isEmpty() || out.contains(c)) continue;
        out << c;
        if (out.size() == 4) break;
    }
    return out;
}

QVariantList TrackModel::rows() const {
    QVariantList out;
    out.reserve(m_match.size());
    for (int p : m_match) out << m_rows.at(m_order.at(p));
    return out;
}

QVariant TrackModel::shownRows() const { return Tidal::wrapRows(rows()); }

QVariant TrackModel::sortedRows() const {
    if (m_sortKey.isEmpty()) return Tidal::wrapRows(m_rows);
    QVariantList out;
    out.reserve(m_order.size());
    for (int src : m_order) out << m_rows.at(src);
    return Tidal::wrapRows(std::move(out));
}

QVariant TrackModel::get(int row) const {
    if (row < 0 || row >= m_match.size()) return {};
    return m_rows.at(m_order.at(m_match.at(row)));
}

int TrackModel::countOf(const QVariant &trackId) const {
    const double id = trackId.toDouble();
    int n = 0;
    for (const QVariant &row : std::as_const(m_rows))
        if (row.toMap().value(QStringLiteral("id")).toDouble() == id) ++n;
    return n;
}

QVariant TrackModel::withMoved(int from, int to) const {
    QVariantList out = m_rows;
    if (from >= 0 && from < out.size() && to >= 0 && to < out.size()) out.move(from, to);
    return Tidal::wrapRows(std::move(out));
}

QVariant TrackModel::withRemoved(int at) const {
    QVariantList out = m_rows;
    if (at >= 0 && at < out.size()) out.removeAt(at);
    return Tidal::wrapRows(std::move(out));
}
