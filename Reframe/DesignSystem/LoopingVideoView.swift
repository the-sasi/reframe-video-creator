import AVFoundation
import SwiftUI
import UIKit

/// A muted, seamlessly looping video — for template previews. Plays while on screen and
/// pauses when it leaves, so a grid of these does not hold a decoder each while scrolled away.
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> LoopingPlayerView {
        let view = LoopingPlayerView()
        view.load(url: url, gravity: gravity)
        return view
    }

    func updateUIView(_ view: LoopingPlayerView, context: Context) {
        if view.currentURL != url { view.load(url: url, gravity: gravity) }
        view.playerLayer.videoGravity = gravity
    }

    static func dismantleUIView(_ view: LoopingPlayerView, coordinator: ()) {
        view.unload()
    }
}

final class LoopingPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private(set) var currentURL: URL?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // Selector-based so the observation is dropped with the view; no deinit bookkeeping.
        NotificationCenter.default.addObserver(
            self, selector: #selector(resumeAfterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func resumeAfterForeground() {
        if window != nil { player?.play() }
    }

    func load(url: URL, gravity: AVLayerVideoGravity) {
        unload()
        currentURL = url
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        playerLayer.player = queue
        playerLayer.videoGravity = gravity
        if window != nil { queue.play() }
    }

    func unload() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer.player = nil
        player = nil
        currentURL = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            player?.pause()
        } else {
            player?.play()
        }
    }
}
