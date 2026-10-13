import Foundation
import AVFoundation
import MediaPlayer
import SwiftData

/// AVPlayer wrapper with lock-screen / headphone remote commands.
/// The bookmark (🔖) remote command is wired as "Snip".
@MainActor
final class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()

    @Published var episode: EpisodeItem?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    var onSnip: ((Double) -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var context: ModelContext?

    func attach(context: ModelContext) { self.context = context }

    func play(_ ep: EpisodeItem, localURL: URL?) {
        stop()
        episode = ep
        let url: URL = localURL ?? URL(string: ep.audioURL)!
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        duration = ep.duration > 0 ? ep.duration : 0

        timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                       queue: .main) { [weak self] t in
            guard let self else { return }
            Task { @MainActor in
                self.currentTime = t.seconds
                if self.duration <= 0, let d = self.player?.currentItem?.duration.seconds, d.isFinite {
                    self.duration = d
                }
                self.updateNowPlaying()
            }
        }
        setupRemoteCommands()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
        isPlaying = true
        updateNowPlaying()
    }

    func toggle() {
        guard player != nil else { return }
        if isPlaying { player?.pause() } else { player?.play() }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlaying()
    }

    func skip(by seconds: Double) { seek(to: max(0, currentTime + seconds)) }

    func stop() {
        if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
        player?.pause()
        player = nil
        isPlaying = false
    }

    func snipNow() { onSnip?(currentTime) }

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.toggle() } }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.toggle() } }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        cc.skipForwardCommand.preferredIntervals = [30]
        cc.skipForwardCommand.addTarget { [weak self] e in
            Task { @MainActor in self?.skip(by: (e as? MPSkipIntervalCommandEvent)?.interval ?? 30) }
            return .success
        }
        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipBackwardCommand.addTarget { [weak self] e in
            Task { @MainActor in self?.skip(by: -((e as? MPSkipIntervalCommandEvent)?.interval ?? 15)) }
            return .success
        }
        // 🔖 bookmark button (headphones/control center) = one-tap Snip
        cc.bookmarkCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.snipNow() }
            return .success
        }
        cc.bookmarkCommand.isEnabled = true
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode?.title ?? "PodSnip",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
