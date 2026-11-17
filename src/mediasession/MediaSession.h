// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <memory>

class Player;
class QWindow;

// What the desktop's media controls show: Windows' transport controls and
// macOS's Now Playing. Linux has MPRIS (src/mpris), which reads Player itself.
struct MediaSessionState {
    enum class Playback { Stopped, Playing, Paused };

    Playback playback = Playback::Stopped;
    QString  title;
    QString  artist;
    QString  album;
    // An https URL, or empty for a track without one.
    QString  coverUrl;
    qint64   durationMs  = 0;
    qint64   positionMs  = 0;
    bool     canNext     = false;
    bool     canPrevious = false;

    bool hasTrack() const { return !title.isEmpty(); }
    friend bool operator==(const MediaSessionState &a, const MediaSessionState &b) {
        return a.playback == b.playback && a.title == b.title && a.artist == b.artist
            && a.album == b.album && a.coverUrl == b.coverUrl
            && a.durationMs == b.durationMs && a.positionMs == b.positionMs
            && a.canNext == b.canNext && a.canPrevious == b.canPrevious;
    }
    friend bool operator!=(const MediaSessionState &a, const MediaSessionState &b) {
        return !(a == b);
    }
};

// One platform's controls. It shows what update() hands it and passes the
// buttons the user presses to MediaSession::handle() on the GUI thread.
class MediaSessionBackend {
public:
    virtual ~MediaSessionBackend() = default;
    virtual void update(const MediaSessionState &state) = 0;
};

// Sits between Player and a backend, the way TrayMenu does for the tray: the
// state goes out through setState(), the presses come back as signals.
class MediaSession : public QObject {
    Q_OBJECT
public:
    enum class Command { Play, Pause, PlayPause, Next, Previous, Stop };

    explicit MediaSession(QObject *parent = nullptr);
    ~MediaSession() override;

    // Takes ownership. Null leaves the session without controls.
    void setBackend(std::unique_ptr<MediaSessionBackend> backend);
    MediaSessionBackend *backend() const { return m_backend.get(); }

    // Hands the state on when it differs from the last one sent.
    void setState(const MediaSessionState &state);
    const MediaSessionState &state() const { return m_state; }

    // What a backend calls when a button is pressed.
    void handle(Command command);

    // The state for a track map from TidalBridge and the player's flags, read
    // the way MPRIS reads them.
    static MediaSessionState stateFrom(const QVariantMap &track, bool playing, bool stopped,
                                       qint64 positionMs, qint64 durationMs, bool hasNext);

    // Follows `player` and sends the presses back to it.
    void attach(Player *player);

    // This platform's backend for `window`, or null where there is none (Linux).
    static std::unique_ptr<MediaSessionBackend> createPlatformBackend(MediaSession *session,
                                                                      QWindow *window);

signals:
    void playRequested();
    void pauseRequested();
    void playPauseRequested();
    void nextRequested();
    void previousRequested();
    void stopRequested();

private:
    std::unique_ptr<MediaSessionBackend> m_backend;
    MediaSessionState m_state;
    bool m_sent = false;
};
