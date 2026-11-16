// SPDX-License-Identifier: GPL-3.0-or-later

#include "RemoteControl.h"

#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QTimer>

#include <cstring>
#include <memory>

namespace {

const QByteArray kPlainShow = QByteArrayLiteral("show");
// A request is a few hundred bytes; anything this long is not one.
constexpr qsizetype kMaxMessage = 64 * 1024;
// Pending commands before sign-in; a stuck launcher cannot pile up more.
constexpr qsizetype kMaxPending = 16;

struct CommandName {
    LaunchRequest::Command command;
    const char *name;
};
constexpr CommandName kCommands[] = {
    { LaunchRequest::Command::PlayPause, "play-pause" },
    { LaunchRequest::Command::Next,      "next" },
    { LaunchRequest::Command::Previous,  "previous" },
};

QString nameOf(LaunchRequest::Command c) {
    for (const CommandName &n : kCommands)
        if (n.command == c) return QString::fromLatin1(n.name);
    return {};
}

} // namespace

QByteArray LaunchRequest::encode() const {
    if (isPlainShow())
        return kPlainShow;
    QJsonArray cmds;
    for (Command c : commands)
        cmds.append(nameOf(c));
    QJsonObject o;
    o.insert(QStringLiteral("show"), show);
    o.insert(QStringLiteral("commands"), cmds);
    o.insert(QStringLiteral("urls"), QJsonArray::fromStringList(urls));
    return QJsonDocument(o).toJson(QJsonDocument::Compact) + '\n';
}

std::optional<LaunchRequest> LaunchRequest::decode(const QByteArray &message) {
    const QByteArray m = message.trimmed();
    if (m == kPlainShow)
        return LaunchRequest{};

    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(m, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject())
        return std::nullopt;
    const QJsonObject o = doc.object();

    LaunchRequest r;
    r.show = o.value(QStringLiteral("show")).toBool(false);
    // A name a newer version added is skipped, not an error.
    for (const QJsonValue &v : o.value(QStringLiteral("commands")).toArray()) {
        for (const CommandName &n : kCommands)
            if (v.toString() == QLatin1String(n.name)) r.commands << n.command;
    }
    for (const QJsonValue &v : o.value(QStringLiteral("urls")).toArray()) {
        if (v.isString() && !v.toString().isEmpty()) r.urls << v.toString();
    }
    return r;
}

RemoteControl::RemoteControl(QObject *parent) : QObject(parent) {}

namespace {

void addOptions(QCommandLineParser &parser) {
    // -platform and the other Qt options are single-dash words, so the same
    // reading keeps -reverse from turning into -r -e -v.
    parser.setSingleDashWordOptionMode(QCommandLineParser::ParseAsLongOptions);
    parser.setApplicationDescription(QStringLiteral(
        "A desktop client for Tidal. With an instance already running, the options "
        "and the link are handed to it."));
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addOption({QStringLiteral("play-pause"), QStringLiteral("Toggle playback.")});
    parser.addOption({QStringLiteral("next"), QStringLiteral("Skip to the next track.")});
    parser.addOption({QStringLiteral("previous"),
                      QStringLiteral("Go back to the previous track.")});
    parser.addPositionalArgument(QStringLiteral("url"),
        QStringLiteral("A Tidal link to open: tidal://, tidal.com or listen.tidal.com."),
        QStringLiteral("[url]"));
}

} // namespace

