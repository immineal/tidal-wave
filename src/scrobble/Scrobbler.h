// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QElapsedTimer>
#include <QList>
#include <QObject>
#include <QPointer>
#include "scrobble/PlayTracker.h"

class Player;
class ScrobbleSink;

// Watches the player, local or casting alike, and hands each play the
// tracker counts to every sink: one per service.
class Scrobbler : public QObject {
    Q_OBJECT
public:
    explicit Scrobbler(QObject *parent = nullptr);

    void addSink(ScrobbleSink *sink);
    void attach(Player *player);
    PlayTracker *tracker() { return &m_tracker; }

private:
    qint64 now() const { return m_clock.elapsed(); }

    PlayTracker m_tracker;
    QElapsedTimer m_clock;
    QList<QPointer<ScrobbleSink>> m_sinks;
};
