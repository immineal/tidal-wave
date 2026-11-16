// SPDX-License-Identifier: GPL-3.0-or-later

#include "TrayMenu.h"

#include <QAction>
#include <QEvent>
#include <QMenu>

TrayMenu::TrayMenu(QObject *parent) : QObject(parent), m_menu(std::make_unique<QMenu>()) {
    m_show = m_menu->addAction(QString());
    m_show->setObjectName(QStringLiteral("trayShow"));
    connect(m_show, &QAction::triggered, this, &TrayMenu::showRequested);

    m_hide = m_menu->addAction(QString());
    m_hide->setObjectName(QStringLiteral("trayHide"));
    connect(m_hide, &QAction::triggered, this, &TrayMenu::hideRequested);

    m_menu->addSeparator();

    m_quit = m_menu->addAction(QString());
    m_quit->setObjectName(QStringLiteral("trayQuit"));
    connect(m_quit, &QAction::triggered, this, &TrayMenu::quitRequested);

    // A catalogue installed or removed reaches every widget as LanguageChange.
    m_menu->installEventFilter(this);
    retranslate();
}

TrayMenu::~TrayMenu() = default;

bool TrayMenu::eventFilter(QObject *watched, QEvent *event) {
    if (watched == m_menu.get() && event->type() == QEvent::LanguageChange)
        retranslate();
    return QObject::eventFilter(watched, event);
}

void TrayMenu::retranslate() {
    m_show->setText(tr("Show"));
    m_hide->setText(tr("Hide"));
    m_quit->setText(tr("Quit"));
}
