import AVFoundation
import Foundation
import Observation
import ReframeKit

/// Records a voiceover to an M4A in the sandbox.
///
/// `AVAudioRecorder`, deliberately — it handles interruptions, routes and the format for us,
/// and a voiceover is a single mono track where nothing more exotic is needed. Pause/resume,
/// a live level for the meter, and a retake that discards the previous file.
@MainActor
@Observable
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {

    enum State: Equatable {
        case idle
        case recording
        case paused
        case finished(URL, Double)
    }

    private(set) var state: State = .idle
    /// 0…1, for the meter.
    private(set) var level: Double = 0
    private(set) var elapsed: Double = 0

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var relativePath: String?

    var isRecording: Bool { state == .recording }

    /// Requests microphone permission (once), then starts.
    func start() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw ReframeError.microphoneDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.playAndRecord` so the preview can keep playing under the voice being recorded;
            // `.defaultToSpeaker` because otherwise iOS routes playback to the earpiece.
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw ReframeError.recordingFailed(detail: error.localizedDescription)
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let relative = "ImportedMedia/voice-\(UUID().uuidString).m4a"
        let url = documents.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw ReframeError.recordingFailed(detail: "record() returned false") }
            self.recorder = recorder
            self.relativePath = relative
            state = .recording
            elapsed = 0
            startMetering()
            DiagnosticsLog.shared.info("voice", "recording started")
        } catch let error as ReframeError {
            throw error
        } catch {
            throw ReframeError.recordingFailed(detail: error.localizedDescription)
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused, let recorder else { return }
        recorder.record()
        state = .recording
    }

    /// Stops and returns the sandbox-relative path and duration.
    @discardableResult
    func stop() -> (relativePath: String, duration: Double)? {
        guard let recorder, let relativePath else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        meterTask?.cancel()
        state = .finished(recorder.url, duration)
        level = 0
        DiagnosticsLog.shared.info("voice", String(format: "recording stopped, %.1fs", duration))
        // Hand the audio session back to playback so the preview is audible again.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        return (relativePath, duration)
    }

    /// Discards the current file and returns to idle.
    func discard() {
        recorder?.stop()
        recorder?.deleteRecording()
        meterTask?.cancel()
        recorder = nil
        relativePath = nil
        state = .idle
        level = 0
        elapsed = 0
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, let recorder = self.recorder, self.state == .recording else { continue }
                recorder.updateMeters()
                let db = Double(recorder.averagePower(forChannel: 0))
                // -60 dB … 0 dB -> 0 … 1, with a curve that keeps quiet speech visible.
                let normalized = max(0, min(1, (db + 60) / 60))
                self.level = pow(normalized, 1.6)
                self.elapsed = recorder.currentTime
            }
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            DiagnosticsLog.shared.failure("voice", "recorder finished unsuccessfully")
        }
    }
}
