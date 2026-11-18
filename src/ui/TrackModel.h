// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QAbstractListModel>
#include <QJSValue>
#include <QList>
#include <QQmlEngine>
#include <QStringList>
#include <QVariantList>

// A list of tracks as a view model: sorted by a column heading and narrowed
// by a typed pattern, as TrackListHeader.Sort and RowFilter do in JS. A row
// becomes a JS object only once it is shown. See api/TrackRows.h.
class TrackModel : public QAbstractListModel {
    Q_OBJECT
    QML_ELEMENT
    // The bridge's TrackRows, or any list of track maps, a JS array too.
    Q_PROPERTY(QVariant source READ source WRITE setSource NOTIFY sourceChanged)
    // Every row of the source, shown or not.
    Q_PROPERTY(int length READ length NOTIFY sourceChanged)
    // As TrackListHeader.Sort: "", "title", "album", "added" or "duration".
    Q_PROPERTY(QString sortKey READ sortKey WRITE setSortKey NOTIFY sortKeyChanged)
    Q_PROPERTY(bool descending READ descending WRITE setDescending NOTIFY descendingChanged)
    Q_PROPERTY(QString pattern READ pattern WRITE setPattern NOTIFY patternChanged)
    // False: a row stays when one field holds the whole pattern (Collection).
    // True: when every word of it is in some field (a playlist's own field).
    Q_PROPERTY(bool everyWord READ everyWord WRITE setEveryWord NOTIFY everyWordChanged)
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    // As RowFilter.live.
    Q_PROPERTY(bool live READ live WRITE setLive NOTIFY liveChanged)
    // The first four distinct covers, in the list's order, for a hero's mosaic.
    Q_PROPERTY(QStringList leadCovers READ leadCovers NOTIFY sourceChanged)
public:
    enum Roles { RowRole = Qt::UserRole + 1, PlaceRole };

    explicit TrackModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    QVariant source() const { return m_source; }
    void setSource(const QVariant &source);
    int length() const { return int(m_rows.size()); }
    QString sortKey() const { return m_sortKey; }
    void setSortKey(const QString &key);
    bool descending() const { return m_descending; }
    void setDescending(bool d);
    QString pattern() const { return m_pattern; }
    void setPattern(const QString &pattern);
    bool everyWord() const { return m_everyWord; }
    void setEveryWord(bool on);
    int count() const { return int(m_match.size()); }
    bool live() const { return m_live; }
    void setLive(bool live);
    QStringList leadCovers() const;

    // The rows let through in the order shown, and every row in the order of
    // the headings, as TrackRows: for the player, which takes them unconverted.
    Q_INVOKABLE QVariant shownRows() const;
    Q_INVOKABLE QVariant sortedRows() const;
    // The rows let through, and the source, as lists JS can read.
    Q_INVOKABLE QVariantList rows() const;
    Q_INVOKABLE QVariantList list() const { return m_rows; }
    Q_INVOKABLE QVariant get(int row) const;
    Q_INVOKABLE QVariant sourceAt(int at) const { return m_rows.value(at); }
    // How many rows of the source are this track.
    Q_INVOKABLE int countOf(const QVariant &trackId) const;
    // The source with one row moved or taken out, for the page to hand back.
    Q_INVOKABLE QVariant withMoved(int from, int to) const;
    Q_INVOKABLE QVariant withRemoved(int at) const;

signals:
    void sourceChanged();
    void sortKeyChanged();
    void descendingChanged();
    void patternChanged();
    void everyWordChanged();
    void countChanged();
    void liveChanged();

private:
    void resort();
    void ensureKeys() const;
    QList<int> matching() const;
    bool matches(int src) const;
    void refilter();
    void applyShown(const QList<int> &next);

    QVariant m_source;
    QVariantList m_rows;
    QString m_sortKey;
    bool m_descending = false;
    QString m_pattern;
    QStringList m_words;           // the pattern folded: one needle, or its words
    bool m_everyWord = false;
    bool m_live = true;
    QList<int> m_order;            // source index of each sorted position
    QList<int> m_match;            // sorted positions the pattern lets through
    QList<int> m_shown;            // the view's rows; m_match while live
    mutable QList<QString> m_keys; // per source row: title, artists, album, folded
    mutable QList<QJSValue> m_js;  // per source row, made when first shown
};
