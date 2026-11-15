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
#include <QTimer>

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
    if (m_jobStop) m_jobStop->store(true);
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

// Any entry of this aligner version, for whatever words.
bool AutoSync::cachedSync(qint64 trackId) const {
    if (m_cacheDir.isEmpty()) return false;
    QFile f(cacheFile(trackId));
    return f.open(QIODevice::ReadOnly)
        && QJsonDocument::fromJson(f.readAll()).object().value(QStringLiteral("v")).toInt() == Models::kVersion;
}

// Kept on disk, so a long mix is not decoded up to the cap on every run.
void AutoSync::writeTooLong(qint64 trackId) const {
    if (m_cacheDir.isEmpty()) return;
    QDir().mkpath(m_cacheDir);
    QSaveFile f(cacheFile(trackId));
    const QJsonObject o{{QStringLiteral("v"), Models::kVersion}, {QStringLiteral("tooLong"), true}};
    if (f.open(QIODevice::WriteOnly)) {
        f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
        f.commit();
    }
}

bool AutoSync::blocked(qint64 trackId) const {
    const auto it = m_failed.constFind(trackId);
    return it != m_failed.cend() && (it->permanent || !it->armed);
}

// Real timings or a result are there already: no need to analyse it ahead.
bool AutoSync::skipAhead(qint64 trackId) const {
    return m_realTimings.contains(trackId) || (m_hasTimings && m_hasTimings(trackId)) || cachedSync(trackId);
}

void AutoSync::noteRealTimings(qint64 trackId) {
    m_realTimings.insert(trackId);
    if (trackId == m_aheadId) m_aheadSkip = true;
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
    if (o.value(QStringLiteral("v")).toInt() != Models::kVersion) return false;
    if (o.value(QStringLiteral("tooLong")).toBool()) {
        out->ok = false;
        out->error = QStringLiteral("too long");
        return true;
    }
    if (o.value(QStringLiteral("text")).toString() != textHash(text)) return false;
    out->ok = true;
    out->kept = o.value(QStringLiteral("kept")).toBool();
    out->confidence = o.value(QStringLiteral("confidence")).toDouble();
    out->lrc = o.value(QStringLiteral("lrc")).toString();
    return true;
}

// The track asked for is no longer wanted: its analysis stops, unless it is
// the next track's, wanted ahead.
void AutoSync::dropPending() {
    const qint64 was = m_pending.trackId;
    m_pending = {};
    if (was && m_analysing == was && !(m_lookAhead && m_aheadId == was) && m_jobStop) m_jobStop->store(true);
}

void AutoSync::sync(qint64 trackId, const QString &plainText, Done done) {
    const quint64 gen = ++m_gen;
    if (m_pending.trackId != trackId) dropPending();
    m_pending = {};
    auto answer = [this, gen, done](const Result &r) {
        QMetaObject::invokeMethod(this, [this, gen, done, r] { if (gen == m_gen) done(r); }, Qt::QueuedConnection);
    };
    Result r;
    if (m_enabled && !m_enabled()) { r.error = QStringLiteral("off"); answer(r); return; }
    if (trackId <= 0 || plainLines(plainText).isEmpty()) { r.error = QStringLiteral("no lyrics"); answer(r); return; }
    if (readCache(trackId, plainText, &r)) { answer(r); return; }
    // A final failure answers now; one that may pass gets another try.
    if (const auto it = m_failed.find(trackId); it != m_failed.end()) {
        if (it->permanent) {
            r.error = it->error;
            answer(r);
            return;
        }
        it->armed = true;
    }
    m_pending = {trackId, plainText, std::move(done), gen};
    pump();
}

void AutoSync::cancel() {
    ++m_gen;
    dropPending();
}

void AutoSync::setLookAhead(bool on) {
    if (on == m_lookAhead) return;
    m_lookAhead = on;
    pump();
}

void AutoSync::audioReady(qint64 trackId, bool ahead) {
    if (auto it = m_failed.find(trackId); it != m_failed.end() && !it->permanent) it->armed = true;
    if (ahead && trackId != m_aheadId) {
        m_aheadId = trackId;
        m_aheadSkip = skipAhead(trackId);
    }
    pump();
}

void AutoSync::pump() {
    if (m_enabled && !m_enabled()) return;
    if (m_pending.done && !m_aligning) {
        if (std::shared_ptr<const Analysis> a = analysisFor(m_pending.trackId)) {
            m_aligning = true;
            const quint64 gen = m_pending.gen;
            const qint64 id = m_pending.trackId;
            const QString text = m_pending.text, file = m_cacheDir.isEmpty() ? QString() : cacheFile(id);
            QPointer<AutoSync> self(this);
            QMetaObject::invokeMethod(m_worker, [self, models = m_models, stop = m_stop, a, text, file, gen, id] {
                const Alignment al = align(*a, text, **models, nullptr, stop.get());
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
                QMetaObject::invokeMethod(self, [self, id, gen, r] { if (self) self->onAligned(id, gen, r); },
                                          Qt::QueuedConnection);
            }, Qt::QueuedConnection);
        }
    }
    if (m_analysing) return;
    // The track waiting for its words first, then the next one in the queue.
    const qint64 ahead = m_lookAhead && !m_aheadSkip ? m_aheadId : 0;
    for (const qint64 id : {m_pending.done ? m_pending.trackId : 0, ahead}) {
        if (id <= 0 || blocked(id) || hasAnalysisForTest(id)) continue;
        const QString path = m_pathFor ? m_pathFor(id) : QString();
        if (path.isEmpty()) continue;
        startAnalysis(id, path);
        return;
    }
}

