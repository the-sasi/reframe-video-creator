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
/// Crucially this calls the *same* `plan()` and `render()` as `VideoExporter`. What you see is
/// what gets written, by construction rather than by discipline.
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

    private var audioPlayer: AVAudioPlayer?
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
        self.frameProvider = PreviewFrameProvider(device: renderer.device, resolver: resolver)
        super.init()

        Task { await frameProvider.register(assets) }
    }

    public var duration: Double { timeline.duration }

    // MARK: - Transport

    public func play() {
        guard !isPlaying, duration > 0 else { return }
        if currentTime >= duration - 0.01 { currentTime = 0 }
        isPlaying = true
        lastDrawTimestamp = nil
        startAudio(at: currentTime)
    }

    public func pause() {
        isPlaying = false
        lastDrawTimestamp = nil
        audioPlayer?.pause()
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    public func seek(to time: Double) {
        currentTime = min(max(time, 0), max(0, duration))
        if isPlaying {
            startAudio(at: currentTime)
        } else {
            audioPlayer?.currentTime = currentTime
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
        if isPlaying { startAudio(at: currentTime) }
    }

    public func updateAssets(_ pool: AssetPool) {
        Task {
            await frameProvider.register(pool)
            await frameProvider.evictAll()
        }
    }

    // MARK: - Audio

    private func startAudio(at time: Double) {
        guard let clip = timeline.audio.first else { return }
        guard let audioPlayer else {
            // Not ready yet. Preparing is now driven by `currentAssetPool` being set rather
            // than by the first `play()`, so this is a genuine miss rather than the normal
            // path — previously the first play was *always* silent because preparation was
            // kicked off here and then returned immediately.
            DiagnosticsLog.shared.warning("preview", "audio not prepared yet; playing silent")
            prepareAudioPlayer(for: clip)
            return
        }
        audioPlayer.currentTime = max(0, clip.sourceStart + (time - clip.start))
        audioPlayer.volume = Float(clip.volume)
        audioPlayer.play()
    }

    /// Synchronous: `AVAudioPlayer(contentsOf:)` reads a local file and does not need to be
    /// awaited. Making it async was what created the race.
    private func prepareAudioPlayer(for clip: AudioClip) {
        guard let reference = currentAssetPool?[clip.assetID] else {
            DiagnosticsLog.shared.warning(
                "preview", "audio clip references an asset not in the pool"
            )
            return
        }
        // Only file-backed audio can drive AVAudioPlayer directly. Photos-library audio would
        // need an export first, which is not worth doing for preview — the export path handles
        // it correctly either way.
        guard case .sandboxRelativePath(let path) = reference.origin else {
            DiagnosticsLog.shared.warning(
                "preview", "audio origin is not a local file; preview will be silent"
            )
            return
        }
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(path)

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.volume = Float(clip.volume)
            audioPlayer = player
            DiagnosticsLog.shared.info("preview", "audio ready: \(reference.displayName)")
        } catch {
            DiagnosticsLog.shared.failure(
                "preview", "audio load failed: \(error.localizedDescription)"
            )
        }
    }

    /// Set by the owning view when the project's assets change. Preparing the player here
    /// rather than lazily is what removes the first-play race.
    public var currentAssetPool: AssetPool? {
        didSet {
            guard let clip = timeline.audio.first else {
                audioPlayer = nil
                return
            }
            prepareAudioPlayer(for: clip)
        }
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
    }

    /// One frame. Called from `MTKViewDelegate.draw(in:)`.
    fileprivate func renderFrame(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }

        // Advance the clock from the view's own timestamps rather than assuming a fixed frame
        // duration — a dropped frame should skip time, not slow the video down.
        if isPlaying {
            let now = CACurrentMediaTime()
            if let last = lastDrawTimestamp {
                currentTime += now - last
            }
            lastDrawTimestamp = now

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
