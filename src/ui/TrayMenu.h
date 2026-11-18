// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QString>
#include <memory>

class QAction;
class QMenu;

// The tray icon's context menu and tooltip. Kept apart from Application so a
// test can build it without a tray host.
class TrayMenu : public QObject {
    Q_OBJECT
public:
    // What the labels follow. Application fills it from the window and Player.
    struct State {
        bool    windowShown = false;
        bool    playing     = false;
        bool    hasTrack    = false;
        QString title;
        QString artist;
    };

    explicit TrayMenu(QObject *parent = nullptr);
    ~TrayMenu() override;

    QMenu *menu() const { return m_menu.get(); }
    void setState(const State &state);
    // The current track, as music players' tray icons show it, or the app name.
    QString toolTip() const;

signals:
    void toggleWindowRequested();
    void playPauseRequested();
    void nextRequested();
    void previousRequested();
    void quitRequested();
    // The labels changed, so the tray icon needs the new tooltip.
    void toolTipChanged(const QString &toolTip);
    void aboutToShow();

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void retranslate();

    std::unique_ptr<QMenu> m_menu;
    State    m_state;
    QAction *m_toggleWindow = nullptr;
    QAction *m_previous = nullptr;
    QAction *m_playPause = nullptr;
    QAction *m_next = nullptr;
    QAction *m_quit = nullptr;
};
