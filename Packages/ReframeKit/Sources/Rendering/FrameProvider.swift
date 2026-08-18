import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import MediaIO
import Metal
import MetalKit
import QuartzCore
import RecipeCore

/// Supplies source pixels to the renderer.
///
/// The renderer cannot tell the two implementations apart, which is the entire point: preview
/// and export differ *only* in where their pixels come from, never in how those pixels are
/// composited. Divergence between what you preview and what you export is unrepresentable.
public protocol FrameProvider: Sendable {
    /// Textures for everything the plan needs. Called once per frame, before rendering.
    func resources(for plan: RenderPlan) async -> RenderResources
}

// MARK: - Shared texture loading

/// CGImage -> MTLTexture with a byte-budgeted cache. Shared by both providers.
///
/// A lock-guarded class rather than an actor, deliberately. `MTLTexture` has no `Sendable`
/// conformance, so an actor could never hand one back to a caller in another isolation domain —
/// which is the only thing this type exists to do. A mutex has no isolation domain to cross,
/// and Metal objects are safe to use from multiple threads once created.
///
/// Budgeted in *bytes*, not entries: an entry cap of 32 let a 4K export pin over a gigabyte of
/// still textures. Eviction is oldest-first, which for a sequential export is exactly LRU.
public final class TextureLoader: @unchecked Sendable {
    private let device: MTLDevice
    private let loader: MTKTextureLoader
    private var cache: [UUID: MTLTexture] = [:]
    private var order: [UUID] = []
    private var bytesInCache = 0
    private let byteBudget: Int
    private let lock = NSLock()

    public init(device: MTLDevice, byteBudget: Int = 160 * 1_048_576) {
        self.device = device
        self.loader = MTKTextureLoader(device: device)
        self.byteBudget = byteBudget
    }

    public func texture(for id: UUID) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if let texture = cache[id] {
            // Touch: move to the recent end.
            order.removeAll { $0 == id }
            order.append(id)
            return texture
        }
        return nil
    }

    public func store(_ texture: MTLTexture, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let old = cache[id] { bytesInCache -= Self.bytes(of: old) }
        cache[id] = texture
        bytesInCache += Self.bytes(of: texture)
        order.removeAll { $0 == id }
        order.append(id)
        while bytesInCache > byteBudget, order.count > 1 {
            let evicted = order.removeFirst()
            if let gone = cache.removeValue(forKey: evicted) { bytesInCache -= Self.bytes(of: gone) }
        }
    }

    public func make(from image: CGImage) -> MTLTexture? {
        // MTKTextureLoader is documented as safe to use concurrently, so this stays outside
        // the lock — texture creation is the slow part and serialising it would throttle
        // export for no safety benefit.
        try? loader.newTexture(
            cgImage: image,
            options: [
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            ]
        )
    }

    public func evictAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        order.removeAll()
        bytesInCache = 0
    }

    private static func bytes(of texture: MTLTexture) -> Int {
        texture.width * texture.height * 4
    }
}

// MARK: - Pixel buffers -> textures

/// Wraps `CVMetalTextureCache`: a `CVPixelBuffer` becomes an `MTLTexture` with no copy.
///
/// The `CVMetalTexture` must outlive the `MTLTexture` — releasing it early recycles the
/// IOSurface under the renderer. `Held` keeps both together, and holders retain the most
/// recent one until the frame after they hand it over.
final class PixelBufferTextures: @unchecked Sendable {
    struct Held {
        let texture: MTLTexture
        let backing: CVMetalTexture
        let pixelBuffer: CVPixelBuffer
    }

    private var cache: CVMetalTextureCache?

    init(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.cache = cache
    }

    func texture(from pixelBuffer: CVPixelBuffer) -> Held? {
        guard let cache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return Held(texture: texture, backing: cvTexture, pixelBuffer: pixelBuffer)
    }

    func flush() {
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }
}

/// Decoded-frame geometry shared by both video paths.
enum VideoGeometry {
    /// Even, aspect-preserving output dimensions for the decoder, capped at `maxDimension`.
    static func outputSize(naturalWidth: Double, naturalHeight: Double, maxDimension: Int) -> (Int, Int) {
        guard naturalWidth > 0, naturalHeight > 0 else { return (maxDimension, maxDimension) }
        let scale = min(1.0, Double(maxDimension) / max(naturalWidth, naturalHeight))
        let w = max(2, Int((naturalWidth * scale).rounded()))
        let h = max(2, Int((naturalHeight * scale).rounded()))
        return (w - w % 2, h - h % 2)
    }

