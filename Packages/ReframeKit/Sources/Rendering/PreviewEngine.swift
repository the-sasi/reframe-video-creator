import AVFoundation
import Foundation
import MediaIO
import Metal
import MetalKit
import Observation
import QuartzCore
import RecipeCore

/// Drives live preview.
///
/// The `MTKView` is the clock: its `draw(in:)` fires at the display rate, and each call
/// advances time and renders one plan. No `CADisplayLink`, no separate timer, no chance of the
/// render and the clock disagreeing.
///
/// Crucially this calls the *same* `plan()` and `render()` as `VideoExporter`, and plays the
/// *same* `AudioMixPlan` the exporter writes. What you see and hear is what gets written, by
/// construction rather than by discipline.
@MainActor
@Observable
public final class PreviewEngine: NSObject {

    public private(set) var currentTime: Double = 0
    public private(set) var isPlaying: Bool = false
    /// Set when rendering fails, so the UI can show a recovery action rather than a black view.
    public private(set) var lastError: ReframeError?

    public var timeline: Timeline {
        didSet { handleTimelineChange(from: oldValue) }
    }

    private let renderer: MetalRenderer
    private let planner = RenderPlanner()
    private let frameProvider: PreviewFrameProvider
    private let resolver: AssetResolver
    private var assets: AssetPool

    /// The mixed audio, as an `AVPlayer` over the same composition the exporter reads.
    private var audioPlayer: AVPlayer?
    private var audioComposition: AudioMixComposition?
    private var audioBuildTask: Task<Void, Never>?
    private var lastDrawTimestamp: CFTimeInterval?
    private var prefetchTask: Task<Void, Never>?
    /// Guards against a second render being requested while one is still in flight, which on a
    /// slow frame would queue up work faster than the GPU retires it.
    private var isRendering = false

    public init(
        renderer: MetalRenderer,
        resolver: AssetResolver,
        timeline: Timeline,
        assets: AssetPool
    ) {
        self.renderer = renderer
        self.resolver = resolver
        self.timeline = timeline
        self.assets = assets
        self.frameProvider = PreviewFrameProvider(device: renderer.device, resolver: resolver)
        super.init()

        Self.configureAudioSession()
        Task { await frameProvider.register(assets) }
        rebuildAudioIfNeeded()
    }

    public var duration: Double { timeline.duration }

    // MARK: - Transport

    public func play() {
        guard !isPlaying, duration > 0 else { return }
        if currentTime >= duration - 0.01 { currentTime = 0 }
        isPlaying = true
        lastDrawTimestamp = nil
        Task { await frameProvider.setPlaying(true) }
        startAudio(at: currentTime)
    }

    public func pause() {
        isPlaying = false
        lastDrawTimestamp = nil
        audioPlayer?.pause()
        Task { await frameProvider.setPlaying(false) }
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    public func seek(to time: Double) {
        currentTime = min(max(time, 0), max(0, duration))
        if isPlaying {
            startAudio(at: currentTime)
        } else {
            seekAudio(to: currentTime)
        }
        schedulePrefetch()
    }

    /// Called continuously during a scrub gesture. Audio is suspended for the duration —
    /// scrubbing audio is a distinctive effect that nobody has ever wanted in a preview.
    public func scrub(to time: Double) {
        currentTime = min(max(time, 0), max(0, duration))
        audioPlayer?.pause()
        schedulePrefetch()
    }

    public func endScrub() {
        if isPlaying { startAudio(at: currentTime) } else { seekAudio(to: currentTime) }
    }

    /// Memory warning: drop every regenerable texture and player. The next frame reloads what
    /// it needs at the current playhead; nothing else is lost.
    public func handleMemoryPressure() {
        Task { await frameProvider.evictAll() }
        renderer.evictCaches()
        DiagnosticsLog.shared.warning("preview", "evicted preview caches under memory pressure")
    }

    /// The pool changed — an asset was added, replaced or removed. Textures for assets that
    /// are still present are kept; only the registry and the audio mix are refreshed.
    public func updateAssets(_ pool: AssetPool) {
        assets = pool
        Task { await frameProvider.register(pool) }
        rebuildAudioIfNeeded()
    }

    // MARK: - Audio

    /// Preview must be audible with the silent switch on — every video editor behaves that way,
    /// and a silent preview reads as "the audio is broken". `.playback` also keeps the mix
    /// running through a background transition long enough to pause cleanly.
    private static func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
    }

    private func rebuildAudioIfNeeded() {
        let plan = AudioMixPlanner().plan(timeline, assets: assets)
        if let existing = audioComposition, existing.plan == plan { return }
        if plan.isEmpty {
            audioComposition = nil
            audioPlayer?.pause()
            audioPlayer = nil
            audioBuildTask?.cancel()
            return
        }

        audioBuildTask?.cancel()
        let resolver = self.resolver
        let assets = self.assets
        audioBuildTask = Task { [weak self] in
            let built = await AudioMixBuilder.build(plan: plan, resolver: resolver, assets: assets)
            guard !Task.isCancelled, let self else { return }
            self.installAudio(built)
        }
    }

    private func installAudio(_ built: AudioMixComposition) {
        audioComposition = built
        let wasPlaying = isPlaying
        audioPlayer?.pause()

        guard !built.isEmpty else {
            audioPlayer = nil
            return
        }
        let item = AVPlayerItem(asset: built.composition)
        item.audioMix = built.audioMix
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        audioPlayer = player
        DiagnosticsLog.shared.info("preview", "audio mix ready: \(built.plan.tracks.count) track(s)")

        if wasPlaying {
            startAudio(at: currentTime)
        } else {
            seekAudio(to: currentTime)
        }
    }

