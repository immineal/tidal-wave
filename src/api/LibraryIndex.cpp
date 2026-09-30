#include "LibraryIndex.h"

LibraryIndex::LibraryIndex(TidalClient *client, PinStore *pins, QObject *parent)
    : QObject(parent), m_client(client), m_pins(pins) {}

QVariantList LibraryIndex::entries() const { return {}; }
bool LibraryIndex::loading() const { return false; }
void LibraryIndex::setUserId(qint64 uid) { m_userId = uid; }
void LibraryIndex::markPlayed(const QString &, const QString &) {}
QVariantList LibraryIndex::search(const QString &, const QStringList &) const { return {}; }
