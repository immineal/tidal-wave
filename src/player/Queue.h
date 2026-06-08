#pragma once
#include <QObject>
#include <QList>
#include "api/Models.h"

using namespace Tidal;

class Queue : public QObject {
    Q_OBJECT
    Q_PROPERTY(int currentIndex READ currentIndex NOTIFY currentIndexChanged)
    Q_PROPERTY(bool shuffle     READ shuffle     WRITE setShuffle  NOTIFY shuffleChanged)
    Q_PROPERTY(int  repeatMode  READ repeatMode  WRITE setRepeatMode NOTIFY repeatModeChanged)

public:
    enum RepeatMode { NoRepeat, RepeatAll, RepeatOne };
    Q_ENUM(RepeatMode)

    explicit Queue(QObject *parent = nullptr);

    void setTracks(const QList<Track> &tracks, int startIndex = 0);
    void appendTracks(const QList<Track> &tracks);
    Q_INVOKABLE void jumpTo(int index);

    const Track  *current()      const;
    const Track  *peek(int delta) const;  // +1 next, -1 prev
    int           currentIndex() const { return m_index; }
    int           count()        const { return m_queue.count(); }
    bool          hasNext()      const;
    bool          hasPrev()      const;
    const QList<Track> &tracks() const { return m_queue; }

    bool shuffle()    const { return m_shuffle; }
    int  repeatMode() const { return m_repeatMode; }
    void setShuffle(bool s);
    void setRepeatMode(int m) { m_repeatMode = m; emit repeatModeChanged(); }

    Q_INVOKABLE bool advance();   // move to next, returns false if queue ended
    Q_INVOKABLE bool previous();

signals:
    void currentIndexChanged(int index);
    void queueChanged();
    void shuffleChanged();
    void repeatModeChanged();

private:
    QList<Track> m_queue;
    QList<int>   m_shuffleOrder;
    int          m_index       = -1;
    int          m_repeatMode  = NoRepeat;
    bool         m_shuffle     = false;

    void buildShuffleOrder();
    int  shuffleIndexOf(int queueIndex) const;
};
