// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QAbstractListModel>
#include <QQmlEngine>

// A model of `count` empty rows, for a view whose delegates work out what
// they show from their index. Unlike a plain number as a model, a new count
// adds or takes rows at the end, so the rows in view stay built.
class CountModel : public QAbstractListModel {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int count READ count WRITE setCount NOTIFY countChanged)
public:
    explicit CountModel(QObject *parent = nullptr) : QAbstractListModel(parent) {}

    int rowCount(const QModelIndex &parent = {}) const override { return parent.isValid() ? 0 : m_count; }
    QVariant data(const QModelIndex &, int) const override { return {}; }

    int count() const { return m_count; }
    void setCount(int n);

signals:
    void countChanged();

private:
    int m_count = 0;
};
