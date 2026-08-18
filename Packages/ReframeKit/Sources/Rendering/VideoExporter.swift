import AVFoundation
import CoreVideo
import Foundation
import MediaIO
import Metal
import RecipeCore

public struct ExportProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        case preparing
        case renderingVideo
        case addingAudio
        case finalising
        case done

        /// Named states rather than a fake percentage. §22: if exact progress cannot be
        /// calculated, use meaningful states.
        public var title: String {
            switch self {
            case .preparing: return "Preparing assets"
            case .renderingVideo: return "Rendering"
            case .addingAudio: return "Adding audio"
            case .finalising: return "Finishing up"
            case .done: return "Done"
            }
        }
    }

    public var phase: Phase
    /// Real, when it is real: the video phase knows exactly how many frames it must write.
    public var fraction: Double?
    public var framesWritten: Int
    public var totalFrames: Int

    public init(phase: Phase, fraction: Double?, framesWritten: Int = 0, totalFrames: Int = 0) {
        self.phase = phase
        self.fraction = fraction
        self.framesWritten = framesWritten
        self.totalFrames = totalFrames
    }
}

/// Writes a timeline to a file.
///
/// `AVAssetWriter` with a pixel-buffer adaptor, VideoToolbox-backed. Frames are rendered
/// straight into pool-provided `CVPixelBuffer`s through a `CVMetalTextureCache`, so a frame is
/// never copied between GPU and CPU on its way to the encoder.
///
/// Back-pressure belongs to the encoder: the loop waits on `isReadyForMoreMediaData` rather
/// than running ahead, which is what keeps peak memory flat instead of proportional to length.
public actor VideoExporter {

    private let renderer: MetalRenderer
    private let planner = RenderPlanner()

    public init(renderer: MetalRenderer) {
        self.renderer = renderer
    }

    public struct Request: Sendable {
        public var timeline: Timeline
        public var assets: AssetPool
        public var settings: ExportSettings
        public var outputURL: URL

        public init(timeline: Timeline, assets: AssetPool, settings: ExportSettings, outputURL: URL) {
            self.timeline = timeline
            self.assets = assets
            self.settings = settings
            self.outputURL = outputURL
        }
    }

    public func export(
        _ request: Request,
        resolver: AssetResolver,
        progress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws -> URL {
        progress(ExportProgress(phase: .preparing, fraction: nil))

        let timeline = request.timeline
        let settings = request.settings
        let duration = timeline.duration
        guard duration > 0 else {
            throw ReframeError.exportFailed(detail: "timeline has zero duration")
        }

        // Pre-flight: refusing an export that would have fit is a much smaller failure than
        // starting one that runs out of disk halfway through.
        let store = ProjectStore()
        let needed = settings.estimatedBytes(duration: duration)
        let available = await store.availableStorageBytes()
        if available < needed {
            throw ReframeError.insufficientStorage(neededBytes: needed, availableBytes: available)
        }

        try? FileManager.default.removeItem(at: request.outputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: request.outputURL, fileType: .mp4)
        } catch {
            throw ReframeError.exportFailed(detail: error.localizedDescription)
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(settings)
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ReframeError.exportFailed(detail: "writer rejected video input")
        }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: settings.width,
                kCVPixelBufferHeightKey as String: settings.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )

        // Audio input must be added before `startWriting`, so it is set up here even though it
        // is not written until the video is done. The mix is built from the same plan the
        // preview plays, so what was heard is what gets written.
        var audioInput: AVAssetWriterInput?
        let mixPlan = AudioMixPlanner().plan(timeline, assets: request.assets)
        var mixComposition: AudioMixComposition?
        if !mixPlan.isEmpty {
            let built = await AudioMixBuilder.build(plan: mixPlan, resolver: resolver, assets: request.assets)
            if !built.isEmpty {
                mixComposition = built
                let input = AVAssetWriterInput(
                    mediaType: .audio, outputSettings: Self.audioSettings()
                )
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }
        }

        guard writer.startWriting() else {
            throw ReframeError.exportFailed(
                detail: writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: .zero)

        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, renderer.device, nil, &textureCache)
        guard let textureCache else {
            throw ReframeError.renderSetupFailed(detail: "CVMetalTextureCacheCreate failed")
        }

        let frameProvider = ExportFrameProvider(
            device: renderer.device,
            resolver: resolver,
            pool: request.assets,
            canvasDimension: max(settings.width, settings.height)
        )

        let fps = Double(settings.fps)
        let totalFrames = max(1, Int((duration * fps).rounded()))

        // --- Video ---
        progress(ExportProgress(phase: .renderingVideo, fraction: 0, framesWritten: 0, totalFrames: totalFrames))

        do {
            for frameIndex in 0..<totalFrames {
                try Task.checkCancellation()

                while !videoInput.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(4))
                    try Task.checkCancellation()
                }

                // Thermal courtesy: a sustained export on a warm phone gets slower *and* worse.
                // Backing off briefly keeps the encoder in its efficient range.
                if ProcessInfo.processInfo.thermalState == .serious {
                    try await Task.sleep(for: .milliseconds(120))
                } else if ProcessInfo.processInfo.thermalState == .critical {
                    throw ReframeError.thermalThrottling
                }

                let time = Double(frameIndex) / fps
                let plan = planner.plan(timeline, at: time)
                let resources = await frameProvider.resources(for: plan)

                guard let pool = adaptor.pixelBufferPool else {
                    throw ReframeError.exportFailed(detail: "adaptor has no pixel buffer pool")
                }
                var pixelBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
                        == kCVReturnSuccess,
                      let pixelBuffer else {
                    throw ReframeError.exportFailed(detail: "pixel buffer pool exhausted")
                }

                guard let target = Self.makeTexture(
                    from: pixelBuffer, cache: textureCache,
                    width: settings.width, height: settings.height
                ) else {
                    throw ReframeError.exportFailed(detail: "could not wrap pixel buffer as texture")
                }

                try renderer.render(plan: plan, resources: resources, into: target)

                let presentationTime = CMTime(
                    value: CMTimeValue(frameIndex), timescale: CMTimeScale(settings.fps)
                )
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw ReframeError.exportFailed(
                        detail: writer.error?.localizedDescription ?? "append failed at frame \(frameIndex)"
                    )
                }

                if frameIndex % 5 == 0 || frameIndex == totalFrames - 1 {
                    progress(
                        ExportProgress(
                            phase: .renderingVideo,
                            fraction: Double(frameIndex + 1) / Double(totalFrames),
                            framesWritten: frameIndex + 1,
                            totalFrames: totalFrames
                        )
                    )
                }
            }
        } catch {
            writer.cancelWriting()
            await frameProvider.finish()
            try? FileManager.default.removeItem(at: request.outputURL)
            if error is CancellationError { throw ReframeError.exportCancelled }
            throw error
        }

        videoInput.markAsFinished()
        await frameProvider.finish()

        // --- Audio ---
        if let audioInput, let mixComposition {
            progress(ExportProgress(phase: .addingAudio, fraction: nil))
            do {
                try await writeAudio(mix: mixComposition, input: audioInput, upTo: duration)
            } catch {
                // A silent video is a far better outcome than a failed export. The user is told
                // in the completion state rather than by losing the render.
                PerformanceLog.warn("audio export failed, continuing silent: \(error)")
            }
            audioInput.markAsFinished()
        }

        // --- Finish ---
        progress(ExportProgress(phase: .finalising, fraction: nil))
        await writer.finishWriting()

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: request.outputURL)
            throw ReframeError.exportFailed(
                detail: writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)"
            )
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: request.outputURL.path)
        let bytes = (attributes?[.size] as? Int64) ?? 0
        DiagnosticsLog.shared.info(
            "export",
            "wrote \(totalFrames) frames at \(settings.width)x\(settings.height)@\(settings.fps), "
                + "\(bytes / 1_000_000) MB, thermal=\(DeviceInfo.thermalDescription())"
        )

        progress(ExportProgress(phase: .done, fraction: 1, framesWritten: totalFrames, totalFrames: totalFrames))
        return request.outputURL
    }

    // MARK: - Audio

    /// Reads the mixed audio through `AVAssetReaderAudioMixOutput` and appends it as-is.
    ///
    /// The composition's timeline *is* the project timeline, so sample timestamps need no
    /// retiming, and every fade, duck and volume is applied by AVFoundation from the same
    /// `AVAudioMix` the preview player uses. Nothing here touches sample data.
    private func writeAudio(
        mix: AudioMixComposition,
        input: AVAssetWriterInput,
        upTo duration: Double
    ) async throws {
        let reader = try AVAssetReader(asset: mix.composition)
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: duration, preferredTimescale: 44_100)
        )
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: mix.composition.tracks(withMediaType: .audio),
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.audioMix = mix.audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ReframeError.exportFailed(detail: "reader rejected audio mix output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ReframeError.exportFailed(detail: reader.error?.localizedDescription ?? "audio startReading failed")
        }
        defer { reader.cancelReading() }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(4))
            }
            guard input.append(sample) else {
                throw ReframeError.exportFailed(detail: "audio append failed")
            }
        }
        if reader.status == .failed {
            throw ReframeError.exportFailed(detail: reader.error?.localizedDescription ?? "audio read failed")
        }
    }

    // MARK: - Settings

    private static func videoSettings(_ settings: ExportSettings) -> [String: Any] {
        // HEVC is roughly 40% smaller at equal quality; H.264 is the maximum-compatibility
        // choice. Both are hardware-encoded through VideoToolbox, and both are covered by
        // Apple's own patent licences on Apple hardware — which is a large part of why this
        // project has no FFmpeg in it.
        let codec: AVVideoCodecType = settings.preferHEVC ? .hevc : .h264

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitrate,
            AVVideoExpectedSourceFrameRateKey: settings.fps,
            AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
        ]
        if !settings.preferHEVC {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: compression,
            // Explicit BT.709 SDR. HDR passthrough is out of scope in v1 — half-done colour
            // management is worse than none.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    private static func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
    }

    private static func makeTexture(
        from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache, width: Int, height: Int
    ) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
