import Foundation
import Metal
import MetalPerformanceShaders
import RecipeCore
import simd

/// Mirrors `LayerUniforms` in Shaders.metal. Field order and padding must match exactly.
struct LayerUniforms {
    var destination: SIMD4<Float>
    var sourceCrop: SIMD4<Float>
    var grade: SIMD4<Float>
    /// vignette, grain, time, unused
    var effects: SIMD4<Float>
    /// Upright-UV -> texture-UV, as (a, b, c, d); the translation rides in `sourceOffset`.
    /// Identity for photos and text; a rotation for video decoded in its natural orientation.
    var sourceTransform: SIMD4<Float>
    /// Canvas-space point the rotation is about.
    var pivot: SIMD2<Float>
    var sourceOffset: SIMD2<Float>
    var opacity: Float
    var rotation: Float
    var scale: Float
    var pad0: Float = 0
}

/// Mirrors `TransitionUniforms` in Shaders.metal.
struct TransitionUniforms {
    var progress: Float
    var kind: Int32
    var direction: Int32
    var pad: Float = 0
}

/// Textures the renderer needs but does not own. Resolved by a `FrameProvider` before each
/// render call, which is what keeps the renderer itself synchronous and free of I/O.
public struct RenderResources: @unchecked Sendable {
    public var assetTextures: [UUID: MTLTexture]
    /// How to read each texture upright. Absent means identity. Video frames arrive in the
    /// track's natural orientation — a portrait iPhone clip is a landscape buffer with a 90°
    /// `preferredTransform` — and rotating in the shader is cheaper than an extra pass.
    public var sourceTransforms: [UUID: SourceUVTransform]
    public var placeholder: MTLTexture?

    public init(
        assetTextures: [UUID: MTLTexture] = [:],
        sourceTransforms: [UUID: SourceUVTransform] = [:],
        placeholder: MTLTexture? = nil
    ) {
        self.assetTextures = assetTextures
        self.sourceTransforms = sourceTransforms
        self.placeholder = placeholder
    }
}

/// Affine map from upright, normalised source coordinates to the texture's own UV space.
///
/// `uvTexture = (a·u + c·v + tx, b·u + d·v + ty)`. Built once per asset from the track's
/// `preferredTransform`; identity for stills, which ImageIO and PhotoKit already hand over
/// upright.
public struct SourceUVTransform: Sendable, Hashable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = SourceUVTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// The pixel dimensions of the *upright* image, given the texture's natural dimensions.
    /// A 90° transform swaps them.
    public func uprightSize(textureWidth: Int, textureHeight: Int) -> (width: Int, height: Int) {
        let swaps = abs(a) < 0.5 && abs(d) < 0.5
        return swaps ? (textureHeight, textureWidth) : (textureWidth, textureHeight)
    }

    /// From an AVFoundation `preferredTransform` (natural pixel space -> presented pixel space)
    /// and the natural pixel size. Inverts it and normalises both spaces to 0…1.
    public static func fromPreferredTransform(
        a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double,
        naturalWidth: Double, naturalHeight: Double
    ) -> SourceUVTransform {
        guard naturalWidth > 0, naturalHeight > 0 else { return .identity }
        // Presented size is the natural rect pushed through the transform.
        let presentedWidth = abs(a * naturalWidth + c * naturalHeight)
        let presentedHeight = abs(b * naturalWidth + d * naturalHeight)
        guard presentedWidth > 0, presentedHeight > 0 else { return .identity }

        // Invert the 2×2.
        let det = a * d - b * c
        guard abs(det) > 1e-9 else { return .identity }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        // Inverse translation: -T⁻¹ * t. Presented pixel coordinates are (0…presentedWidth),
        // but a rotated transform's tx/ty is what shifts the rotated frame back into view.
        let itx = -(ia * tx + ic * ty)
        let ity = -(ib * tx + id * ty)

        // Compose: uv_presented -> pixel_presented (× presented size) -> pixel_natural (T⁻¹)
        // -> uv_natural (÷ natural size).
        return SourceUVTransform(
            a: ia * presentedWidth / naturalWidth,
            b: ib * presentedWidth / naturalHeight,
            c: ic * presentedHeight / naturalWidth,
            d: id * presentedHeight / naturalHeight,
            tx: itx / naturalWidth,
            ty: ity / naturalHeight
        )
    }
}