    static func pixelBufferAttributes(width: Int, height: Int) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
    }

    /// The upright-UV -> texture-UV map for a track, from its preferred transform.
    static func sourceTransform(for track: AVAssetTrack) async -> SourceUVTransform {
        guard let transform = try? await track.load(.preferredTransform),
              let size = try? await track.load(.naturalSize) else { return .identity }
        return SourceUVTransform.fromPreferredTransform(
            a: transform.a, b: transform.b, c: transform.c, d: transform.d,
            tx: transform.tx, ty: transform.ty,
            naturalWidth: size.width, naturalHeight: size.height
        )
    }
}

// MARK: - Preview

/// Proxy-resolution textures, cached, tolerant of a miss.
///
/// Stills are decoded once and cached. Video plays through an `AVPlayer` per asset whose frames
/// are pulled by `AVPlayerItemVideoOutput` and wrapped as Metal textures with no copy — so a
/// clip in the preview genuinely *plays*, at the clip's speed, from the clip's source offset,
/// rather than sitting on its first frame. Scrubbing seeks. A cache miss reuses the last good
/// frame rather than stalling: dropping a frame of freshness is invisible, dropping a frame of
/// the display link is not.
public actor PreviewFrameProvider: FrameProvider {

    private let device: MTLDevice
    private let resolver: AssetResolver
    private let loader: TextureLoader
    private let pixelTextures: PixelBufferTextures
    private let maxDimension: Int
    private var placeholder: MTLTexture?
    private var pending: Set<UUID> = []
    private var registry: [UUID: AssetReference] = [:]
    private var players: [UUID: PreviewVideoPlayer] = [:]
    private var playerOrder: [UUID] = []
    private var isPlaying = false
    private let playerLimit = 4

    public init(device: MTLDevice, resolver: AssetResolver, maxDimension: Int = 1080) {
        self.device = device
        self.resolver = resolver
        self.loader = TextureLoader(device: device, byteBudget: 96 * 1_048_576)
        self.pixelTextures = PixelBufferTextures(device: device)
        self.maxDimension = maxDimension
        self.placeholder = Self.makePlaceholder(device: device)
    }

    /// The engine tells the provider whether the transport is running, so video players can
    /// roll rather than seek frame by frame.
    public func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if !playing {
            for player in players.values { player.pause() }
        }
    }

    public func resources(for plan: RenderPlan) async -> RenderResources {
        var textures: [UUID: MTLTexture] = [:]
        var transforms: [UUID: SourceUVTransform] = [:]
        var activeVideoIDs: Set<UUID> = []

        for layer in Self.assetLayers(in: plan) {
            guard case .asset(let id, let sourceTime) = layer.content else { continue }
            guard let reference = registry[id] else { continue }

            if reference.kind == .video {
                activeVideoIDs.insert(id)
                if let player = await player(for: reference) {
                    if let held = player.frame(at: sourceTime, playing: isPlaying) {
                        textures[id] = held.texture
                    } else if let last = player.lastTexture {
                        textures[id] = last
                    }
                    transforms[id] = player.sourceTransform
                }
            } else if let cached = loader.texture(for: id) {
                textures[id] = cached
            } else {
                // Not loaded yet: kick off the load and render this frame without it. The next
                // frame will have it, ~33 ms later.
                await load(id: id)
                if let now = loader.texture(for: id) { textures[id] = now }
            }
        }

        // Players for clips that are not on screen must not keep rolling.
        for (id, player) in players where !activeVideoIDs.contains(id) {
            player.pause()
        }

        return RenderResources(assetTextures: textures, sourceTransforms: transforms, placeholder: placeholder)
    }

    /// Warms the cache for assets the playhead is about to reach, so scrubbing forward does not
    /// show a placeholder on every new clip.
    public func prefetch(timeline: Timeline, around time: Double, lookahead: Double = 2.0) async {
        let upcoming = timeline.clips
            .filter { $0.start >= time - 0.5 && $0.start <= time + lookahead }
        for clip in upcoming {
            guard let id = clip.assetID, let reference = registry[id] else { continue }
            if reference.kind == .video {
                if let player = await player(for: reference) {
                    player.preroll(at: clip.sourceStart)
                }
            } else if loader.texture(for: id) == nil {
                await load(id: id)
            }
        }
    }

    private func load(id: UUID) async {
        guard !pending.contains(id) else { return }
        pending.insert(id)
        defer { pending.remove(id) }

        guard let reference = registry[id] else { return }
        guard let resolved = await resolver.resolve(reference, maxDimension: maxDimension),
              let image = resolved.image else { return }
        if let texture = loader.make(from: image) {
            loader.store(texture, for: id)
        }
    }

    private func player(for reference: AssetReference) async -> PreviewVideoPlayer? {
        if let existing = players[reference.id] {
            playerOrder.removeAll { $0 == reference.id }
            playerOrder.append(reference.id)
            return existing
        }
        guard !pending.contains(reference.id) else { return nil }
        pending.insert(reference.id)
        defer { pending.remove(reference.id) }

        guard let resolved = await resolver.resolve(reference), let asset = resolved.asset,
              let player = await PreviewVideoPlayer(
                asset: asset, maxDimension: maxDimension, textures: pixelTextures
              ) else { return nil }
        players[reference.id] = player
        playerOrder.append(reference.id)
        while playerOrder.count > playerLimit {
            let evicted = playerOrder.removeFirst()
            players.removeValue(forKey: evicted)?.tearDown()
        }
        return player
    }

    /// Tells the provider which references exist. Called when the project's asset pool changes.
    public func register(_ pool: AssetPool) {
        let fresh = Dictionary(uniqueKeysWithValues: pool.assets.map { ($0.id, $0) })
        // Drop players for assets that left the pool; keep everything else warm.
        for id in players.keys where fresh[id] == nil {
            players.removeValue(forKey: id)?.tearDown()
            playerOrder.removeAll { $0 == id }
        }
        registry = fresh
    }

    public func evictAll() async {
        loader.evictAll()
        for player in players.values { player.tearDown() }
        players.removeAll()
        playerOrder.removeAll()
        pixelTextures.flush()
    }

    static func assetLayers(in plan: RenderPlan) -> [RenderPlan.PlanLayer] {
        var all: [RenderPlan.PlanLayer] = []
        switch plan.stage {
        case .single(let layers): all += layers
        case .transition(let stage): all += stage.from + stage.to
        }
        return all + plan.overlays
    }

    /// A neutral grey card for empty slots. Rendering a labelled placeholder is what keeps a
    /// missing photo from being a crash or a silently dropped scene.
    private static func makePlaceholder(device: MTLDevice) -> MTLTexture? {
        let size = 16
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 32
            pixels[i + 1] = 32
            pixels[i + 2] = 36
            pixels[i + 3] = 255
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: size * 4
            )
        }
        return texture
    }
}

