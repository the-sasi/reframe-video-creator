import AVFoundation
import CoreGraphics
import Foundation
import MediaIO
import Metal
import MetalKit
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

/// CGImage -> MTLTexture with a bounded cache. Shared by both providers.
///
/// A lock-guarded class rather than an actor, deliberately. `MTLTexture` has no `Sendable`
/// conformance, so an actor could never hand one back to a caller in another isolation domain —
/// which is the only thing this type exists to do. A mutex has no isolation domain to cross,
/// and Metal objects are safe to use from multiple threads once created.
///
/// Same reasoning as `MetalRenderer` and `TexturePool`, which are built this way for the same
/// reason. The `@unchecked` claim covers exactly one thing: `cache` and `order`, both of which
/// are only ever touched under `lock`.
public final class TextureLoader: @unchecked Sendable {
    private let device: MTLDevice
    private let loader: MTKTextureLoader
    private var cache: [UUID: MTLTexture] = [:]
    private var order: [UUID] = []
    private let limit: Int
    private let lock = NSLock()
    /// One long-lived texture per video asset, overwritten each frame.
    private var reusable: [UUID: MTLTexture] = [:]

    public init(device: MTLDevice, limit: Int = 12) {
        self.device = device
        self.loader = MTKTextureLoader(device: device)
        self.limit = limit
    }

    public func texture(for id: UUID) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return cache[id]
    }

    public func store(_ texture: MTLTexture, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cache[id] = texture
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
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

    /// Uploads into a texture we already own, rather than allocating a new one.
    ///
    /// Video frames change every frame, so `make(from:)` would allocate and discard a
    /// full-canvas texture per frame — roughly 8 MB each at 1080x1920, which is exactly the
    /// churn `TexturePool` exists to avoid and which the export path was bypassing entirely.
    /// Reusing one texture per asset makes steady-state allocation zero.
    public func reusableTexture(
        from image: CGImage, key: UUID, maxDimension: Int
    ) -> MTLTexture? {
        let width = min(image.width, maxDimension)
        let height = min(image.height, maxDimension)
        guard width > 0, height > 0 else { return nil }

        lock.lock()
        var texture = reusable[key]
        if texture == nil || texture!.width != width || texture!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            texture = device.makeTexture(descriptor: descriptor)
            reusable[key] = texture
        }
        lock.unlock()

        guard let texture else { return nil }

        // Draw into a plain RGBA8 buffer: CGImage can arrive in any of a dozen pixel formats
        // and normalising here is cheaper than handling them all.
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        buffer.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    public func evictAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        order.removeAll()
        reusable.removeAll()
    }
}

// MARK: - Preview

