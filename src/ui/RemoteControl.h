// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>
#include <functional>
#include <optional>

class QLocalServer;

// What one launch asks for, from its command line. A second launch hands it to
// the running instance over the single-instance socket.
struct LaunchRequest {
    enum class Command { PlayPause, Next, Previous };

    // Raise the window. A plain launch and a link do; a playback option alone
    // does not.
    bool show = true;
    QList<Command> commands;
    QStringList urls;

    bool isPlainShow() const { return show && commands.isEmpty() && urls.isEmpty(); }

    // A plain launch is the bare "show" every older version sends and
    // understands. Anything else is one line of JSON.
    QByteArray encode() const;
    static std::optional<LaunchRequest> decode(const QByteArray &message);

    friend bool operator==(const LaunchRequest &a, const LaunchRequest &b) {
        return a.show == b.show && a.commands == b.commands && a.urls == b.urls;
    }
};

// Reads the command line, passes a launch on to a running instance, and on the
// running side turns what arrives into signals for Application.
class RemoteControl : public QObject {
    Q_OBJECT
public:
    explicit RemoteControl(QObject *parent = nullptr);

    struct Parsed {
        LaunchRequest request;
        // Set for --help, --version and a command-line error: print and end.
        bool exit = false;
        int exitCode = 0;
        QString output;   // for stdout
        QString error;    // for stderr
    };
    // `arguments` starts with the program name. Needs a QCoreApplication.
    static Parsed parseArguments(const QStringList &arguments);
    // Whether the raw command line asks for --help or --version, which have
    // to be answered before anything opens a display connection.
    static bool asksForInfoOnly(int argc, char **argv);

    // Hands `request` to the instance listening on `socketName`. False when
    // none answers, and this launch becomes the instance.
    static bool sendToRunning(const QString &socketName, const LaunchRequest &request,
                              int timeoutMs = 500);

    // Takes requests from later launches on `server`, which must listen.
    void listen(QLocalServer *server);

    // Shows at once; commands and links wait until setReady(true): before
    // sign-in there is no queue to act on and no page to open.
    void submit(const LaunchRequest &request);
    void setReady(bool ready);
    bool isReady() const { return m_ready; }

    // Finds the album a track is on; 0 when the lookup fails. A track has no
    // page of its own, so a track link opens its album.
    using AlbumOfTrack = std::function<void(qint64 trackId, std::function<void(qint64 albumId)>)>;
    void setAlbumOfTrack(AlbumOfTrack lookup) { m_albumOfTrack = std::move(lookup); }

signals:
    void showRequested();
    void playPauseRequested();
    void nextRequested();
    void previousRequested();
    // `kind` is "album", "artist", "playlist" or "mix", with the id that
    // TidalLink parsed.
    void openRequested(const QString &kind, const QString &id);

private:
    // A command, or a link when `url` is set.
    struct Pending {
        LaunchRequest::Command command = LaunchRequest::Command::PlayPause;
        QString url;
    };
    void perform(const Pending &item);
    void open(const QString &url);

    bool m_ready = false;
    QList<Pending> m_pending;
    AlbumOfTrack m_albumOfTrack;
};
