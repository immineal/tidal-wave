// SPDX-License-Identifier: GPL-3.0-or-later

#include "AudioFeed.h"
#include "Aligner.h"

#include <QAudioBuffer>
#include <QAudioDecoder>
#include <QAudioFormat>
#include <QIODevice>
#include <QTimer>
#include <vector>

namespace lyricsync {

AudioFeed::AudioFeed(QObject *parent) : QObject(parent) {}

AudioFeed::~AudioFeed() { closeSource(); }

// The decoder goes before the device it reads.
void AudioFeed::closeSource() {
    if (m_watch) m_watch->stop();
    if (m_decoder) {
        m_decoder->disconnect(this);
        m_decoder->stop();
        delete m_decoder;
        m_decoder = nullptr;
    }
    m_device.reset();
}

bool AudioFeed::start(std::unique_ptr<QIODevice> device, FrontEnd *into) {
    if (m_decoder || !device || !device->isOpen() || !into) return false;
    m_device = std::move(device);
    m_into = into;
    m_decoder = new QAudioDecoder(this);
    if (!m_decoder->isSupported()) {
        delete m_decoder;
        m_decoder = nullptr;
        return false;
    }
    QAudioFormat fmt;
    fmt.setSampleRate(44100);
    fmt.setChannelCount(2);
    fmt.setSampleFormat(QAudioFormat::Float);
    m_decoder->setAudioFormat(fmt);
    m_decoder->setSourceDevice(m_device.get());
    connect(m_decoder, &QAudioDecoder::bufferReady, this, &AudioFeed::onBuffer);
    // Queued: some backends report the end or a bad file from inside start().
    connect(m_decoder, &QAudioDecoder::finished, this, &AudioFeed::onFinished, Qt::QueuedConnection);
    connect(m_decoder, qOverload<QAudioDecoder::Error>(&QAudioDecoder::error), this,
            [this](QAudioDecoder::Error) { fail(m_decoder->errorString()); }, Qt::QueuedConnection);
    m_watch = new QTimer(this);
    m_watch->setSingleShot(true);
    // A starved thread may see the timer before buffers that are waiting.
    connect(m_watch, &QTimer::timeout, this, [this] {
        if (m_decoder && m_decoder->bufferAvailable()) onBuffer();
        else fail(QStringLiteral("the decoder stalled"));
    });
    m_watch->start(kStallMs);
    m_decoder->start();
    return true;
}

void AudioFeed::cancel() { fail(QStringLiteral("cancelled")); }

void AudioFeed::onBuffer() {
    if (!m_done && m_watch) m_watch->start(kStallMs);
    while (!m_done && m_decoder->bufferAvailable()) {
        QString err;
        if (!appendBuffer(m_decoder->read(), m_into, &err)) { fail(err); return; }
        if (m_maxFrames && m_into->framesIn() > m_maxFrames) { fail(QStringLiteral("too long")); return; }
    }
}

// Queued from the decoder, so it may be deleted here.
void AudioFeed::onFinished() {
    if (m_done) return;
    onBuffer();
    if (m_done) return;
    m_done = true;
    closeSource();
    emit finished(m_into->framesIn() > 0, m_into->framesIn() > 0 ? QString() : QStringLiteral("no audio"));
}

// May run inside a decoder signal, so the decoder is let go of a turn later.
void AudioFeed::fail(const QString &err) {
    if (m_done) return;
    m_done = true;
    if (m_watch) m_watch->stop();
    if (m_decoder) m_decoder->stop();
    QMetaObject::invokeMethod(this, [this, err] {
        closeSource();
        emit finished(false, err.isEmpty() ? QStringLiteral("decoding failed") : err);
    }, Qt::QueuedConnection);
}

bool AudioFeed::appendBuffer(const QAudioBuffer &b, FrontEnd *into, QString *err) {
    if (!b.isValid() || b.frameCount() <= 0) return true;
    const QAudioFormat f = b.format();
    if (f.sampleRate() != 44100) {
        if (err) *err = QStringLiteral("decoder gave %1 Hz").arg(f.sampleRate());
        return false;
    }
    const int ch = f.channelCount();
    const qsizetype n = b.frameCount();
    if (ch <= 0) return false;
    std::vector<float> lr(size_t(n) * 2);
    auto put = [&](auto sample) {
        for (qsizetype i = 0; i < n; ++i) {
            const float l = sample(i * ch), r = ch > 1 ? sample(i * ch + 1) : l;
            lr[size_t(i) * 2] = l;
            lr[size_t(i) * 2 + 1] = r;
        }
    };
    switch (f.sampleFormat()) {
    case QAudioFormat::Float: { const float *p = b.constData<float>(); put([p](qsizetype i) { return p[i]; }); break; }
    case QAudioFormat::Int16: { const qint16 *p = b.constData<qint16>(); put([p](qsizetype i) { return p[i] / 32768.f; }); break; }
    case QAudioFormat::Int32: { const qint32 *p = b.constData<qint32>(); put([p](qsizetype i) { return float(p[i] / 2147483648.0); }); break; }
    case QAudioFormat::UInt8: { const quint8 *p = b.constData<quint8>(); put([p](qsizetype i) { return (p[i] - 128) / 128.f; }); break; }
    default:
        if (err) *err = QStringLiteral("unknown sample format");
        return false;
    }
    into->push(lr.data(), size_t(n));
    return true;
}

} // namespace lyricsync
