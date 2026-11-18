// SPDX-License-Identifier: GPL-3.0-or-later

#include "RowFilter.h"
#include "api/Fold.h"

#include <climits>

namespace {

constexpr int kRowRole = Qt::UserRole + 1;

// A missing field reads as empty, as `x || ""` does in QML.
QString textOf(const QJSValue &v) {
    if (v.isUndefined() || v.isNull()) return {};
    return v.toString();
}

} // namespace

RowFilter::RowFilter(QObject *parent) : QAbstractListModel(parent) {}

int RowFilter::rowCount(const QModelIndex &parent) const {
    return parent.isValid() ? 0 : int(m_shown.size());
}

QVariant RowFilter::data(const QModelIndex &index, int role) const {
    if (role != kRowRole || !index.isValid() || index.row() >= m_shown.size()) return {};
    return QVariant::fromValue(m_rows.at(m_shown.at(index.row())));
}

// One role, named as a JS array's is, so delegates read `modelData` either way.
QHash<int, QByteArray> RowFilter::roleNames() const {
    return {{kRowRole, QByteArrayLiteral("modelData")}};
}

void RowFilter::setSource(const QJSValue &rows) {
    if (rows.strictlyEquals(m_source)) return;
    m_source = rows;
    rebuild();
    emit sourceChanged();
}

void RowFilter::setFields(const QStringList &fields) {
    if (fields == m_fields) return;
    m_fields = fields;
    rebuild();
    emit fieldsChanged();
}

// A new list is new rows, so this is a reset. The lower-casing is done here,
// once per row, and never per key.
void RowFilter::rebuild() {
    const int before = count();
    beginResetModel();
    m_rows.clear();
    m_keys.clear();
    m_match.clear();
    m_shown.clear();
    // An array, or a list the bridge handed over, which reads the same way.
    const int n = m_source.isObject() ? m_source.property(QStringLiteral("length")).toInt() : 0;
    m_rows.reserve(n);
    m_keys.reserve(qsizetype(n) * m_fields.size());
    for (int i = 0; i < n; ++i) {
        const QJSValue row = m_source.property(quint32(i));
        m_rows << row;
        for (const QString &f : std::as_const(m_fields)) m_keys << Tidal::foldForMatch(textOf(row.property(f)));
    }
    for (int i = 0; i < n; ++i)
        if (matches(i, m_needle)) m_match << i;
    // A new list is laid out live or not: lists arrive seldom, keys often.
    m_shown = m_match;
    endResetModel();
    if (count() != before) emit countChanged();
}

bool RowFilter::matches(qsizetype row, const QString &needle) const {
    if (needle.isEmpty()) return true;
    const qsizetype w = m_fields.size();
    for (qsizetype f = 0; f < w; ++f)
        if (m_keys.at(row * w + f).contains(needle)) return true;
    return false;
}

void RowFilter::setPattern(const QString &pattern) {
    if (pattern == m_pattern) return;
    m_pattern = pattern;
    // Spaces at either end do not count, as in the sidebar's finder.
    const QString needle = Tidal::foldForMatch(pattern.trimmed());
    if (needle != m_needle) {
        // A needle that holds the last one can only narrow, so only the rows
        // still shown need looking at.
        const bool narrows = needle.contains(m_needle);
        QList<int> next;
        if (narrows) {
            for (int i : std::as_const(m_match))
                if (matches(i, needle)) next << i;
        } else {
            for (int i = 0; i < m_rows.size(); ++i)
                if (matches(i, needle)) next << i;
        }
        m_needle = needle;
        const bool resized = next.size() != m_match.size();
        m_match = next;
        if (m_live) applyShown(m_match);
        if (resized) emit countChanged();
    }
    emit patternChanged();
}

// Both lists are ascending indices into m_rows, so one walk finds every run
// that goes and every run that arrives. m_shown is edited as each signal goes
// out, so the model always reads what the signals have said so far.
void RowFilter::applyShown(const QList<int> &next) {
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

void RowFilter::setLive(bool live) {
    if (live == m_live) return;
    m_live = live;
    if (m_live) applyShown(m_match);
    emit liveChanged();
}

QJSValue RowFilter::rows() const {
    QJSEngine *engine = qjsEngine(this);
    if (!engine) return {};
    QJSValue out = engine->newArray(uint(m_match.size()));
    for (qsizetype i = 0; i < m_match.size(); ++i)
        out.setProperty(quint32(i), m_rows.at(m_match.at(i)));
    return out;
}

QJSValue RowFilter::get(int row) const {
    if (row < 0 || row >= m_match.size()) return {};
    return m_rows.at(m_match.at(row));
}
