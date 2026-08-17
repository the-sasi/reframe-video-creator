import Foundation
import os

/// Instrumentation for the targets in docs/08-quality.md.
///
/// Those targets are unmeasured. This is the apparatus for measuring them: every pipeline stage
/// emits a signpost interval and a peak-footprint sample, so Instruments shows the real numbers
/// and the benchmark scheme can dump a CSV.
public enum PerformanceLog {

    public static let subsystem = "app.reframe.engine"

    private static let signposter = OSSignposter(
        subsystem: subsystem, category: "Pipeline"
    )
    private static let logger = Logger(subsystem: subsystem, category: "Performance")

    public struct Sample: Sendable, Hashable {
        public let stage: String
        public let duration: Double
        public let peakMemoryBytes: UInt64

        public var peakMemoryMB: Double { Double(peakMemoryBytes) / 1_048_576 }
    }

    /// Times a stage and records its peak footprint.
    ///
    /// The `isolation:` parameter defaulting to `#isolation` makes this inherit whatever
    /// isolation the caller has. Without it, `AnalysisPipeline` (an actor) passing a closure
    /// that captures its own state counts as sending a non-Sendable closure across a boundary,
    /// which Swift 6 rejects.
    @discardableResult
    public static func measure<T>(
        _ stage: StaticString,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let state = signposter.beginInterval(stage)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(stage, state)
            let elapsed = ContinuousClock.now - start
            logger.debug(
                "\(String(describing: stage), privacy: .public) took \(elapsed.formatted(), privacy: .public), footprint \(memoryFootprintMB(), format: .fixed(precision: 1)) MB"
            )
        }
        return try await body()
    }

    /// Current resident footprint in bytes.
    ///
    /// `TASK_VM_INFO.phys_footprint` is the number jetsam actually watches — `resident_size`
    /// looks reassuring right up until the app is killed, so it is the wrong thing to log.
    public static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    public static func memoryFootprintMB() -> Double {
        Double(memoryFootprint()) / 1_048_576
    }

    public static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
