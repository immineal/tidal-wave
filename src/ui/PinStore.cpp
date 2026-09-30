#include "PinStore.h"

PinStore::PinStore(QObject *parent) : QObject(parent) {}
void PinStore::setUserId(qint64 uid) { m_userId = uid; }
QVariantList PinStore::items() const { return m_items; }
bool PinStore::isPinned(const QString &, const QString &) const { return false; }
void PinStore::pin(const QString &, const QString &, const QString &, const QString &, const QString &) {}
void PinStore::unpin(const QString &, const QString &) {}
void PinStore::toggle(const QString &, const QString &, const QString &, const QString &, const QString &) {}
void PinStore::move(int, int) {}