/// Proxy-resolution textures, cached, tolerant of a miss.
///
/// A cache miss reuses the last good frame rather than stalling — dropping a frame of freshness
/// is invisible, dropping a frame of the display link is not.
public actor PreviewFrameProvider: FrameProvider {

    private let resolver: AssetResolver
    private let loader: TextureLoader
    private let maxDimension: Int
    private var placeholder: MTLTexture?
    private var pending: Set<UUID> = []

    public init(device: MTLDevice, resolver: AssetResolver, maxDimension: Int = 1080) {
        self.resolver = resolver
        self.loader = TextureLoader(device: device)
        self.maxDimension = maxDimension
        self.placeholder = Self.makePlaceholder(device: device)
    }

    public func resources(for plan: RenderPlan) async -> RenderResources {
        var textures: [UUID: MTLTexture] = [:]
        for id in Self.assetIDs(in: plan) {
            if let cached = loader.texture(for: id) {
                textures[id] = cached
            } else {
                // Not loaded yet: kick off the load and render this frame without it. The next
                // frame will have it, ~33 ms later.
                await load(id: id)
            }
        }
        return RenderResources(assetTextures: textures, placeholder: placeholder)
    }

    /// Warms the cache for assets the playhead is about to reach, so scrubbing forward does not
    /// show a placeholder on every new clip.
    public func prefetch(timeline: Timeline, around time: Double, lookahead: Double = 2.0) async {
        let ids = timeline.clips
            .filter { $0.start >= time - 0.5 && $0.start <= time + lookahead }
            .compactMap(\.assetID)
        // The condition lives in the body rather than a `where` clause: `where` is an
        // autoclosure, and autoclosures cannot be async.
        for id in ids {
            if loader.texture(for: id) == nil {
                await load(id: id)
            }
        }
    }

    private func load(id: UUID) async {
        guard !pending.contains(id) else { return }
        pending.insert(id)
        defer { pending.remove(id) }

        // Resolution is by id, so the pool must be reachable from the resolver's cache. The
        // caller seeds it via `register(_:)`.
        guard let reference = registry[id] else { return }
        guard let resolved = await resolver.resolve(reference, maxDimension: maxDimension)
        else { return }

        // Spelled out rather than `resolved.image ?? (await ...)`: the right-hand side of `??`
        // is an autoclosure, and autoclosures cannot be async.
        let image: CGImage?
        if let still = resolved.image {
            image = still
        } else {
            image = await Self.firstFrame(of: resolved.asset, maxDimension: maxDimension)
        }
        guard let image else { return }

        if let texture = loader.make(from: image) {
            loader.store(texture, for: id)
        }
    }

    private var registry: [UUID: AssetReference] = [:]

    /// Tells the provider which references exist. Called when the project's asset pool changes.
    public func register(_ pool: AssetPool) {
        registry = Dictionary(uniqueKeysWithValues: pool.assets.map { ($0.id, $0) })
    }

    public func evictAll() async {
        loader.evictAll()
    }

    private static func firstFrame(of asset: AVAsset?, maxDimension: Int) async -> CGImage? {
        guard let asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        // Preview tolerates a nearby keyframe; export does not.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        return try? await generator.image(at: .zero).image
    }

    static func assetIDs(in plan: RenderPlan) -> Set<UUID> {
        var ids = Set<UUID>()
        func collect(_ layers: [RenderPlan.PlanLayer]) {
            for layer in layers {
                if case .asset(let id, _) = layer.content { ids.insert(id) }
            }
        }
        switch plan.stage {
        case .single(let layers): collect(layers)
        case .transition(let stage):
            collect(stage.from)
            collect(stage.to)
        }
        collect(plan.overlays)
        return ids
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

// MARK: - Export

/// Full-resolution, exact, one frame in flight.
///
/// Stills are loaded once and held for the clips that use them. Video is decoded sequentially
/// through `AVAssetReader`, which is both the fastest way to walk a track and the only way to
/// guarantee we get the frame we asked for rather than a nearby keyframe.
public actor ExportFrameProvider: FrameProvider {

    private let resolver: AssetResolver
    private let loader: TextureLoader
    private let canvasDimension: Int
    private var registry: [UUID: AssetReference] = [:]
    private var placeholder: MTLTexture?
    private var videoReaders: [UUID: SequentialVideoReader] = [:]

    public init(device: MTLDevice, resolver: AssetResolver, pool: AssetPool, canvasDimension: Int) {
        self.resolver = resolver
        // Generous: export holds every still it has touched, because re-decoding a 48 MP photo
        // for each of its clips would dominate export time.
        self.loader = TextureLoader(device: device, limit: 32)
        self.canvasDimension = canvasDimension
        self.registry = Dictionary(uniqueKeysWithValues: pool.assets.map { ($0.id, $0) })
    }

    public func setPlaceholder(_ texture: MTLTexture?) {
        placeholder = texture
    }

    public func resources(for plan: RenderPlan) async -> RenderResources {
        var textures: [UUID: MTLTexture] = [:]

        for layer in Self.layers(in: plan) {
            guard case .asset(let id, let sourceTime) = layer.content else { continue }
            guard let reference = registry[id] else { continue }

            if reference.kind == .video {
                if let texture = await videoTexture(for: reference, at: sourceTime) {
                    textures[id] = texture
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

        return RenderResources(assetTextures: textures, placeholder: placeholder)
    }

    private func videoTexture(for reference: AssetReference, at time: Double) async -> MTLTexture? {
        if videoReaders[reference.id] == nil {
            guard let resolved = await resolver.resolve(reference),
                  let asset = resolved.asset else { return nil }
            videoReaders[reference.id] = SequentialVideoReader(
                asset: asset, maxDimension: canvasDimension
            )
        }
        guard let image = await videoReaders[reference.id]?.frame(at: time) else { return nil }
        // Reuse this asset's texture instead of allocating one per frame.
        return loader.reusableTexture(
            from: image, key: reference.id, maxDimension: canvasDimension
        )
    }

    public func finish() {
        videoReaders.removeAll()
    }

    private static func layers(in plan: RenderPlan) -> [RenderPlan.PlanLayer] {
        var all: [RenderPlan.PlanLayer] = []
        switch plan.stage {
        case .single(let layers): all += layers
        case .transition(let stage): all += stage.from + stage.to
        }
        return all + plan.overlays
    }
}

/// Walks a video track forward, holding one decoded frame.
///
/// Sequential reading rather than repeated seeking: seeking to every frame of a clip costs
/// roughly an order of magnitude more than decoding through it, and produces the same pixels.
///
/// A class rather than an actor: `AVAssetImageGenerator` is not `Sendable`, so awaiting
/// `generator.image(at:)` from inside an actor counts as sending it across a boundary. The
/// `@unchecked` claim is narrow — `ExportFrameProvider` is an actor and is the only owner, and
/// it awaits each frame in order, so calls here are already serialised.
final class SequentialVideoReader: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private var lastTime: Double = -1
    private var lastImage: CGImage?

    init(asset: AVAsset, maxDimension: Int) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }

    func frame(at time: Double) async -> CGImage? {
        // Re-decoding for a time we already have is pure waste; at 30 fps two rendered frames
        // often land inside the same source frame.
        if abs(time - lastTime) < 0.008, let lastImage { return lastImage }

        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        guard let image = try? await generator.image(at: cmTime).image else {
            // Past the end, or an undecodable frame: hold the last good one rather than
            // punching a black hole in the middle of the export.
            return lastImage
        }
        lastTime = time
        lastImage = image
        return image
    }
}
