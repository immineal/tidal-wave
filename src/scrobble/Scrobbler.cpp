// SPDX-License-Identifier: GPL-3.0-or-later

#include "scrobble/Scrobbler.h"
#include "scrobble/ScrobbleSink.h"
#include "player/Player.h"
#include <QDateTime>

Scrobbler::Scrobbler(QObject *parent) : QObject(parent) {
    m_clock.start();
    connect(&m_tracker, &PlayTracker::started, this, [this](const Listen &l) {
        for (const auto &s : std::as_const(m_sinks)) if (s) s->nowPlaying(l);
    });
    connect(&m_tracker, &PlayTracker::listened, this, [this](const Listen &l) {
        for (const auto &s : std::as_const(m_sinks)) if (s) s->add(l);
    });
}

void Scrobbler::addSink(ScrobbleSink *sink) {
    m_sinks.append(sink);
}

void Scrobbler::attach(Player *player) {
    const auto track = [this, player] {
        m_tracker.setTrack(Listen::fromTrackMap(player->currentTrackMap()));
    };
    connect(player, &Player::currentTrackChanged, this, track);
    connect(player, &Player::playingChanged, this, [this](bool playing) {
        m_tracker.setPlaying(playing, now());
    });
    connect(player, &Player::positionChanged, this, [this](qint64 ms) {
        m_tracker.position(ms, now(), QDateTime::currentSecsSinceEpoch());
    });
    connect(player, &Player::seeked, this, [this] { m_tracker.seeked(); });
    track();
    m_tracker.setPlaying(player->playing(), now());
}
