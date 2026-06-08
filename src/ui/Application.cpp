#include "Application.h"
#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDateTime>
#include <QFont>
// #include <QQuickStyle>

Application::Application(QObject *parent) : QObject(parent) {
}

int Application::run(int argc, char **argv) {
    QApplication::setApplicationName("Tidal Wave");
    QApplication::setApplicationVersion("0.1.0");
    QApplication::setOrganizationName("TidalWave");

    QApplication app(argc, argv);
    
    QFont defaultFont("Inter");
    defaultFont.setFamilies({"Inter", "DejaVu Sans", "sans-serif"});
    QApplication::setFont(defaultFont);
    // QQuickStyle::setStyle("Basic");

    m_api    = new TidalApi(this);
    m_auth   = new Auth(m_api, this);
    m_client = new TidalClient(m_api, this);
    m_bridge = new TidalBridge(m_client, this);
    m_player = new Player(m_client, this);
    m_mpris  = new MprisManager(m_player, this);
    m_discord = new DiscordRPC(this);

    connect(m_auth, &Auth::loginSucceeded, this, [this]() {
        m_client->setUserId(m_auth->userId());
    });

    connect(m_player, &Player::currentTrackChanged, this, &Application::updateDiscordRPC);
    connect(m_player, &Player::playingChanged, this, &Application::updateDiscordRPC);
    connect(m_player, &Player::positionChanged, this, &Application::onPlayerPositionChanged);

    m_auth->loadCredentials();

    QQmlApplicationEngine engine;
    engine.addImageProvider("tidal", new TidalImageProvider());

    QQmlContext *ctx = engine.rootContext();
    ctx->setContextProperty("auth",   m_auth);
    ctx->setContextProperty("bridge", m_bridge);
    ctx->setContextProperty("player", m_player);

    engine.load(QUrl(QStringLiteral("qrc:/TidalWave/qml/main.qml")));
    if (engine.rootObjects().isEmpty()) return -1;

    return app.exec();
}

void Application::updateDiscordRPC() {
    Track track = m_player->currentTrack();
    if (track.id > 0) {
        bool playing = m_player->playing();
        double pos = m_player->position() / 1000.0;
        double dur = m_player->duration() / 1000.0;

        m_discord->updateActivity(
            track.title,
            track.artistNames(),
            track.album.title,
            track.album.coverUrl(),
            pos,
            dur,
            playing
        );

        m_lastDiscordUpdatePos = m_player->position();
        m_lastDiscordUpdateTime = QDateTime::currentMSecsSinceEpoch();
    } else {
        m_discord->clearActivity();
    }
}

void Application::onPlayerPositionChanged(qint64 ms) {
    if (!m_player->playing()) {
        return;
    }
    qint64 current_time = QDateTime::currentMSecsSinceEpoch();
    qint64 elapsed = current_time - m_lastDiscordUpdateTime;
    qint64 expected_pos = m_lastDiscordUpdatePos + elapsed;

    if (qAbs(ms - expected_pos) > 2000) {
        updateDiscordRPC();
    }
}
