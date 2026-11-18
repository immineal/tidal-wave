// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QImage>
#include <QObject>
#include <QString>
#include <QUrl>
#include <QVariantMap>
#include <functional>

#ifdef Q_OS_LINUX
#include <QDBusConnection>
#endif

// A desktop notification when a new track starts, off unless Settings turns
// it on. Not while the window is in front, as Lollypop and Rhythmbox do: the
// player bar already says it. Every outside dependency is a hook for tests.
class TrackNotifier : public QObject {
    Q_OBJECT
public:
    struct Notification {
        QString title;   // the track
        QString body;    // its artists, and the album on a second line
        QImage  cover;   // may be null
    };
    using Sender       = std::function<void(const Notification &)>;
    using CoverFetcher = std::function<void(const QUrl &, std::function<void(const QImage &)>)>;

    explicit TrackNotifier(QObject *parent = nullptr);

    void setEnabled(std::function<bool()> enabled)      { m_enabled = std::move(enabled); }
    void setWindowActive(std::function<bool()> active)  { m_windowActive = std::move(active); }
    void setSender(Sender send)                         { m_send = std::move(send); }
    // Without one, notifications carry no cover.
    void setCoverFetcher(CoverFetcher fetch)            { m_fetchCover = std::move(fetch); }

    // Called with Player's current track whenever it or the playing state
    // changes. A track is announced once, when it first plays.
    void update(const QVariantMap &track, bool playing);

#ifdef Q_OS_LINUX
    // Sends through org.freedesktop.Notifications on `bus`, each one replacing
    // the last, without sound.
    static Sender freedesktopSender(const QDBusConnection &bus, QObject *context);
#endif

private:
    std::function<bool()> m_enabled;
    std::function<bool()> m_windowActive;
    Sender       m_send;
    CoverFetcher m_fetchCover;
    qint64       m_lastTrack = 0;
    // Bumped per announcement, so a late cover for an earlier track is dropped.
    quint64      m_generation = 0;
};