/// One `AVPlayer` per video asset in the preview, muted, driven by the timeline clock.
///
/// Playing: the player rolls at `rate` and frames are pulled at its own clock; drift against
/// the timeline beyond a few frames triggers a seek. Paused or scrubbing: every request is a
/// seek with a tolerance of about a frame, which is what makes dragging the playhead over a
/// clip show the clip moving.
///
/// A class rather than an actor: `AVPlayer` and `AVPlayerItemVideoOutput` are not `Sendable`,
/// and the owning actor already serialises every call.
final class PreviewVideoPlayer: @unchecked Sendable {
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private let textures: PixelBufferTextures
    private var held: PixelBufferTextures.Held?
    private var lastRequestedTime: Double = -1
    private var lastRequestWall: CFTimeInterval = 0
    /// Playback rate inferred from how fast the requested source time advances against the
    /// wall clock — the plan carries source times, not speeds, and this is what keeps a 2×
    /// clip rolling at 2× rather than seeking every quarter-second.
    private var estimatedRate: Double = 1
    private var seekInFlight = false
    let sourceTransform: SourceUVTransform
    private(set) var isReady = false

    var lastTexture: MTLTexture? { held?.texture }

    init?(asset: AVAsset, maxDimension: Int, textures: PixelBufferTextures) async {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize) else { return nil }
        let (width, height) = VideoGeometry.outputSize(
            naturalWidth: natural.width, naturalHeight: natural.height, maxDimension: maxDimension
        )
        self.sourceTransform = await VideoGeometry.sourceTransform(for: track)
        self.textures = textures

        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: VideoGeometry.pixelBufferAttributes(width: width, height: height)
        )
        item.add(output)
        self.item = item
        self.output = output

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        // Preview audio is mixed separately from the same plan; this player must never make
        // a sound of its own or the mix would be double-counted.
        player.volume = 0
        self.player = player
        self.isReady = true
    }

    /// The frame for `sourceTime`, or nil if none is ready yet (the caller keeps the last one).
    func frame(at sourceTime: Double, playing: Bool) -> PixelBufferTextures.Held? {
        let target = CMTime(seconds: max(0, sourceTime), preferredTimescale: 600)
        let current = player.currentTime().seconds
        let drift = abs(current - sourceTime)
        let now = CACurrentMediaTime()

        if playing {
            // Update the rate estimate from the last request, smoothed and clamped.
            let wallDelta = now - lastRequestWall
            if lastRequestWall > 0, wallDelta > 0.01, wallDelta < 0.5, lastRequestedTime >= 0 {
                let observed = (sourceTime - lastRequestedTime) / wallDelta
                if observed > 0.1, observed < 8 {
                    estimatedRate = estimatedRate * 0.7 + observed * 0.3
                }
            }
            let rate = min(4, max(0.25, estimatedRate))
            if player.rate == 0 || abs(Double(player.rate) - rate) > 0.08 || drift > 0.25 {
                if drift > 0.12 { seek(to: target, precise: false) }
                player.rate = Float(rate)
            }
        } else {
            if player.rate != 0 { player.pause() }
            estimatedRate = 1
            // Only seek when the request actually moved; a paused preview asks for the same
            // frame thirty times a second.
            if abs(sourceTime - lastRequestedTime) > 0.004 {
                seek(to: target, precise: true)
            }
        }
        lastRequestedTime = sourceTime
        lastRequestWall = now

        let itemTime = playing ? player.currentTime() : target
        let queryTime = output.hasNewPixelBuffer(forItemTime: itemTime) ? itemTime : item.currentTime()
        if output.hasNewPixelBuffer(forItemTime: queryTime),
           let buffer = output.copyPixelBuffer(forItemTime: queryTime, itemTimeForDisplay: nil),
           let fresh = textures.texture(from: buffer) {
            held = fresh
            return fresh
        }
        return nil
    }

    private func seek(to time: CMTime, precise: Bool) {
        // Coalesce: a seek already running will be followed by another as soon as it lands.
        guard !seekInFlight else { return }
        seekInFlight = true
        let tolerance = precise
            ? CMTime(value: 1, timescale: 60)
            : CMTime(value: 1, timescale: 8)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            self?.seekInFlight = false
        }
    }

    func preroll(at sourceTime: Double) {
        guard player.rate == 0 else { return }
        seek(to: CMTime(seconds: max(0, sourceTime), preferredTimescale: 600), precise: true)
    }

    func pause() {
        if player.rate != 0 { player.pause() }
    }

    func tearDown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        held = nil
    }
}

