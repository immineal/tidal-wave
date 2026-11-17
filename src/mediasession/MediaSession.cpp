// SPDX-License-Identifier: GPL-3.0-or-later

#include "mediasession/MediaSession.h"

#include <QStringList>
#include <QVariantList>

#include "player/Player.h"

MediaSession::MediaSession(QObject *parent) : QObject(parent) {}

MediaSession::~MediaSession() = default;

void MediaSession::setBackend(std::unique_ptr<MediaSessionBackend> backend) {
    m_backend = std::move(backend);
    m_sent = false;
    if (m_backend) {
        m_backend->update(m_state);
        m_sent = true;
    }
}

void MediaSession::setState(const MediaSessionState &state) {
    if (m_sent && state == m_state) return;
    m_state = state;
    if (!m_backend) return;
    m_backend->update(m_state);
    m_sent = true;
}

void MediaSession::handle(Command command) {
    switch (command) {
    case Command::Play:      emit playRequested();      break;
    case Command::Pause:     emit pauseRequested();     break;
    case Command::PlayPause: emit playPauseRequested(); break;
    case Command::Next:      emit nextRequested();      break;
    case Command::Previous:  emit previousRequested();  break;
    case Command::Stop:      emit stopRequested();      break;
    }
}

// One string for the artists, as both platforms take it. A row from an older
// version has only the joined string, which is used as it is.
static QString artistLine(const QVariantMap &track) {
    QStringList names;
    const QVariantList artists = track.value(QStringLiteral("artistList")).toList();
    for (const QVariant &artist : artists) {
        const QString name = artist.toMap().value(QStringLiteral("name")).toString();
        if (!name.isEmpty()) names.append(name);
    }
    if (!names.isEmpty()) return names.join(QStringLiteral(", "));
    return track.value(QStringLiteral("artists")).toString();
}

MediaSessionState MediaSession::stateFrom(const QVariantMap &track, bool playing, bool stopped,
                                          qint64 positionMs, qint64 durationMs, bool hasNext) {
    MediaSessionState s;
    if (track.value(QStringLiteral("id")).toLongLong() <= 0) return s;

    s.title    = track.value(QStringLiteral("title")).toString();
    s.artist   = artistLine(track);
    s.album    = track.value(QStringLiteral("albumTitle")).toString();
    s.coverUrl = track.value(QStringLiteral("coverUrl")).toString();
    // The loaded length, and the catalogue's until something is loaded.
    s.durationMs = durationMs > 0
        ? durationMs
        : track.value(QStringLiteral("duration")).toLongLong() * 1000;
    s.positionMs  = qMax<qint64>(0, positionMs);
    s.playback    = playing ? MediaSessionState::Playback::Playing
                  : stopped ? MediaSessionState::Playback::Stopped
                            : MediaSessionState::Playback::Paused;
    s.canNext     = hasNext;
    s.canPrevious = true;   // Previous at least restarts the track.
    return s;
}

void MediaSession::attach(Player *player) {
    const auto refresh = [this, player] {
        setState(stateFrom(player->currentTrackMap(), player->playing(), player->stopped(),
                           player->position(), player->duration(), player->hasNext()));
    };
    // Not positionChanged: the controls count the time on by themselves.
    connect(player, &Player::playingChanged,      this, refresh);
    connect(player, &Player::stoppedChanged,      this, refresh);
    connect(player, &Player::currentTrackChanged, this, refresh);
    connect(player, &Player::durationChanged,     this, refresh);
    connect(player, &Player::seeked,              this, refresh);
    connect(player, &Player::queueChanged,        this, refresh);
    connect(player, &Player::currentIndexChanged, this, refresh);

    // The same calls as MPRIS: a paused player stays paused across a step.
    connect(this, &MediaSession::playRequested, player, [player] {
        if (!player->playing()) player->playPause();
    });
    connect(this, &MediaSession::pauseRequested, player, [player] {
        if (player->playing()) player->playPause();
    });
    connect(this, &MediaSession::playPauseRequested, player, [player] { player->playPause(); });
    connect(this, &MediaSession::nextRequested, player, [player] { player->next(!player->playing()); });
    connect(this, &MediaSession::previousRequested, player, [player] {
        player->previous(!player->playing());
    });
    connect(this, &MediaSession::stopRequested, player, [player] { player->stop(); });
    refresh();
}

#ifndef TIDALWAVE_PLATFORM_MEDIA_SESSION
// CMake sets that where it compiles a backend: MSVC on Windows, and macOS.
std::unique_ptr<MediaSessionBackend> MediaSession::createPlatformBackend(MediaSession *, QWindow *) {
    return nullptr;
}
#endif