/// The GPU half of the render path.
///
/// `@unchecked Sendable` rather than an actor, deliberately: `MTLCommandBuffer` submission
/// ordering is significant, and actor reentrancy would let two renders interleave their
/// encoding. Confinement to `renderQueue` gives the ordering guarantee an actor would not.
public final class MetalRenderer: @unchecked Sendable {

    public let device: MTLDevice
    public let textRasterizer: TextRasterizer

    private let commandQueue: MTLCommandQueue
    private let layerPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let transitionPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let pool: TexturePool
    private let renderQueue = DispatchQueue(label: "app.reframe.renderer")

    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw ReframeError.metalUnavailable
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw ReframeError.renderSetupFailed(detail: "makeCommandQueue returned nil")
        }
        self.commandQueue = queue

        // Shaders.metal lives in the app target, so it compiles into the main bundle's default
        // library. Building it there rather than in the package means Xcode validates the
        // shader at build time instead of us discovering a typo as a black frame.
        guard let library = try? device.makeDefaultLibrary(bundle: .main) else {
            throw ReframeError.renderSetupFailed(
                detail: "default.metallib not found in main bundle — is Shaders.metal in Compile Sources?"
            )
        }

        func pipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            guard let vertexFunction = library.makeFunction(name: vertex),
                  let fragmentFunction = library.makeFunction(name: fragment) else {
                throw ReframeError.renderSetupFailed(detail: "missing shader \(vertex)/\(fragment)")
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            // Premultiplied source-over. Both the layer and overlay fragment shaders
            // premultiply before returning, so this is the matching blend.
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw ReframeError.renderSetupFailed(detail: error.localizedDescription)
            }
        }

        self.layerPipeline = try pipeline(vertex: "layer_vertex", fragment: "layer_fragment")
        self.overlayPipeline = try pipeline(vertex: "layer_vertex", fragment: "overlay_fragment")
        self.transitionPipeline = try pipeline(
            vertex: "fullscreen_vertex", fragment: "transition_fragment"
        )

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        // Slide and push sample off-canvas on purpose; clamping to zero makes the incoming
        // frame arrive from emptiness rather than from a smeared edge pixel.
        samplerDescriptor.sAddressMode = .clampToZero
        samplerDescriptor.tAddressMode = .clampToZero
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw ReframeError.renderSetupFailed(detail: "makeSamplerState returned nil")
        }
        self.sampler = sampler

        self.textRasterizer = TextRasterizer(device: device)
        self.pool = TexturePool(device: device)
    }

    // MARK: - Rendering

    /// Renders one plan into `target`. Synchronous and ordered; callers drive it from a display
    /// link (preview) or an asset-writer pull loop (export).
    public func render(
        plan: RenderPlan,
        resources: RenderResources,
        into target: MTLTexture,
        waitForCompletion: Bool = true
    ) throws {
        try renderQueue.sync {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw ReframeError.renderSetupFailed(detail: "makeCommandBuffer returned nil")
            }

            // Scratch textures borrowed for this frame. Returned to the pool only once the GPU
            // has finished with them: releasing them at the end of encoding, as an earlier
            // version did, let the *next* preview frame reuse a texture the previous frame's
            // transition was still reading -- a flicker that only showed during dissolves.
            var borrowed: [MTLTexture] = []

            switch plan.stage {
            case .single(let layers):
                try encode(
                    layers: layers, plan: plan, resources: resources,
                    into: target, clear: plan.background,
                    commandBuffer: commandBuffer
                )

            case .transition(let stage):
                try encodeTransition(
                    stage, plan: plan, resources: resources,
                    into: target, commandBuffer: commandBuffer, borrowed: &borrowed
                )
            }

            if !plan.overlays.isEmpty {
                try encode(
                    layers: plan.overlays, plan: plan, resources: resources,
                    into: target, clear: nil,
                    commandBuffer: commandBuffer
                )
            }

            if !borrowed.isEmpty {
                let pool = self.pool
                let box = BorrowedTextures(textures: borrowed)
                commandBuffer.addCompletedHandler { _ in
                    for texture in box.textures { pool.release(texture) }
                }
            }

            commandBuffer.commit()
            if waitForCompletion {
                commandBuffer.waitUntilCompleted()
            }
        }
    }

    private func encodeTransition(
        _ stage: RenderPlan.TransitionStage,
        plan: RenderPlan,
        resources: RenderResources,
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        borrowed: inout [MTLTexture]
    ) throws {
        let width = target.width
        let height = target.height

        let fromTexture = try pool.acquire(width: width, height: height)
        let toTexture = try pool.acquire(width: width, height: height)
        borrowed.append(fromTexture)
        borrowed.append(toTexture)

        try encode(
            layers: stage.from, plan: plan, resources: resources,
            into: fromTexture, clear: plan.background, commandBuffer: commandBuffer
        )
        try encode(
            layers: stage.to, plan: plan, resources: resources,
            into: toTexture, clear: plan.background, commandBuffer: commandBuffer
        )

        var sourceA = fromTexture
        var sourceB = toTexture

        // The blur transition pre-filters both scenes with MPS, so the shader stays a plain
        // crossfade. If MPS is unavailable it degrades to dissolve, which is what
        // `TransitionKind.blur`'s fallback expects anyway.
        if stage.kind == .blur, MPSSupportsMTLDevice(device) {
            let radius = Float(sin(stage.progress * .pi) * 24)
            if radius > 0.5 {
                let blur = MPSImageGaussianBlur(device: device, sigma: radius)
                let a = try pool.acquire(width: width, height: height)
                let b = try pool.acquire(width: width, height: height)
                borrowed.append(a)
                borrowed.append(b)
                blur.encode(commandBuffer: commandBuffer, sourceTexture: fromTexture, destinationTexture: a)
                blur.encode(commandBuffer: commandBuffer, sourceTexture: toTexture, destinationTexture: b)
                sourceA = a
                sourceB = b
            }
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(plan.background.x), green: Double(plan.background.y),
            blue: Double(plan.background.z), alpha: Double(plan.background.w)
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw ReframeError.renderSetupFailed(detail: "transition encoder")
        }
        encoder.setRenderPipelineState(transitionPipeline)
        encoder.setFragmentTexture(sourceA, index: 0)
        encoder.setFragmentTexture(sourceB, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)

        var uniforms = TransitionUniforms(
            progress: Float(stage.progress),
            kind: TransitionLibrary.shaderKind(for: stage.kind),
            direction: TransitionLibrary.shaderDirection(for: stage.direction)
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TransitionUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func encode(
        layers: [RenderPlan.PlanLayer],
        plan: RenderPlan,
        resources: RenderResources,
        into target: MTLTexture,
        clear: SIMD4<Float>?,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        if let clear {
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(clear.x), green: Double(clear.y),
                blue: Double(clear.z), alpha: Double(clear.w)
            )
        } else {
            descriptor.colorAttachments[0].loadAction = .load
        }
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw ReframeError.renderSetupFailed(detail: "layer encoder")
        }
        encoder.setFragmentSamplerState(sampler, index: 0)

        for layer in layers {
            switch layer.content {
            case .asset(let id, _):
                let isReal = resources.assetTextures[id] != nil
                guard let texture = resources.assetTextures[id] ?? resources.placeholder else {
                    continue
                }
                var destination = layer.destination
                let sourceTransform = resources.sourceTransforms[id] ?? .identity
                if layer.fitToDestination, isReal {
                    let upright = sourceTransform.uprightSize(
                        textureWidth: texture.width, textureHeight: texture.height
                    )
                    destination = Self.aspectFit(
                        textureWidth: upright.width, textureHeight: upright.height,
                        into: layer.destination, canvas: plan.canvas
                    )
                }
                // Overlays (logos) are already the colour they should be; grading them would
                // tint the user's brand. Everything else takes the graded path.
                let isOverlay = layer.grade.isNeutral && layer.vignette == 0 && layer.grain == 0
                    && layer.destination != .full
                draw(
                    texture: texture, layer: layer, pipeline: isOverlay ? overlayPipeline : layerPipeline,
                    sourceCrop: layer.sourceCrop, destination: destination,
                    opacity: layer.opacity, scale: layer.scale,
                    time: plan.time, canvasAspect: plan.canvas.aspectRatio,
                    sourceTransform: sourceTransform, encoder: encoder
                )

            case .placeholder:
                guard let texture = resources.placeholder else { continue }
                draw(
                    texture: texture, layer: layer, pipeline: layerPipeline,
                    sourceCrop: .full, destination: layer.destination,
                    opacity: layer.opacity, scale: layer.scale, canvasAspect: plan.canvas.aspectRatio, encoder: encoder
                )

            case .text(let draw):
                guard let rasterized = textRasterizer.rasterize(draw, canvas: plan.canvas) else {
                    continue
                }
                let style = draw.style
                let pivot = SIMD2<Double>(rasterized.blockCenter.x, rasterized.blockCenter.y)
                let layerOpacity = layer.opacity * style.opacity
                var rotated = layer
                rotated.rotation = style.rotation
                rotated.rotationPivot = pivot

                // Backgrounds first, faded with the most-visible word on their line so a pill
                // appears with its first word rather than sitting empty ahead of the reveal.
                for background in rasterized.backgrounds {
                    var lineAlpha = 0.0
                    for (index, word) in draw.words.enumerated()
                    where rasterized.lineOfWord[index] == background.index {
                        lineAlpha = max(lineAlpha, word.opacity)
                    }
                    guard lineAlpha > 0.001 else { continue }
                    self.draw(
                        texture: background.texture, layer: rotated, pipeline: overlayPipeline,
                        sourceCrop: .full, destination: background.rect,
                        opacity: lineAlpha * layerOpacity, scale: 1,
                        canvasAspect: plan.canvas.aspectRatio, encoder: encoder
                    )
                }

                // One quad per word. Per-word animation is applied here rather than baked into
                // the texture, which is why the rasteriser cache survives the whole reveal.
                for piece in rasterized.words {
                    guard piece.index < draw.words.count else { continue }
                    let word = draw.words[piece.index]
                    guard word.opacity > 0.001 else { continue }
                    let destination = piece.rect.offset(dx: 0, dy: word.offsetY)
                    self.draw(
                        texture: piece.texture, layer: rotated, pipeline: overlayPipeline,
                        sourceCrop: .full, destination: destination,
                        opacity: word.opacity * layerOpacity, scale: word.scale,
                        canvasAspect: plan.canvas.aspectRatio, encoder: encoder
                    )
                }

            case .solid:
                // Solid fills are expressed as a clear colour on the render pass; there is no
                // case where a mid-pass solid quad is needed, so nothing to encode.
                continue
            }
        }

        encoder.endEncoding()
    }

    private func draw(
        texture: MTLTexture,
        layer: RenderPlan.PlanLayer,
        pipeline: MTLRenderPipelineState,
        sourceCrop: NormalizedRect,
        destination: NormalizedRect,
        opacity: Double,
        scale: Double,
        time: Double = 0,
        canvasAspect: Double = 1,
        sourceTransform: SourceUVTransform = .identity,
        encoder: MTLRenderCommandEncoder
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)

        let pivot = layer.rotationPivot ?? SIMD2<Double>(destination.centerX, destination.centerY)
        var uniforms = LayerUniforms(
            destination: SIMD4<Float>(
                Float(destination.x), Float(destination.y),
                Float(destination.width), Float(destination.height)
            ),
            sourceCrop: SIMD4<Float>(
                Float(sourceCrop.x), Float(sourceCrop.y),
                Float(sourceCrop.width), Float(sourceCrop.height)
            ),
            grade: SIMD4<Float>(
                Float(layer.grade.exposure), Float(layer.grade.contrast),
                Float(layer.grade.saturation), Float(layer.grade.temperature)
            ),
            effects: SIMD4<Float>(
                Float(layer.vignette), Float(layer.grain), Float(time), Float(canvasAspect)
            ),
            sourceTransform: SIMD4<Float>(
                Float(sourceTransform.a), Float(sourceTransform.b),
                Float(sourceTransform.c), Float(sourceTransform.d)
            ),
            pivot: SIMD2<Float>(Float(pivot.x), Float(pivot.y)),
            sourceOffset: SIMD2<Float>(Float(sourceTransform.tx), Float(sourceTransform.ty)),
            opacity: Float(opacity),
            rotation: Float(layer.rotation),
            scale: Float(scale)
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// The largest rect with the texture's aspect ratio that fits inside `destination`, centred.
    /// Aspect is compared in *pixels*: destination is normalised against a non-square canvas.
    static func aspectFit(
        textureWidth: Int, textureHeight: Int, into destination: NormalizedRect, canvas: CanvasSpec
    ) -> NormalizedRect {
        guard textureWidth > 0, textureHeight > 0 else { return destination }
        let destinationPixelWidth = destination.width * Double(canvas.width)
        let destinationPixelHeight = destination.height * Double(canvas.height)
        guard destinationPixelWidth > 0, destinationPixelHeight > 0 else { return destination }
        let textureAspect = Double(textureWidth) / Double(textureHeight)
        let destinationAspect = destinationPixelWidth / destinationPixelHeight

        var width = destination.width
        var height = destination.height
        if textureAspect > destinationAspect {
            height = destination.width * Double(canvas.width) / textureAspect / Double(canvas.height)
        } else {
            width = destination.height * Double(canvas.height) * textureAspect / Double(canvas.width)
        }
        return NormalizedRect(
            x: destination.centerX - width / 2,
            y: destination.centerY - height / 2,
            width: width, height: height
        )
    }

    // MARK: - Memory

    /// Called from the app's memory-pressure hook. Drops everything regenerable.
    public func evictCaches() {
        textRasterizer.evictAll()
        pool.drain()
    }
}

