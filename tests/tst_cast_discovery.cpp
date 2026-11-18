// CastDiscovery's bookkeeping, fed the way Avahi's poll thread feeds it. No
// Avahi daemon is started: the tests call the callbacks' entry points.

#include <QTest>
#include <QHostAddress>
#include <QNetworkInterface>
#include <QSignalSpy>
#include <QThread>
#include <atomic>
#include <thread>

#include "cast/CastDiscovery.h"

class TestCastDiscovery : public QObject {
    Q_OBJECT

private slots:
    // Avahi calls back on its own thread while the main thread may clear the
    // table in stop(). Both have to be safe at once.
    void resultsFromTheAvahiThreadDoNotRaceStop()
    {
        CastDiscovery discovery;
        std::atomic<bool> done{false};
        std::thread avahi([&] {
            for (int i = 0; i < 20000; ++i) {
                const QString name = QStringLiteral("Speaker-%1").arg(i);
                discovery.onResolved(name, name, name, QStringLiteral("192.0.2.1"), 8009);
                if (i % 2) discovery.onRemoved(name);
            }
            done = true;
        });
        while (!done) {
            discovery.stop();
            QCoreApplication::processEvents();
        }
        avahi.join();
        QCoreApplication::processEvents();
    }

    // Results are handed over on the thread the object lives on, so whoever
    // listens never hears from Avahi's thread.
    void resultsArriveOnTheMainThread()
    {
        CastDiscovery discovery;
        // Only compared, never kept: an adopted thread's QThread dies with it.
        std::atomic<int> heard{0};
        std::atomic<bool> onMain{false};
        connect(&discovery, &CastDiscovery::deviceFound, this, [&] {
            onMain = QThread::currentThread() == QCoreApplication::instance()->thread();
            ++heard;
        }, Qt::DirectConnection);
        std::thread avahi([&] {
            discovery.onResolved(QStringLiteral("Speaker"), QStringLiteral("id-1"),
                                 QStringLiteral("Speaker"), QStringLiteral("192.0.2.1"), 8009);
        });
        avahi.join();
        QTRY_COMPARE_WITH_TIMEOUT(heard.load(), 1, 2000);
        QVERIFY(onMain);
    }

    // A device answers over IPv4 and IPv6. Its IPv4 address is the one kept,
    // whichever comes back first: a link-local IPv6 one needs its interface.
    void anIpv4AddressIsPreferred_data()
    {
        QTest::addColumn<bool>("ipv6First");
        QTest::newRow("IPv6 first") << true;
        QTest::newRow("IPv4 first") << false;
    }

    void anIpv4AddressIsPreferred()
    {
        QFETCH(bool, ipv6First);
        CastDiscovery discovery;
        QSignalSpy found(&discovery, &CastDiscovery::deviceFound);
        const QString v4 = QStringLiteral("192.0.2.7");
        const QString v6 = QStringLiteral("fe80::1%lo");
        const QString name = QStringLiteral("Speaker");
        discovery.onResolved(name, QStringLiteral("id-1"), name, ipv6First ? v6 : v4, 8009);
        discovery.onResolved(name, QStringLiteral("id-1"), name, ipv6First ? v4 : v6, 8009);
        QTRY_VERIFY_WITH_TIMEOUT(!found.isEmpty(), 2000);
        QTest::qWait(100);
        QCOMPARE(found.last().at(2).toString(), v4);
    }

    // Each address family is its own record, and losing one of two leaves
    // the device there.
    void aDeviceGoesWithItsLastRecord()
    {
        CastDiscovery discovery;
        QSignalSpy removed(&discovery, &CastDiscovery::deviceRemoved);
        const QString name = QStringLiteral("Speaker");
        discovery.onBrowsed(name);
        discovery.onBrowsed(name);
        discovery.onResolved(name, QStringLiteral("id-1"), name, QStringLiteral("192.0.2.7"), 8009);
        discovery.onRemoved(name);
        QTest::qWait(100);
        QCOMPARE(removed.count(), 0);
        discovery.onRemoved(name);
        QTRY_COMPARE_WITH_TIMEOUT(removed.count(), 1, 2000);
        QCOMPARE(removed.first().at(0).toString(), QStringLiteral("id-1"));
    }

    // fe80:: without an interface cannot be connected to; Avahi knows the
    // interface, and it goes into the address as its scope.
    void aLinkLocalAddressKeepsItsInterface()
    {
        const int lo = QNetworkInterface::interfaceIndexFromName(QStringLiteral("lo"));
        if (lo <= 0) QSKIP("no loopback interface named lo");
        const QString scoped = CastDiscovery::withScope(QStringLiteral("fe80::1"), lo);
        QCOMPARE(scoped, QStringLiteral("fe80::1%lo"));
        QCOMPARE(QHostAddress(scoped).scopeId(), QStringLiteral("lo"));

        QCOMPARE(CastDiscovery::withScope(QStringLiteral("192.0.2.7"), lo),
                 QStringLiteral("192.0.2.7"));
        QCOMPARE(CastDiscovery::withScope(QStringLiteral("2001:db8::1"), lo),
                 QStringLiteral("2001:db8::1"));
    }
};

QTEST_MAIN(TestCastDiscovery)
#include "tst_cast_discovery.moc"
