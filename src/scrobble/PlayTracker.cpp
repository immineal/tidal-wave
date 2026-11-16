// SPDX-License-Identifier: GPL-3.0-or-later

#include "scrobble/PlayTracker.h"
#include <QtGlobal>

qint64 PlayTracker::thresholdMs(qint64 durationMs) {
    if (durationMs <= kMinTrackMs) return -1;
    return qMin(durationMs / 2, kEnoughMs);
}

void PlayTracker::setTrack(const Listen &track) {
    if (track.trackId == m_track.trackId && track.trackId != 0) {
        // Same row, maybe with fuller details.
        m_track = track;
        return;
    }
    m_track   = track;
    m_lastPos = -1;
    m_jumped  = false;
    beginPlay();
}

void PlayTracker::beginPlay() {
    m_restart = false;
    m_played  = 0;
    m_started = false;
    m_counted = false;
    m_track.listenedAt = 0;
}

void PlayTracker::setPlaying(bool playing, qint64 nowMs) {
    if (playing == m_playing) return;
    m_playing = playing;
    // The time paused is not the time between two reports.
    m_lastAt = nowMs;
}

void PlayTracker::seeked() {
    m_jumped = true;
}

void PlayTracker::position(qint64 posMs, qint64 nowMs, qint64 epochSec) {
    if (!m_track.isValid()) return;
    const qint64 lastPos = m_lastPos;
    const qint64 lastAt  = m_lastAt;
    const bool   jumped  = m_jumped;
    m_lastPos = posMs;
    m_lastAt  = nowMs;
    m_jumped  = false;
    if (lastPos < 0) return;

    const qint64 step = posMs - lastPos;
    if (step < 0) {
        // Back near the start of a track that counted: a repeat, unless a
        // jump forward follows, as when a cast hands back and seeks on.
        m_restart = m_counted && posMs < kRestartMs;
        return;
    }
    const bool steady = step > 0 && step <= (nowMs - lastAt) + kSlackMs;
    if (!steady) {
        if (step > 0) m_restart = false;
        return;
    }
    if (!m_playing || jumped) return;
    if (m_restart) {
        if (lastPos < kRestartMs) beginPlay();
        m_restart = false;
    }
    if (!m_started) {
        m_started = true;
        // From the top, the play began a moment before this step.
        m_track.listenedAt = epochSec - (lastPos < kRestartMs ? lastPos / 1000 : 0);
        Listen now = m_track;
        now.listenedAt = 0;
        emit started(now);
    }
    m_played += step;
    const qint64 needed = thresholdMs(m_track.durationMs);
    if (!m_counted && needed >= 0 && m_played >= needed) {
        m_counted = true;
        emit listened(m_track);
    }
}