/// Carries scratch textures into a command buffer's completion handler. `MTLTexture` is not
/// `Sendable`; the textures are not touched again until the GPU is done with them, which is
/// exactly when the handler runs.
private struct BorrowedTextures: @unchecked Sendable {
    let textures: [MTLTexture]
}

/// Recycles textures by size so steady-state export allocates nothing.
///
/// Without this, a transition allocates two full-canvas textures per frame — at 1080x1920 that
/// is 16 MB a frame, which the allocator will happily do right up until jetsam intervenes.
final class TexturePool: @unchecked Sendable {
    private let device: MTLDevice
    private var available: [String: [MTLTexture]] = [:]
    private let lock = NSLock()

    init(device: MTLDevice) {
        self.device = device
    }

    func acquire(width: Int, height: Int) throws -> MTLTexture {
        let key = "\(width)x\(height)"

        lock.lock()
        if var bucket = available[key], let texture = bucket.popLast() {
            available[key] = bucket
            lock.unlock()
            return texture
        }
        lock.unlock()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ReframeError.renderSetupFailed(detail: "texture pool exhausted at \(key)")
        }
        return texture
    }

    func release(_ texture: MTLTexture) {
        let key = "\(texture.width)x\(texture.height)"
        lock.lock()
        defer { lock.unlock() }
        var bucket = available[key] ?? []
        // Cap per size class: an unbounded pool is a leak with extra steps.
        guard bucket.count < 6 else { return }
        bucket.append(texture)
        available[key] = bucket
    }

    func drain() {
        lock.lock()
        available.removeAll()
        lock.unlock()
    }
}
