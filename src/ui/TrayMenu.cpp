// SPDX-License-Identifier: GPL-3.0-or-later

#include "TrayMenu.h"

#include <QAction>
#include <QCoreApplication>
#include <QEvent>
#include <QMenu>

namespace {
QAction *addNamed(QMenu *menu, const char *name) {
    QAction *a = menu->addAction(QString());
    a->setObjectName(QString::fromLatin1(name));
    return a;
}
} // namespace

TrayMenu::TrayMenu(QObject *parent) : QObject(parent), m_menu(std::make_unique<QMenu>()) {
    // One entry for the window, as Strawberry and Clementine have: an item
    // that hides a hidden window does nothing.
    m_toggleWindow = addNamed(m_menu.get(), "trayToggleWindow");
    connect(m_toggleWindow, &QAction::triggered, this, &TrayMenu::toggleWindowRequested);

    m_menu->addSeparator();
    m_previous = addNamed(m_menu.get(), "trayPrevious");
    connect(m_previous, &QAction::triggered, this, &TrayMenu::previousRequested);
    m_playPause = addNamed(m_menu.get(), "trayPlayPause");
    connect(m_playPause, &QAction::triggered, this, &TrayMenu::playPauseRequested);
    m_next = addNamed(m_menu.get(), "trayNext");
    connect(m_next, &QAction::triggered, this, &TrayMenu::nextRequested);

    m_menu->addSeparator();
    m_quit = addNamed(m_menu.get(), "trayQuit");
    connect(m_quit, &QAction::triggered, this, &TrayMenu::quitRequested);

    connect(m_menu.get(), &QMenu::aboutToShow, this, &TrayMenu::aboutToShow);
    // A catalogue installed or removed reaches every widget as LanguageChange.
    m_menu->installEventFilter(this);
    retranslate();
}

TrayMenu::~TrayMenu() = default;

void TrayMenu::setState(const State &state) {
    m_state = state;
    retranslate();
}

QString TrayMenu::toolTip() const {
    if (!m_state.hasTrack || m_state.title.isEmpty())
        return QCoreApplication::applicationName();
    if (m_state.artist.isEmpty())
        return m_state.title;
    return tr("%1 - %2", "tray tooltip: track title, then its artists")
        .arg(m_state.title, m_state.artist);
}

bool TrayMenu::eventFilter(QObject *watched, QEvent *event) {
    if (watched == m_menu.get() && event->type() == QEvent::LanguageChange)
        retranslate();
    return QObject::eventFilter(watched, event);
}

void TrayMenu::retranslate() {
    m_toggleWindow->setText(m_state.windowShown ? tr("Hide") : tr("Show"));
    m_previous->setText(tr("Previous track"));
    m_playPause->setText(m_state.playing ? tr("Pause") : tr("Play"));
    m_next->setText(tr("Next track"));
    m_quit->setText(tr("Quit"));
    // With nothing queued the buttons would do nothing.
    for (QAction *a : {m_previous, m_playPause, m_next})
        a->setEnabled(m_state.hasTrack);
    emit toolTipChanged(toolTip());
}