RemoteControl::Parsed RemoteControl::parseArguments(const QStringList &arguments) {
    QCommandLineParser parser;
    addOptions(parser);
    Parsed out;

    const bool ok = parser.parse(arguments);
    // Asked for help or the version, the rest of the line does not matter.
    const QString helpAll = QStringLiteral("help-all");
    if (parser.isSet(QStringLiteral("help")) || parser.optionNames().contains(helpAll)
        || parser.unknownOptionNames().contains(helpAll)) {
        out.exit = true;
        out.output = parser.helpText();
        return out;
    }
    if (parser.isSet(QStringLiteral("version"))) {
        out.exit = true;
        out.output = QStringLiteral("%1 %2\n").arg(QCoreApplication::applicationName(),
                                                   QCoreApplication::applicationVersion());
        return out;
    }
    if (!ok) {
        out.exit = true;
        out.exitCode = 1;
        out.error = parser.errorText() + QStringLiteral("\nTry '--help' for the options.\n");
        return out;
    }

    LaunchRequest &r = out.request;
    for (const CommandName &n : kCommands)
        if (parser.isSet(QString::fromLatin1(n.name))) r.commands << n.command;
    r.urls = parser.positionalArguments();
    r.show = r.commands.isEmpty() || !r.urls.isEmpty();
    return out;
}

bool RemoteControl::asksForInfoOnly(int argc, char **argv) {
    for (int i = 1; i < argc; ++i) {
        const char *a = argv[i];
        if (std::strcmp(a, "--") == 0) return false;
        for (const char *info : { "-h", "-?", "--help", "-help", "--help-all", "-help-all",
                                  "-v", "--version", "-version" })
            if (std::strcmp(a, info) == 0) return true;
    }
    return false;
}

bool RemoteControl::sendToRunning(const QString &socketName, const LaunchRequest &request,
                                  int timeoutMs) {
    QLocalSocket socket;
    socket.connectToServer(socketName);
    if (!socket.waitForConnected(timeoutMs))
        return false;
    socket.write(request.encode());
    socket.waitForBytesWritten(timeoutMs);
    // The close tells the instance the message is complete.
    socket.disconnectFromServer();
    if (socket.state() != QLocalSocket::UnconnectedState)
        socket.waitForDisconnected(timeoutMs);
    return true;
}

void RemoteControl::listen(QLocalServer *server) {
    connect(server, &QLocalServer::newConnection, this, [this, server]() {
        while (QLocalSocket *client = server->nextPendingConnection()) {
            auto buffer = std::make_shared<QByteArray>();
            auto handled = std::make_shared<bool>(false);
            // A newline ends a request, and so does the close. A bare "show"
            // from an older launch has neither before it closes.
            auto consume = [this, client, buffer, handled](bool atEnd) {
                if (*handled) return;
                buffer->append(client->readAll());
                if (buffer->size() > kMaxMessage) {
                    *handled = true;
                    client->abort();
                    return;
                }
                const qsizetype newline = buffer->indexOf('\n');
                if (newline < 0 && *buffer != kPlainShow && !atEnd)
                    return;
                *handled = true;
                const auto request = LaunchRequest::decode(
                    newline < 0 ? *buffer : buffer->left(newline));
                if (request) submit(*request);
                else if (!buffer->isEmpty())
                    qWarning("tidal-wave: ignored a malformed request from another launch");
                client->disconnectFromServer();
            };
            connect(client, &QLocalSocket::readyRead, this, [consume] { consume(false); });
            connect(client, &QLocalSocket::disconnected, this, [consume, client] {
                consume(true);
                client->deleteLater();
            });
            // A launch that connects and says nothing is dropped.
            QTimer::singleShot(2000, client, [client] { client->abort(); });
        }
    });
}

void RemoteControl::submit(const LaunchRequest &request) {
    if (request.show)
        emit showRequested();
    for (LaunchRequest::Command c : request.commands) {
        if (m_ready) perform(c);
        else if (m_pending.size() < kMaxPending) m_pending << c;
    }
}

void RemoteControl::setReady(bool ready) {
    m_ready = ready;
    while (m_ready && !m_pending.isEmpty())
        perform(m_pending.takeFirst());
}

void RemoteControl::perform(LaunchRequest::Command command) {
    switch (command) {
    case LaunchRequest::Command::PlayPause: emit playPauseRequested(); break;
    case LaunchRequest::Command::Next:      emit nextRequested();      break;
    case LaunchRequest::Command::Previous:  emit previousRequested();  break;
    }
}
