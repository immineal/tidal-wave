// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QString>
#include <memory>

class QAudioDecoder;
class QAudioBuffer;
class QIODevice;

namespace lyricsync {

class FrontEnd;

// Decodes an audio file with Qt's own decoder into a FrontEnd, as 44.1 kHz
// stereo float. Lives on a thread with an event loop; one file per object.
class AudioFeed : public QObject {
    Q_OBJECT
public:
    explicit AudioFeed(QObject *parent = nullptr);
    ~AudioFeed() override;

    // Takes ownership of an opened device. False when it could not start.
    bool start(std::unique_ptr<QIODevice> device, FrontEnd *into);
    void cancel();
    // Past this many input frames decoding stops and fails; 0 for no limit.
    void setMaxFrames(size_t frames) { m_maxFrames = frames; }

    // Folds one buffer into 44.1 kHz stereo float; false when its rate or
    // format cannot be used. Public for the tests.
    static bool appendBuffer(const QAudioBuffer &b, FrontEnd *into, QString *err);

signals:
    // Every buffer has gone into the FrontEnd, or decoding stopped (ok false).
    // Never emitted from inside start(); the device is closed by then.
    void finished(bool ok, const QString &error);

private:
    void onBuffer();
    void onFinished();
    void fail(const QString &err);
    void closeSource();

    QAudioDecoder *m_decoder = nullptr;
    std::unique_ptr<QIODevice> m_device;
    FrontEnd *m_into = nullptr;
    size_t m_maxFrames = 0;
    bool m_done = false;
};

} // namespace lyricsync
