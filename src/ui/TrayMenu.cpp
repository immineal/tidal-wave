// SPDX-License-Identifier: GPL-3.0-or-later

#include "TrayMenu.h"

#include <QAction>
#include <QEvent>
#include <QMenu>

TrayMenu::TrayMenu(QObject *parent) : QObject(parent), m_menu(std::make_unique<QMenu>()) {
    // One entry for the window: a Hide next to an already hidden window did
    // nothing.
    m_toggleWindow = m_menu->addAction(QString());
    m_toggleWindow->setObjectName(QStringLiteral("trayToggleWindow"));
    connect(m_toggleWindow, &QAction::triggered, this, &TrayMenu::toggleWindowRequested);

    m_menu->addSeparator();

    m_quit = m_menu->addAction(QString());
    m_quit->setObjectName(QStringLiteral("trayQuit"));
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

bool TrayMenu::eventFilter(QObject *watched, QEvent *event) {
    if (watched == m_menu.get() && event->type() == QEvent::LanguageChange)
        retranslate();
    return QObject::eventFilter(watched, event);
}

void TrayMenu::retranslate() {
    m_toggleWindow->setText(m_state.windowShown ? tr("Hide") : tr("Show"));
    m_quit->setText(tr("Quit"));
}
