// SPDX-License-Identifier: GPL-3.0-or-later

#include "scrobble/ScrobbleSink.h"
#include "api/Auth.h"
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>
#include <QSettings>
#include <QStandardPaths>
#include <QTimer>

namespace {

QString enabledKey(const QString &key) {
    return QStringLiteral("scrobbling/%1/enabled").arg(key);
}

// Written beside the file and renamed over it. `ownerOnly` before the first
// byte goes in, as Auth does with the Tidal credentials.
bool writeFile(const QString &path, const QByteArray &bytes, bool ownerOnly) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly)) return false;
    if (ownerOnly && !f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner)) {
        f.cancelWriting();
        return false;
    }
    f.write(bytes);
    return f.commit();
}

QJsonObject readObject(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    return QJsonDocument::fromJson(f.readAll()).object();
}

} // namespace

ScrobbleSink::Paths ScrobbleSink::defaultPaths(const QString &key) {
    Paths p;
    // The Tidal credentials' directory, so both secrets sit in one place.
    p.secret = QFileInfo(Auth::credentialsPath()).absolutePath()
             + QStringLiteral("/scrobbling-%1.json").arg(key);
    p.queue  = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
             + QStringLiteral("/scrobble-queue-%1.json").arg(key);
    return p;
}

ScrobbleSink::ScrobbleSink(ScrobbleService *service, const Paths &paths, QObject *parent)
    : QObject(parent)
    , m_service(service)
    , m_paths(paths)
    , m_timer(new QTimer(this))
{
    m_service->setParent(this);
    m_timer->setSingleShot(true);
    connect(m_timer, &QTimer::timeout, this, &ScrobbleSink::pump);
    m_clock.start();
    m_enabled = QSettings().value(enabledKey(m_service->key()), false).toBool();
    load();
    // What an earlier run left goes out once the event loop runs.
    QTimer::singleShot(0, this, &ScrobbleSink::pump);
}

void ScrobbleSink::load() {
    const QJsonObject account = readObject(m_paths.secret);
    m_secret = account.value(QStringLiteral("secret")).toString();
    m_user   = account.value(QStringLiteral("user_name")).toString();
    const QJsonObject queue = readObject(m_paths.queue);
    m_queueUser = queue.value(QStringLiteral("user_name")).toString();
    if (m_queueUser.isEmpty()) m_queueUser = m_user;
    const QJsonArray rows = queue.value(QStringLiteral("listens")).toArray();
    for (const auto &v : rows) {
        const Listen l = Listen::fromStored(v.toObject());
        if (l.isValid()) m_queue.append(l);
    }
}

void ScrobbleSink::saveQueue() {
    if (m_queue.isEmpty()) {
        QFile::remove(m_paths.queue);
        return;
    }
    QJsonArray rows;
    for (const Listen &l : std::as_const(m_queue)) rows.append(l.toStored());
    QJsonObject doc;
    doc[QStringLiteral("version")] = 1;
    if (!m_queueUser.isEmpty()) doc[QStringLiteral("user_name")] = m_queueUser;
    doc[QStringLiteral("listens")] = rows;
    if (!writeFile(m_paths.queue, QJsonDocument(doc).toJson(QJsonDocument::Compact), false))
        qWarning() << "Scrobbling: could not write the queue to" << m_paths.queue;
}

bool ScrobbleSink::saveSecret() {
    QJsonObject o;
    o[QStringLiteral("service")]   = m_service->key();
    o[QStringLiteral("secret")]    = m_secret;
    o[QStringLiteral("user_name")] = m_user;
    return writeFile(m_paths.secret, QJsonDocument(o).toJson(), true);
}

void ScrobbleSink::setEnabled(bool on) {
    if (on == m_enabled) return;
    m_enabled = on;
    QSettings().setValue(enabledKey(m_service->key()), on);
    if (!on) m_pendingNow.reset();
    emit enabledChanged();
    pump();
}

void ScrobbleSink::setError(const QString &text, bool stays) {
    m_errorStays = stays;
    if (text == m_lastError) return;
    m_lastError = text;
    emit statusChanged();
}

void ScrobbleSink::setAuthFailed(bool failed) {
    if (failed == m_authFailed) return;
    m_authFailed = failed;
    emit statusChanged();
}