void AutoSync::startAnalysis(qint64 trackId, const QString &path) {
    m_analysing = trackId;
    qInfo() << "[autosync] analysing track" << trackId << (trackId == m_pending.trackId ? "" : "ahead");
    m_jobStop = std::make_shared<std::atomic<bool>>(false);
    if (m_hold) m_hold(path);
    QPointer<AutoSync> self(this);
    const size_t maxFrames = size_t(m_maxSeconds) * 44100;
    QMetaObject::invokeMethod(m_worker, [self, worker = m_worker, stop = m_jobStop, models = m_models, trackId, path,
                                         maxFrames] {
        auto back = [self, trackId, path](std::shared_ptr<const Analysis> a, const QString &err, Outcome o) {
            QMetaObject::invokeMethod(self, [self, trackId, path, a, err, o] {
                if (self) self->onAnalysed(trackId, path, a, err, o);
            }, Qt::QueuedConnection);
        };
        if (stop->load()) { back(nullptr, QStringLiteral("cancelled"), Outcome::Cancelled); return; }
        QString why;
        if (!*models) *models = Models::builtin(&why);
        if (!*models) { back(nullptr, why.isEmpty() ? QStringLiteral("no models") : why, Outcome::Permanent); return; }
        auto file = std::make_unique<QFile>(path);
        if (!file->open(QIODevice::ReadOnly)) {
            back(nullptr, QStringLiteral("cannot open the audio"), Outcome::Transient);
            return;
        }
        auto fe = std::make_shared<FrontEnd>();
        fe->setStop(stop.get());
        auto *feed = new AudioFeed(worker);
        feed->setMaxFrames(maxFrames);
        feed->setStop(stop.get());
        QObject::connect(feed, &AudioFeed::finished, worker, [feed, fe, models, stop, back](bool ok, const QString &err) {
            feed->deleteLater();
            if (!ok) {
                switch (feed->failure()) {
                case AudioFeed::Failure::Cancelled: back(nullptr, err, Outcome::Cancelled); return;
                case AudioFeed::Failure::TooLong:   back(nullptr, err, Outcome::TooLong); return;
                case AudioFeed::Failure::Format:    back(nullptr, err, Outcome::Permanent); return;
                default:                            back(nullptr, err, Outcome::Transient); return;
                }
            }
            auto a = std::make_shared<Analysis>(fe->finish(**models));
            if (stop->load()) { back(nullptr, QStringLiteral("cancelled"), Outcome::Cancelled); return; }
            if (a->frames <= 0) { back(nullptr, QStringLiteral("too short"), Outcome::Permanent); return; }
            back(a, {}, Outcome::Ok);
        });
        if (!feed->start(std::move(file), fe.get())) {
            delete feed;
            back(nullptr, QStringLiteral("no audio decoder"), Outcome::Permanent);
        }
    }, Qt::QueuedConnection);
}

void AutoSync::onAnalysed(qint64 trackId, const QString &path, std::shared_ptr<const Analysis> a, const QString &err,
                          Outcome outcome) {
    m_analysing = 0;
    m_jobStop.reset();
    if (m_release) m_release(path);
    if (outcome == Outcome::Cancelled) { pump(); return; }
    const bool ok = outcome == Outcome::Ok;
    if (ok) {
        m_kept.push_front({trackId, std::move(a)});
        while (int(m_kept.size()) > kKeptAnalyses) m_kept.pop_back();
        m_failed.remove(trackId);
    } else {
        Failure &f = m_failed[trackId];
        f.error = err;
        f.armed = false;
        ++f.tries;
        f.permanent = outcome != Outcome::Transient || f.tries >= kMaxTries;
        qInfo().noquote() << "[autosync] track" << trackId << "not analysed:" << err
                          << (f.permanent ? QStringLiteral("(final)")
                                          : QStringLiteral("(try %1 of %2)").arg(f.tries).arg(kMaxTries));
        if (outcome == Outcome::TooLong) writeTooLong(trackId);
        if (m_pending.done && m_pending.trackId == trackId) {
            if (f.permanent) {
                Result r;
                r.error = err;
                Done done = std::move(m_pending.done);
                m_pending = {};
                done(r);
            } else {
                // Someone waits for it: tried again soon, whether or not new audio comes.
                QTimer::singleShot(m_retryMs, this, [this, trackId] { retry(trackId); });
            }
        }
    }
    emit analysed(trackId, ok);
    pump();
}

void AutoSync::retry(qint64 trackId) {
    if (!m_pending.done || m_pending.trackId != trackId) return;
    if (auto it = m_failed.find(trackId); it != m_failed.end() && !it->permanent) it->armed = true;
    pump();
}

void AutoSync::onAligned(qint64 trackId, quint64 gen, const Result &r) {
    m_aligning = false;
    qInfo().noquote() << "[autosync] track" << trackId
                      << (r.ok ? QStringLiteral("aligned, confidence %1, %2").arg(r.confidence, 0, 'f', 3)
                                     .arg(r.kept ? QStringLiteral("shown") : QStringLiteral("not shown"))
                               : r.error);
    if (m_pending.done && m_pending.gen == gen && gen == m_gen) {
        Done done = std::move(m_pending.done);
        m_pending = {};
        done(r);
    }
    pump();
}

} // namespace lyricsync
