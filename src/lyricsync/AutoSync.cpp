// SPDX-License-Identifier: GPL-3.0-or-later

#include "AutoSync.h"
#include "Aligner.h"
#include "AudioFeed.h"
#include "Text.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QSaveFile>

namespace lyricsync {

namespace {

QString textHash(const QString &text) {
    return QString::fromLatin1(QCryptographicHash::hash(text.toUtf8(), QCryptographicHash::Sha1).toHex());
}

} // namespace

AutoSync::AutoSync(QObject *parent)
    : QObject(parent)
    , m_stop(std::make_shared<std::atomic<bool>>(false))
    , m_models(std::make_shared<std::shared_ptr<const Models>>())
{
    m_worker = new QObject;
    m_worker->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    m_thread.setObjectName(QStringLiteral("lyricsync"));
    m_thread.start(QThread::LowestPriority);
}

AutoSync::~AutoSync() {
    // An analysis under way stops at its next check, so quitting does not wait on it.
    m_stop->store(true);
    m_thread.quit();
    m_thread.wait();
}

void AutoSync::setFileHold(std::function<void(const QString &)> hold, std::function<void(const QString &)> release) {
    m_hold = std::move(hold);
    m_release = std::move(release);
}

void AutoSync::setModels(std::shared_ptr<const Models> m) {
    QMetaObject::invokeMethod(m_worker, [slot = m_models, m] { *slot = m; }, Qt::QueuedConnection);
}

QString AutoSync::cacheFile(qint64 trackId) const {
    return m_cacheDir + u'/' + QString::number(trackId) + QStringLiteral(".sync.json");
}

bool AutoSync::hasAnalysisForTest(qint64 trackId) const {
    for (const Kept &k : m_kept)
        if (k.trackId == trackId) return true;
    return false;
}

std::shared_ptr<const Analysis> AutoSync::analysisFor(qint64 trackId) {
    for (auto it = m_kept.begin(); it != m_kept.end(); ++it)
        if (it->trackId == trackId) {
            m_kept.splice(m_kept.begin(), m_kept, it);
            return m_kept.front().a;
        }
    return nullptr;
}

bool AutoSync::readCache(qint64 trackId, const QString &text, Result *out) const {
    if (m_cacheDir.isEmpty()) return false;
    QFile f(cacheFile(trackId));
    if (!f.open(QIODevice::ReadOnly)) return false;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    // An entry from another aligner version, or for other words, is not used.
    if (o.value(QStringLiteral("v")).toInt() != Models::kVersion
        || o.value(QStringLiteral("text")).toString() != textHash(text))
        return false;
    out->ok = true;
    out->kept = o.value(QStringLiteral("kept")).toBool();
    out->confidence = o.value(QStringLiteral("confidence")).toDouble();
    out->lrc = o.value(QStringLiteral("lrc")).toString();
    return true;
}

void AutoSync::sync(qint64 trackId, const QString &plainText, Done done) {
    const quint64 gen = ++m_gen;
    m_pending = {};
    auto answer = [this, gen, done](const Result &r) {
        QMetaObject::invokeMethod(this, [this, gen, done, r] { if (gen == m_gen) done(r); }, Qt::QueuedConnection);
    };
    Result r;
    if (m_enabled && !m_enabled()) { r.error = QStringLiteral("off"); answer(r); return; }
    if (trackId <= 0 || plainLines(plainText).isEmpty()) { r.error = QStringLiteral("no lyrics"); answer(r); return; }
    if (readCache(trackId, plainText, &r)) { answer(r); return; }
    if (m_failed.contains(trackId)) { r.error = QStringLiteral("no audio"); answer(r); return; }
    m_pending = {trackId, plainText, std::move(done), gen};
    pump();
}

void AutoSync::cancel() {
    ++m_gen;
    m_pending = {};
}

void AutoSync::setLookAhead(bool on) {
    if (on == m_lookAhead) return;
    m_lookAhead = on;
    pump();
}

void AutoSync::audioReady(qint64 trackId, bool ahead) {
    if (ahead) m_aheadId = trackId;
    pump();
}

void AutoSync::pump() {
    if (m_enabled && !m_enabled()) return;
    if (m_pending.done && !m_aligning) {
        if (std::shared_ptr<const Analysis> a = analysisFor(m_pending.trackId)) {
            m_aligning = true;
            const quint64 gen = m_pending.gen;
            const QString text = m_pending.text, file = m_cacheDir.isEmpty() ? QString() : cacheFile(m_pending.trackId);
            QPointer<AutoSync> self(this);
            QMetaObject::invokeMethod(m_worker, [self, models = m_models, a, text, file, gen] {
                const Alignment al = align(*a, text, **models);
                Result r;
                r.ok = al.aligned;
                r.kept = al.kept;
                r.confidence = al.confidence;
                r.lrc = toLrc(al);
                if (!al.aligned) r.error = QStringLiteral("not aligned");
                if (!file.isEmpty() && al.aligned) {
                    QDir().mkpath(QFileInfo(file).path());
                    QSaveFile f(file);
                    const QJsonObject o{{QStringLiteral("v"), Models::kVersion}, {QStringLiteral("text"), textHash(text)},
                                        {QStringLiteral("kept"), r.kept}, {QStringLiteral("confidence"), r.confidence},
                                        {QStringLiteral("lrc"), r.lrc}};
                    if (f.open(QIODevice::WriteOnly)) {
                        f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
                        f.commit();
                    }
                }
                QMetaObject::invokeMethod(self, [self, gen, r] { if (self) self->onAligned(gen, r); },
                                          Qt::QueuedConnection);
            }, Qt::QueuedConnection);
        }
    }
    if (m_analysing) return;
    // The track waiting for its words first, then the next one in the queue.
    for (const qint64 id : {m_pending.done ? m_pending.trackId : 0, m_lookAhead ? m_aheadId : 0}) {
        if (id <= 0 || m_failed.contains(id) || hasAnalysisForTest(id)) continue;
        const QString path = m_pathFor ? m_pathFor(id) : QString();
        if (path.isEmpty()) continue;
        startAnalysis(id, path);
        return;
    }
}

void AutoSync::startAnalysis(qint64 trackId, const QString &path) {
    m_analysing = trackId;
    if (m_hold) m_hold(path);
    QPointer<AutoSync> self(this);
    QMetaObject::invokeMethod(m_worker, [self, worker = m_worker, stop = m_stop, models = m_models, trackId, path] {
        auto back = [self, trackId, path](std::shared_ptr<const Analysis> a, const QString &err) {
            QMetaObject::invokeMethod(self, [self, trackId, path, a, err] {
                if (self) self->onAnalysed(trackId, path, a, err);
            }, Qt::QueuedConnection);
        };
        QString why;
        if (!*models) *models = Models::builtin(&why);
        if (!*models) { back(nullptr, why.isEmpty() ? QStringLiteral("no models") : why); return; }
        auto file = std::make_unique<QFile>(path);
        if (!file->open(QIODevice::ReadOnly)) { back(nullptr, QStringLiteral("cannot open the audio")); return; }
        auto fe = std::make_shared<FrontEnd>();
        fe->setStop(stop.get());
        auto *feed = new AudioFeed(worker);
        feed->setMaxFrames(size_t(kMaxSeconds) * 44100);
        QObject::connect(feed, &AudioFeed::finished, worker, [feed, fe, models, back](bool ok, const QString &err) {
            feed->deleteLater();
            if (!ok) { back(nullptr, err); return; }
            auto a = std::make_shared<Analysis>(fe->finish(**models));
            if (a->frames <= 0) { back(nullptr, QStringLiteral("too short")); return; }
            back(a, {});
        });
        if (!feed->start(std::move(file), fe.get())) {
            delete feed;
            back(nullptr, QStringLiteral("no audio decoder"));
        }
    }, Qt::QueuedConnection);
}

void AutoSync::onAnalysed(qint64 trackId, const QString &path, std::shared_ptr<const Analysis> a, const QString &err) {
    m_analysing = 0;
    if (m_release) m_release(path);
    const bool ok = a != nullptr;
    if (ok) {
        m_kept.push_front({trackId, std::move(a)});
        while (int(m_kept.size()) > kKeptAnalyses) m_kept.pop_back();
    } else {
        m_failed.insert(trackId);
        if (m_pending.done && m_pending.trackId == trackId) {
            Result r;
            r.error = err;
            Done done = std::move(m_pending.done);
            m_pending = {};
            done(r);
        }
    }
    emit analysed(trackId, ok);
    pump();
}

void AutoSync::onAligned(quint64 gen, const Result &r) {
    m_aligning = false;
    if (m_pending.done && m_pending.gen == gen && gen == m_gen) {
        Done done = std::move(m_pending.done);
        m_pending = {};
        done(r);
    }
    pump();
}

} // namespace lyricsync
