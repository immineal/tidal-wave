// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include "scrobble/Listen.h"

// The rule ListenBrainz and Last.fm both document: a track longer than 30 s
// is a listen once half of it, or 4 minutes, has really been played. Only
// steady progress of the position counts, so pauses and seeks add nothing.
// Fed by Scrobbler from Player's signals; the clocks are passed in for tests.
class PlayTracker : public QObject {
    Q_OBJECT
public:
    static constexpr qint64 kMinTrackMs = 30000;
    static constexpr qint64 kEnoughMs   = 240000;
    // A step of the position this far ahead of the clock is a jump.
    static constexpr qint64 kSlackMs    = 2000;
    // Played on from this close to the start, a counted track is a new play.
    static constexpr qint64 kRestartMs  = 3000;

    explicit PlayTracker(QObject *parent = nullptr) : QObject(parent) {}

    // How much of a track has to be played; -1 for one too short to count.
    static qint64 thresholdMs(qint64 durationMs);

    // The track on show. The same track again changes nothing: a repeat is
    // seen in the position going back to the start.
    void setTrack(const Listen &track);
    void setPlaying(bool playing, qint64 nowMs);
    // A position report. nowMs is a monotonic clock, epochSec the wall clock.
    void position(qint64 posMs, qint64 nowMs, qint64 epochSec);
    // The user moved the position: the next step is no play.
    void seeked();

    qint64 playedMs() const { return m_played; }
    bool   counted()  const { return m_counted; }

signals:
    // The first second of a play: "playing now".
    void started(const Listen &listen);
    // The play crossed the threshold; listenedAt is when it started.
    void listened(const Listen &listen);

private:
    void beginPlay();

    Listen m_track;
    bool   m_playing  = false;
    qint64 m_lastPos  = -1;
    qint64 m_lastAt   = 0;
    bool   m_jumped   = false;
    bool   m_restart  = false;
    qint64 m_played   = 0;
    bool   m_started  = false;
    bool   m_counted  = false;
};
