// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QAbstractListModel>
#include <QJSValue>
#include <QList>
#include <QQmlEngine>
#include <QStringList>

// A JS array as a view model, narrowed by a typed pattern: a row stays when one
// of `fields`, folded, contains the pattern folded (see api/Fold.h). A key only removes
// and inserts rows, so the rows that stay keep their delegates and covers.
class RowFilter : public QAbstractListModel {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QJSValue source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(QStringList fields READ fields WRITE setFields NOTIFY fieldsChanged)
    Q_PROPERTY(QString pattern READ pattern WRITE setPattern NOTIFY patternChanged)
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    // False holds the view's rows where they are while count and rows() follow
    // the pattern, so a hidden view makes no delegates; true catches it up.
    Q_PROPERTY(bool live READ live WRITE setLive NOTIFY liveChanged)
public:
    explicit RowFilter(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    QJSValue source() const { return m_source; }
    void setSource(const QJSValue &rows);
    QStringList fields() const { return m_fields; }
    void setFields(const QStringList &fields);
    QString pattern() const { return m_pattern; }
    void setPattern(const QString &pattern);
    int count() const { return int(m_match.size()); }
    bool live() const { return m_live; }
    void setLive(bool live);

    // The rows let through, in order, as a new array.
    Q_INVOKABLE QJSValue rows() const;
    Q_INVOKABLE QJSValue get(int row) const;

signals:
    void sourceChanged();
    void fieldsChanged();
    void patternChanged();
    void countChanged();
    void liveChanged();

private:
    void rebuild();
    bool matches(qsizetype row, const QString &needle) const;
    // Turns m_shown into `next` with the fewest removes and inserts.
    void applyShown(const QList<int> &next);

    QJSValue m_source;
    QStringList m_fields;
    QString m_pattern;
    QString m_needle;                // m_pattern folded
    QList<QJSValue> m_rows;
    QList<QString> m_keys;           // per row, each field folded once
    QList<int> m_match;              // indices into m_rows the pattern lets through
    QList<int> m_shown;              // the view's rows; m_match while live
    bool m_live = true;
};
