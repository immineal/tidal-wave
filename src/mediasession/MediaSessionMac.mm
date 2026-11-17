// SPDX-License-Identifier: GPL-3.0-or-later

// Now Playing in Control Centre and the menu bar, and the media keys, through
// MPNowPlayingInfoCenter and MPRemoteCommandCenter. Built with ARC.

#include "mediasession/MediaSession.h"

#include <QMetaObject>
#include <QPointer>

#include <memory>
#include <utility>
#include <vector>

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

namespace {

NSString *toNS(const QString &s) { return s.toNSString(); }

class NowPlayingBackend final : public MediaSessionBackend {
public:
    explicit NowPlayingBackend(MediaSession *session) {
        MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
        QPointer<MediaSession> target(session);
        // The handlers run on the main queue; queued anyway, so a press never
        // reaches the player from inside the system's call.
        auto bind = [&](MPRemoteCommand *command, MediaSession::Command c) {
            command.enabled = YES;
            id token = [command addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                if (!target) return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
                QMetaObject::invokeMethod(target.data(), [target, c] {
                    if (target) target->handle(c);
                }, Qt::QueuedConnection);
                return MPRemoteCommandHandlerStatusSuccess;
            }];
            m_targets.push_back({command, token});
        };
        bind(center.playCommand,            MediaSession::Command::Play);
        bind(center.pauseCommand,           MediaSession::Command::Pause);
        bind(center.togglePlayPauseCommand, MediaSession::Command::PlayPause);
        bind(center.stopCommand,            MediaSession::Command::Stop);
        bind(center.nextTrackCommand,       MediaSession::Command::Next);
        bind(center.previousTrackCommand,   MediaSession::Command::Previous);
    }

    ~NowPlayingBackend() override {
        *m_alive = false;
        for (const auto &t : m_targets) [t.first removeTarget:t.second];
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
    }

    void update(const MediaSessionState &s) override {
        MPNowPlayingInfoCenter *info = [MPNowPlayingInfoCenter defaultCenter];
        if (!s.hasTrack()) {
            info.nowPlayingInfo = nil;
            info.playbackState = MPNowPlayingPlaybackStateStopped;
            m_cover.clear();
            m_artwork = nil;
            return;
        }
        MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
        center.nextTrackCommand.enabled = s.canNext ? YES : NO;
        center.previousTrackCommand.enabled = s.canPrevious ? YES : NO;

        const bool playing = s.playback == MediaSessionState::Playback::Playing;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[MPMediaItemPropertyTitle] = toNS(s.title);
        d[MPMediaItemPropertyArtist] = toNS(s.artist);
        d[MPMediaItemPropertyAlbumTitle] = toNS(s.album);
        d[MPMediaItemPropertyPlaybackDuration] = @(double(s.durationMs) / 1000.0);
        d[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(double(s.positionMs) / 1000.0);
        d[MPNowPlayingInfoPropertyPlaybackRate] = @(playing ? 1.0 : 0.0);
        d[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeAudio);
        if (m_artwork && s.coverUrl == m_cover) d[MPMediaItemPropertyArtwork] = m_artwork;
        info.nowPlayingInfo = d;
        info.playbackState = playing ? MPNowPlayingPlaybackStatePlaying
                           : s.playback == MediaSessionState::Playback::Paused
                                 ? MPNowPlayingPlaybackStatePaused
                                 : MPNowPlayingPlaybackStateStopped;
        if (s.coverUrl != m_cover) fetchCover(s.coverUrl);
    }

private:
    // Off the main thread, then put in only if the track has not moved on.
    void fetchCover(const QString &url) {
        m_cover = url;
        m_artwork = nil;
        NSURL *u = url.isEmpty() ? nil : [NSURL URLWithString:toNS(url)];
        if (!u) return;
        const quint64 serial = ++m_serial;
        NowPlayingBackend *backend = this;
        std::shared_ptr<bool> alive = m_alive;
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:u
            completionHandler:^(NSData *data, NSURLResponse *, NSError *error) {
                if (error || !data) return;
                NSImage *image = [[NSImage alloc] initWithData:data];
                if (!image) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!*alive || backend->m_serial != serial) return;
                    backend->setArtwork(image);
                });
            }];
        [task resume];
    }

    void setArtwork(NSImage *image) {
        m_artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size
                                                    requestHandler:^NSImage *(CGSize) { return image; }];
        MPNowPlayingInfoCenter *info = [MPNowPlayingInfoCenter defaultCenter];
        NSMutableDictionary *d = [info.nowPlayingInfo mutableCopy];
        if (!d) return;
        d[MPMediaItemPropertyArtwork] = m_artwork;
        info.nowPlayingInfo = d;
    }

    std::vector<std::pair<MPRemoteCommand *, id>> m_targets;
    QString m_cover;
    MPMediaItemArtwork *m_artwork = nil;
    quint64 m_serial = 0;
    // Read by a cover fetch that finishes after the backend is gone.
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
};

} // namespace

std::unique_ptr<MediaSessionBackend> MediaSession::createPlatformBackend(MediaSession *session,
                                                                         QWindow *) {
    if (!session) return nullptr;
    return std::make_unique<NowPlayingBackend>(session);
}