QString ScrobbleSink::statusText() const {
    if (m_checking) return tr("Checking the token with %1…").arg(serviceName());
    if (!connected()) {
        if (m_queue.isEmpty()) return m_lastError;
        QString kept = m_queueUser.isEmpty()
            ? tr("%Ln listen(s) kept until you connect again.", nullptr, int(m_queue.size()))
            : tr("%Ln listen(s) kept until %1 connects again.", nullptr, int(m_queue.size())).arg(m_queueUser);
        if (!m_lastError.isEmpty()) kept += QLatin1Char(' ') + m_lastError;
        return kept;
    }
    QString line = m_queue.isEmpty()
        ? tr("Nothing is waiting to be sent.")
        : tr("%Ln listen(s) waiting to be sent.", nullptr, int(m_queue.size()));
    if (!m_lastError.isEmpty()) line += QLatin1Char(' ') + m_lastError;
    return line;
}

void ScrobbleSink::signIn(const QString &raw) {
    const QString secret = raw.trimmed();
    if (secret.isEmpty() || m_checking) return;
    m_checking = true;
    emit checkingChanged();
    emit statusChanged();
    const int generation = m_generation;
    m_service->verify(secret, [this, secret, generation](const ScrobbleReply &r, const QString &user) {
        if (generation != m_generation) return;
        m_checking = false;
        emit checkingChanged();
        if (r.kind != ScrobbleReply::Ok) {
            qInfo().noquote() << "Scrobbling:" << serviceName() << "did not take the token:" << r.detail;
            setError(r.kind == ScrobbleReply::Retry
                ? tr("%1 could not be reached. Try again in a moment.").arg(serviceName())
                : tr("%1 does not know this token. Copy it again from your %1 settings.").arg(serviceName()));
            emit statusChanged();
            return;
        }
        // Another account's listens are not this one's to send.
        if (!m_queueUser.isEmpty() && user != m_queueUser && !m_queue.isEmpty()) {
            m_queue.clear();
            emit queueChanged();
        }
        m_queueUser = user;
        saveQueue();
        m_secret = secret;
        m_user   = user;
        // An answer still out was for the old token and is not waited for.
        ++m_generation;
        m_busy = false;
        if (!saveSecret())
            qWarning() << "Scrobbling: could not save the account to" << m_paths.secret;
        // The user acted, so no backoff is waited out; the check was a call.
        m_failures = 0;
        m_notBefore = m_clock.elapsed() + m_spacingMs;
        setAuthFailed(false);
        setError(QString());
        emit accountChanged();
        emit statusChanged();
        pump();
    });
}

void ScrobbleSink::disconnectAccount() {
    ++m_generation;
    const bool wasChecking = m_checking;
    m_checking = false;
    m_secret.clear();
    m_user.clear();
    QFile::remove(m_paths.secret);
    m_pendingNow.reset();
    m_timer->stop();
    m_busy = false;
    m_failures = 0;
    m_notBefore = 0;
    m_singlesLeft = 0;
    setAuthFailed(false);
    setError(QString());
    if (wasChecking) emit checkingChanged();
    emit accountChanged();
    emit statusChanged();
}

void ScrobbleSink::add(const Listen &listen) {
    if (!m_enabled || !connected() || !listen.isValid()) return;
    m_queue.append(listen);
    while (m_queue.size() > kMaxQueued) m_queue.removeFirst();
    // On disk before anything is sent, so a quit loses nothing.
    saveQueue();
    emit queueChanged();
    emit statusChanged();
    pump();
}

void ScrobbleSink::nowPlaying(const Listen &listen) {
    if (!m_enabled || !connected() || m_authFailed || !listen.isValid()) return;
    m_pendingNow = listen;
    pump();
}

void ScrobbleSink::holdFor(qint64 ms) {
    m_notBefore = qMax(m_notBefore, m_clock.elapsed() + ms);
}

