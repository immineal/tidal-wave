// The tray icon's menu, built without a tray host: its labels have to follow
// a live language switch, the window's state and the player's.

#include <QAction>
#include <QApplication>
#include <QMenu>
#include <QSettings>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>

#include "ui/I18n.h"
#include "ui/Prefs.h"
#include "ui/TrayMenu.h"

class TestTrayMenu : public QObject {
    Q_OBJECT

    static QAction *action(const TrayMenu &tray, const char *name) {
        return tray.menu()->findChild<QAction *>(QString::fromLatin1(name));
    }

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_tray_menu"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    // The menu is built in English and the language is then switched in
    // Settings, which installs the German catalogue while the app runs.
    void followsALiveLanguageSwitch() {
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("en"));
        I18n i18n(&prefs);
        TrayMenu tray;
        QCOMPARE(action(tray, "trayQuit")->text(), QStringLiteral("Quit"));

        prefs.setLanguage(QStringLiteral("de"));
        QCOMPARE(i18n.effectiveLanguage(), QStringLiteral("de"));
        // Qt posts LanguageChange to the widgets.
        QTRY_COMPARE(action(tray, "trayQuit")->text(), QStringLiteral("Beenden"));

        prefs.setLanguage(QStringLiteral("en"));
        QTRY_COMPARE(action(tray, "trayQuit")->text(), QStringLiteral("Quit"));
    }

private:
    QTemporaryDir m_dir;
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    TestTrayMenu tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "tst_tray_menu.moc"
