// SPDX-License-Identifier: GPL-3.0-or-later

#include "CountModel.h"

void CountModel::setCount(int n) {
    n = qMax(0, n);
    if (n == m_count) return;
    if (n > m_count) {
        beginInsertRows({}, m_count, n - 1);
        m_count = n;
        endInsertRows();
    } else {
        beginRemoveRows({}, n, m_count - 1);
        m_count = n;
        endRemoveRows();
    }
    emit countChanged();
}