// MARK: - Export

/// Full-resolution, exact, one frame in flight.
///
/// Stills are loaded once and held within a byte budget. Video is decoded *sequentially* through
/// `AVAssetReader` — the fastest way to walk a track, and the only way to guarantee we get the
/// frame we asked for rather than a nearby keyframe — and each decoded buffer is wrapped as a
/// Metal texture with no copy.
public actor ExportFrameProvider: FrameProvider {

    private let resolver: AssetResolver
    private let loader: TextureLoader
    private let pixelTextures: PixelBufferTextures
    private let canvasDimension: Int
    private var registry: [UUID: AssetReference] = [:]
    private var placeholder: MTLTexture?
    private var videoDecoders: [UUID: SequentialVideoDecoder] = [:]

    public init(device: MTLDevice, resolver: AssetResolver, pool: AssetPool, canvasDimension: Int) {
        self.resolver = resolver
        // Roughly a dozen 1080p stills, or three 4K ones. Enough that a still reused across
        // several clips is decoded once; small enough that a 4K export cannot be jetsammed by
        // its own texture cache.
        self.loader = TextureLoader(device: device, byteBudget: 120 * 1_048_576)
        self.pixelTextures = PixelBufferTextures(device: device)
        self.canvasDimension = canvasDimension
        self.registry = Dictionary(uniqueKeysWithValues: pool.assets.map { ($0.id, $0) })
    }

    public func setPlaceholder(_ texture: MTLTexture?) {
        placeholder = texture
    }

    public func resources(for plan: RenderPlan) async -> RenderResources {
        var textures: [UUID: MTLTexture] = [:]
        var transforms: [UUID: SourceUVTransform] = [:]

        for layer in PreviewFrameProvider.assetLayers(in: plan) {
            guard case .asset(let id, let sourceTime) = layer.content else { continue }
            guard let reference = registry[id] else { continue }

            if reference.kind == .video {
                if let decoder = await decoder(for: reference) {
                    if let texture = decoder.texture(at: sourceTime) {
                        textures[id] = texture
                    }
                    transforms[id] = decoder.sourceTransform
                }
            } else if let cached = loader.texture(for: id) {
                textures[id] = cached
            } else if let resolved = await resolver.resolve(reference, maxDimension: canvasDimension),
                      let image = resolved.image,
                      let texture = loader.make(from: image) {
                loader.store(texture, for: id)
                textures[id] = texture
            }
        }

        return RenderResources(assetTextures: textures, sourceTransforms: transforms, placeholder: placeholder)
    }

    private func decoder(for reference: AssetReference) async -> SequentialVideoDecoder? {
        if let existing = videoDecoders[reference.id] { return existing }
        guard let resolved = await resolver.resolve(reference),
              let asset = resolved.asset,
              let decoder = await SequentialVideoDecoder(
                asset: asset, maxDimension: canvasDimension, textures: pixelTextures
              ) else { return nil }
        videoDecoders[reference.id] = decoder
        return decoder
    }

    public func finish() {
        for decoder in videoDecoders.values { decoder.finish() }
        videoDecoders.removeAll()
        loader.evictAll()
        pixelTextures.flush()
    }
}