void ScrobbleSink::pump() {
    if (m_busy || !m_enabled || !connected() || m_authFailed) return;
    if (!m_pendingNow && m_queue.isEmpty()) return;
    const qint64 wait = m_notBefore - m_clock.elapsed();
    if (wait > 0) {
        if (!m_timer->isActive() || m_timer->remainingTime() > wait) m_timer->start(int(wait));
        return;
    }
    m_timer->stop();
    if (m_pendingNow) {
        const Listen now = *m_pendingNow;
        m_pendingNow.reset();
        m_busy = true;
        const int generation = m_generation;
        m_service->nowPlaying(m_secret, now, [this, generation](const ScrobbleReply &r) {
            if (generation != m_generation) return;
            m_busy = false;
            holdFor(qMax<qint64>(m_spacingMs, qint64(r.waitSec) * 1000));
            // Never retried, as both services ask; a refused token shows here too.
            if (r.kind == ScrobbleReply::AuthFailed) {
                setAuthFailed(true);
                setError(tr("%1 no longer accepts this token, so nothing is sent. Paste a new token to go on.").arg(serviceName()));
            }
            pump();
        });
        return;
    }
    sendBatch();
}

void ScrobbleSink::sendBatch() {
    const int cap = m_singlesLeft > 0 ? 1 : m_service->maxBatch();
    const QList<Listen> batch = m_queue.mid(0, cap);
    m_busy = true;
    const int generation = m_generation;
    m_service->submit(m_secret, batch, [this, batch, generation](const ScrobbleReply &r) {
        batchDone(batch, generation, r);
    });
}

bool ScrobbleSink::removeSent(const QList<Listen> &sent) {
    bool any = false;
    for (const Listen &l : sent) {
        const qsizetype i = m_queue.indexOf(l);
        if (i >= 0) { m_queue.removeAt(i); any = true; }
    }
    return any;
}

QString ScrobbleSink::retryText(const ScrobbleReply &r) const {
    if (r.detail.startsWith(QLatin1String("HTTP 429")))
        return tr("%1 asked to slow down. Listens wait here and go out later.").arg(serviceName());
    if (r.detail.startsWith(QLatin1String("HTTP ")))
        return tr("%1 has a problem on its side. Listens wait here and go out later.").arg(serviceName());
    return tr("%1 could not be reached. Listens wait here and go out later.").arg(serviceName());
}

void ScrobbleSink::batchDone(const QList<Listen> &batch, int generation, const ScrobbleReply &r) {
    if (generation != m_generation) {
        // Taken after a disconnect: sent, so the next connect does not send it again.
        if (r.kind == ScrobbleReply::Ok && removeSent(batch)) {
            saveQueue();
            emit queueChanged();
            emit statusChanged();
        }
        return;
    }
    m_busy = false;
    const int count = int(batch.size());
    switch (r.kind) {
    case ScrobbleReply::Ok:
        removeSent(batch);
        saveQueue();
        m_failures = 0;
        if (m_singlesLeft > 0) --m_singlesLeft;
        if (!m_errorStays) setError(QString());
        holdFor(qMax<qint64>(m_spacingMs, qint64(r.waitSec) * 1000));
        emit queueChanged();
        break;
    case ScrobbleReply::Retry: {
        qInfo().noquote() << "Scrobbling:" << serviceName() << "will be asked again:" << r.detail;
        qint64 wait = qint64(r.waitSec) * 1000;
        if (wait <= 0) {
            wait = qMin<qint64>(qint64(m_retryMs) << qMin(m_failures, 10), kMaxRetryMs);
            ++m_failures;
        }
        holdFor(qMax<qint64>(wait, m_spacingMs));
        setError(retryText(r));
        break;
    }
    case ScrobbleReply::AuthFailed:
        qInfo().noquote() << "Scrobbling:" << serviceName() << "refused the token:" << r.detail;
        setAuthFailed(true);
        setError(tr("%1 no longer accepts this token, so nothing is sent. Paste a new token to go on.").arg(serviceName()));
        break;
    case ScrobbleReply::Rejected:
        qWarning().noquote() << "Scrobbling:" << serviceName() << "refused" << count << "listens:" << r.detail;
        holdFor(m_spacingMs);
        if (count > 1) {
            // One bad listen refuses the batch; one at a time finds it.
            m_singlesLeft = count;
        } else {
            if (m_singlesLeft > 0) --m_singlesLeft;
            const Listen dropped = batch.first();
            removeSent(batch);
            saveQueue();
            setError(tr("%1 turned down the listen of \"%2\".").arg(serviceName(), dropped.title), true);
            emit queueChanged();
        }
        break;
    }
    emit statusChanged();
    pump();
}
