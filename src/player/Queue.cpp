#include "Queue.h"
#include <QRandomGenerator>
#include <algorithm>

Queue::Queue(QObject *parent) : QObject(parent) {}

void Queue::setTracks(const QList<Track> &tracks, int startIndex) {
    m_queue = tracks;
    m_index = startIndex;
    if (m_shuffle) buildShuffleOrder();
    emit queueChanged();
    emit currentIndexChanged(m_index);
}

void Queue::appendTracks(const QList<Track> &tracks) {
    m_queue.append(tracks);
    if (m_shuffle) buildShuffleOrder();
    emit queueChanged();
}

void Queue::jumpTo(int index) {
    if (index < 0 || index >= m_queue.count()) return;
    m_index = index;
    emit currentIndexChanged(m_index);
}

const Track *Queue::current() const {
    if (m_index < 0 || m_index >= m_queue.count()) return nullptr;
    return &m_queue[m_index];
}

bool Queue::hasNext() const {
    if (m_repeatMode == RepeatAll) return !m_queue.isEmpty();
    if (m_repeatMode == RepeatOne) return true;
    if (m_shuffle) {
        int si = shuffleIndexOf(m_index);
        return si < m_shuffleOrder.count() - 1;
    }
    return m_index < m_queue.count() - 1;
}

bool Queue::hasPrev() const {
    return m_index > 0;
}

bool Queue::advance() {
    if (m_repeatMode == RepeatOne) {
        emit currentIndexChanged(m_index);
        return true;
    }
    if (m_shuffle) {
        int si = shuffleIndexOf(m_index);
        if (si < 0) return false;
        si++;
        if (si >= m_shuffleOrder.count()) {
            if (m_repeatMode == RepeatAll) {
                buildShuffleOrder();
                m_index = m_shuffleOrder[0];
            } else return false;
        } else {
            m_index = m_shuffleOrder[si];
        }
    } else {
        if (m_index >= m_queue.count() - 1) {
            if (m_repeatMode == RepeatAll) m_index = 0;
            else return false;
        } else {
            m_index++;
        }
    }
    emit currentIndexChanged(m_index);
    return true;
}

bool Queue::previous() {
    if (m_index <= 0) return false;
    m_index--;
    emit currentIndexChanged(m_index);
    return true;
}

void Queue::setShuffle(bool s) {
    m_shuffle = s;
    if (s) buildShuffleOrder();
    emit shuffleChanged();
}

void Queue::buildShuffleOrder() {
    m_shuffleOrder.resize(m_queue.count());
    std::iota(m_shuffleOrder.begin(), m_shuffleOrder.end(), 0);
    // Fisher-Yates
    for (int i = m_shuffleOrder.count() - 1; i > 0; --i) {
        int j = QRandomGenerator::global()->bounded(i + 1);
        std::swap(m_shuffleOrder[i], m_shuffleOrder[j]);
    }
    // Ensure current track is first in shuffle order
    if (m_index >= 0) {
        int pos = m_shuffleOrder.indexOf(m_index);
        if (pos > 0) std::swap(m_shuffleOrder[0], m_shuffleOrder[pos]);
    }
}

int Queue::shuffleIndexOf(int queueIndex) const {
    return m_shuffleOrder.indexOf(queueIndex);
}

const Track *Queue::peek(int delta) const {
    int next = m_index + delta;
    if (next < 0 || next >= m_queue.count()) return nullptr;
    return &m_queue[next];
}