    /// Bumped for every audio seek; the render tick only trusts the audio clock when the
    /// latest seek has completed. Without this, seeking while playing reads the player's old
    /// position for a few frames and visibly snaps the playhead backwards.
    private var audioSeekGeneration = 0
    private var audioClockSettled = true

    private func startAudio(at time: Double) {
        guard let audioPlayer else { return }
        audioSeekGeneration += 1
        let generation = audioSeekGeneration
        audioClockSettled = false
        audioPlayer.pause()
        let target = CMTime(seconds: max(0, time), preferredTimescale: 44_100)
        audioPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            // The completion handler is not main-actor-isolated; hop back before touching state.
            Task { @MainActor in
                guard let self, generation == self.audioSeekGeneration else { return }
                self.audioClockSettled = true
                guard self.isPlaying else { return }
                self.audioPlayer?.play()
            }
        }
    }

    private func seekAudio(to time: Double) {
        audioPlayer?.seek(
            to: CMTime(seconds: max(0, time), preferredTimescale: 44_100),
            toleranceBefore: CMTime(value: 1, timescale: 30), toleranceAfter: CMTime(value: 1, timescale: 30)
        )
    }

    // MARK: - Rendering

    private func schedulePrefetch() {
        prefetchTask?.cancel()
        let timeline = self.timeline
        let time = self.currentTime
        prefetchTask = Task { [frameProvider] in
            await frameProvider.prefetch(timeline: timeline, around: time)
        }
    }

    private func handleTimelineChange(from old: Timeline) {
        if currentTime > timeline.duration {
            currentTime = max(0, timeline.duration)
        }
        schedulePrefetch()
        rebuildAudioIfNeeded()
    }

    /// One frame. Called from `MTKViewDelegate.draw(in:)`.
    fileprivate func renderFrame(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }

        if isPlaying {
            // When there is a mix, the audio player is the master clock — audio drift is what
            // people notice, and slaving video to it is how every player keeps sync. Without a
            // mix, advance from the view's own timestamps so a dropped frame skips time rather
            // than slowing the video down.
            if let audioPlayer, audioPlayer.rate > 0, audioClockSettled {
                let audioTime = audioPlayer.currentTime().seconds
                if audioTime.isFinite, abs(audioTime - currentTime) > 0.04 {
                    currentTime = audioTime
                } else if let last = lastDrawTimestamp {
                    currentTime += CACurrentMediaTime() - last
                }
            } else if let last = lastDrawTimestamp {
                currentTime += CACurrentMediaTime() - last
            }
            lastDrawTimestamp = CACurrentMediaTime()

            if currentTime >= duration {
                currentTime = duration
                pause()
            }
        }

        guard !isRendering else { return }
        isRendering = true

        let plan = planner.plan(timeline, at: currentTime)
        let surface = DrawableBox(drawable: drawable)

        // Detached on purpose. `MetalRenderer.render` confines its encoding to a serial queue
        // via `sync`, and doing that from the main actor would block the very thread that has
        // to service the next display-link callback. Only the result hops back.
        Task.detached(priority: .userInitiated) { [renderer, frameProvider] in
            let resources = await frameProvider.resources(for: plan)
            var failure: ReframeError?
            do {
                try renderer.render(
                    plan: plan, resources: resources, into: surface.texture,
                    waitForCompletion: false
                )
                surface.present()
            } catch let error as ReframeError {
                failure = error
            } catch {
                failure = .renderSetupFailed(detail: error.localizedDescription)
            }
            await MainActor.run {
                // Log the transition only. A broken preview fails identically 30 times a
                // second, and an unfiltered log would be nothing but that one line.
                if let failure, self.lastError != failure {
                    DiagnosticsLog.shared.failure("preview", failure.logDetail)
                }
                self.lastError = failure
                self.isRendering = false
            }
        }
    }

    /// Hands the engine an `MTKView` configured for it.
    public func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.autoResizeDrawable = true
        view.delegate = self
        return view
    }

    /// Renders one frame at `time` into a CPU-readable image, for project thumbnails.
    ///
    /// Same planner, same renderer, so the poster frame *is* a frame of the video. Runs at a
    /// small size so it costs a few milliseconds.
    public func snapshot(at time: Double, maxDimension: Int = 360) async -> CGImage? {
        let plan = planner.plan(timeline, at: time)
        let canvas = timeline.canvas
        let scale = Double(maxDimension) / Double(max(canvas.width, canvas.height))
        let width = max(2, Int(Double(canvas.width) * scale)) & ~1
        let height = max(2, Int(Double(canvas.height) * scale)) & ~1

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: descriptor) else { return nil }

        let resources = await frameProvider.resources(for: plan)
        guard (try? renderer.render(plan: plan, resources: resources, into: target, waitForCompletion: true)) != nil else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

/// Carries a `CAMetalDrawable` across an isolation boundary.
///
/// `@unchecked Sendable` because the drawable is handed to exactly one task, used once, and
/// presented once — the ownership is linear even though the type cannot express that.
private struct DrawableBox: @unchecked Sendable {
    let drawable: any CAMetalDrawable
    var texture: MTLTexture { drawable.texture }
    func present() { drawable.present() }
}

extension PreviewEngine: MTKViewDelegate {
    nonisolated public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated public func draw(in view: MTKView) {
        // MTKView always calls its delegate on the main thread; `assumeIsolated` states that
        // rather than hopping and losing a frame of latency.
        MainActor.assumeIsolated {
            self.renderFrame(in: view)
        }
    }
}
