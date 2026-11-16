// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QString>
#include <memory>

class QAction;
class QMenu;

// The tray icon's context menu. Kept apart from Application so a test can
// build it without a tray host.
class TrayMenu : public QObject {
    Q_OBJECT
public:
    // What the labels follow. Application fills it in.
    struct State {
        bool windowShown = false;
    };

    explicit TrayMenu(QObject *parent = nullptr);
    ~TrayMenu() override;

    QMenu *menu() const { return m_menu.get(); }
    void setState(const State &state);

signals:
    void toggleWindowRequested();
    void quitRequested();
    void aboutToShow();

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void retranslate();

    std::unique_ptr<QMenu> m_menu;
    State    m_state;
    QAction *m_toggleWindow = nullptr;
    QAction *m_quit = nullptr;
};