/// Walks a video track forward through `AVAssetReader`, holding one decoded frame.
///
/// A request earlier than the frame in hand — the same clip reused later in the timeline, say —
/// restarts the reader at that time. Everything else is a straight read-ahead, which is roughly
/// an order of magnitude faster than seeking to each frame with `AVAssetImageGenerator` (which
/// decodes from the previous keyframe every time).
///
/// A class rather than an actor: `AVAssetReader` is not `Sendable`, and `ExportFrameProvider`
/// is an actor and the only owner, so calls here are already serialised.
final class SequentialVideoDecoder: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let outputWidth: Int
    private let outputHeight: Int
    private let textures: PixelBufferTextures
    private let frameDuration: Double
    let sourceTransform: SourceUVTransform

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: (time: Double, held: PixelBufferTextures.Held)?
    private var lookahead: (time: Double, buffer: CVPixelBuffer)?
    private var exhausted = false

    init?(asset: AVAsset, maxDimension: Int, textures: PixelBufferTextures) async {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize) else { return nil }
        self.asset = asset
        self.track = track
        self.textures = textures
        (outputWidth, outputHeight) = VideoGeometry.outputSize(
            naturalWidth: natural.width, naturalHeight: natural.height, maxDimension: maxDimension
        )
        let fps = (try? await track.load(.nominalFrameRate)) ?? 30
        self.frameDuration = fps > 0 ? 1.0 / Double(fps) : 1.0 / 30
        self.sourceTransform = await VideoGeometry.sourceTransform(for: track)
    }

    /// The decoded frame whose presentation time is the latest one at or before `time`.
    func texture(at time: Double) -> MTLTexture? {
        let wanted = max(0, time)

        // Going backwards, or first use: (re)start at the wanted time.
        if reader == nil || (current.map { wanted < $0.time - frameDuration * 0.5 } ?? false) {
            restart(at: wanted)
        }

        // Advance until the *next* frame would be past the wanted time.
        while !exhausted {
            if lookahead == nil { lookahead = readNext() }
            guard let next = lookahead else { exhausted = true; break }
            if next.time <= wanted + frameDuration * 0.25 {
                if let held = textures.texture(from: next.buffer) {
                    current = (next.time, held)
                }
                lookahead = nil
            } else {
                break
            }
        }
        // Past the end, or an undecodable frame: hold the last good one rather than punching
        // a black hole in the middle of the export.
        return current?.held.texture
    }

    private func restart(at time: Double) {
        reader?.cancelReading()
        reader = nil
        output = nil
        lookahead = nil
        exhausted = false

        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: VideoGeometry.pixelBufferAttributes(width: outputWidth, height: outputHeight)
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        // Start a little early so the first frame at or before `time` is delivered even when
        // `time` sits between two presentation stamps.
        let start = max(0, time - frameDuration)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity
        )
        guard reader.startReading() else { return }
        self.reader = reader
        self.output = output
    }

    private func readNext() -> (time: Double, buffer: CVPixelBuffer)? {
        guard let output else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // The pixel buffer's lifetime is independent of the sample buffer once retained.
            return (pts.isFinite ? pts : 0, buffer)
        }
        return nil
    }

    func finish() {
        reader?.cancelReading()
        reader = nil
        output = nil
        current = nil
        lookahead = nil
    }
}
