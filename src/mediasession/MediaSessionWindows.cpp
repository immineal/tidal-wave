// SPDX-License-Identifier: GPL-3.0-or-later

// The System Media Transport Controls: the flyout over the volume keys and
// the lock screen. A desktop app reaches them through a window handle, with
// ISystemMediaTransportControlsInterop.

// The Windows headers come before Qt's, whose keyword macros (signals,
// slots, emit) are not meant for them.
#ifndef NOMINMAX
#  define NOMINMAX
#endif
#include <windows.h>
// Before the WinRT headers, so they can take a classic COM interface.
#include <unknwn.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

#include "mediasession/MediaSession.h"

#include <QMetaObject>
#include <QPointer>
#include <QWindow>

#include <chrono>

namespace wf  = winrt::Windows::Foundation;
namespace wm  = winrt::Windows::Media;
namespace wss = winrt::Windows::Storage::Streams;

namespace {

winrt::hstring toH(const QString &s) {
    return winrt::hstring(reinterpret_cast<const wchar_t *>(s.utf16()), uint32_t(s.size()));
}

class SmtcBackend final : public MediaSessionBackend {
public:
    SmtcBackend(MediaSession *session, HWND hwnd) {
        auto interop = winrt::get_activation_factory<wm::SystemMediaTransportControls,
                                                     ISystemMediaTransportControlsInterop>();
        winrt::check_hresult(interop->GetForWindow(
            hwnd, winrt::guid_of<wm::SystemMediaTransportControls>(), winrt::put_abi(m_smtc)));

        m_smtc.IsPlayEnabled(true);
        m_smtc.IsPauseEnabled(true);
        m_smtc.IsStopEnabled(true);
        m_smtc.IsNextEnabled(true);
        m_smtc.IsPreviousEnabled(true);
        m_smtc.DisplayUpdater().Type(wm::MediaPlaybackType::Music);

        // Raised on a thread of the system's, so the press is queued over.
        QPointer<MediaSession> target(session);
        m_pressed = m_smtc.ButtonPressed(
            [target](const wm::SystemMediaTransportControls &,
                     const wm::SystemMediaTransportControlsButtonPressedEventArgs &args) {
                MediaSession::Command c;
                switch (args.Button()) {
                case wm::SystemMediaTransportControlsButton::Play:     c = MediaSession::Command::Play; break;
                case wm::SystemMediaTransportControlsButton::Pause:    c = MediaSession::Command::Pause; break;
                case wm::SystemMediaTransportControlsButton::Stop:     c = MediaSession::Command::Stop; break;
                case wm::SystemMediaTransportControlsButton::Next:     c = MediaSession::Command::Next; break;
                case wm::SystemMediaTransportControlsButton::Previous: c = MediaSession::Command::Previous; break;
                default: return;
                }
                if (!target) return;
                QMetaObject::invokeMethod(target.data(), [target, c] {
                    if (target) target->handle(c);
                }, Qt::QueuedConnection);
            });
    }

    ~SmtcBackend() override {
        try {
            m_smtc.ButtonPressed(m_pressed);
            m_smtc.IsEnabled(false);
        } catch (...) {}
    }

    void update(const MediaSessionState &s) override {
        try {
            push(s);
        } catch (const winrt::hresult_error &e) {
            qWarning("tidal-wave: media controls refused an update (0x%08x)", unsigned(e.code()));
        }
    }

private:
    void push(const MediaSessionState &s) {
        m_smtc.IsEnabled(s.hasTrack());
        if (!s.hasTrack()) {
            m_smtc.PlaybackStatus(wm::MediaPlaybackStatus::Closed);
            m_smtc.DisplayUpdater().ClearAll();
            m_cover.clear();
            return;
        }
        m_smtc.IsNextEnabled(s.canNext);
        m_smtc.IsPreviousEnabled(s.canPrevious);

        auto updater = m_smtc.DisplayUpdater();
        updater.Type(wm::MediaPlaybackType::Music);
        auto music = updater.MusicProperties();
        music.Title(toH(s.title));
        music.Artist(toH(s.artist));
        music.AlbumTitle(toH(s.album));
        // The system fetches the picture itself; only a new one is handed on.
        if (s.coverUrl != m_cover) {
            m_cover = s.coverUrl;
            wss::RandomAccessStreamReference art{nullptr};
            if (!s.coverUrl.isEmpty())
                art = wss::RandomAccessStreamReference::CreateFromUri(wf::Uri(toH(s.coverUrl)));
            updater.Thumbnail(art);
        }
        updater.Update();

        using std::chrono::milliseconds;
        wm::SystemMediaTransportControlsTimelineProperties timeline;
        timeline.StartTime(wf::TimeSpan{0});
        timeline.MinSeekTime(wf::TimeSpan{0});
        timeline.EndTime(std::chrono::duration_cast<wf::TimeSpan>(milliseconds(s.durationMs)));
        timeline.MaxSeekTime(timeline.EndTime());
        timeline.Position(std::chrono::duration_cast<wf::TimeSpan>(milliseconds(s.positionMs)));
        m_smtc.UpdateTimelineProperties(timeline);

        m_smtc.PlaybackStatus(
            s.playback == MediaSessionState::Playback::Playing ? wm::MediaPlaybackStatus::Playing
          : s.playback == MediaSessionState::Playback::Paused  ? wm::MediaPlaybackStatus::Paused
                                                               : wm::MediaPlaybackStatus::Stopped);
    }

    wm::SystemMediaTransportControls m_smtc{nullptr};
    winrt::event_token m_pressed{};
    QString m_cover;
};

} // namespace

std::unique_ptr<MediaSessionBackend> MediaSession::createPlatformBackend(MediaSession *session,
                                                                         QWindow *window) {
    if (!session || !window) return nullptr;
    try {
        return std::make_unique<SmtcBackend>(session, reinterpret_cast<HWND>(window->winId()));
    } catch (const winrt::hresult_error &e) {
        qWarning("tidal-wave: no media controls for this window (0x%08x)", unsigned(e.code()));
        return nullptr;
    }
}
