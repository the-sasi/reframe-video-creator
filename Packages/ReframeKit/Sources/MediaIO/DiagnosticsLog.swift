import Foundation
import os

/// An on-device flight recorder.
///
/// Exists because this project is developed on Windows with no Mac and therefore no debugger.
/// Without it, a failure on the phone reports as "it broke" and diagnosis is guesswork. With
/// it, the user taps **Export Log** and sends a text file that says which stage ran, how long
/// it took, what it produced, and where it stopped.
///
/// A lock-guarded class rather than an actor, deliberately: logging must be callable from
/// anywhere — synchronous code, deinit, error paths — without an `await`. A logger you have to
/// suspend to reach is a logger that gets left out of exactly the paths that need it.
public final class DiagnosticsLog: @unchecked Sendable {

    public static let shared = DiagnosticsLog()

    public enum Level: String, Codable, Sendable {
        case info
        case timing
        case warning
        case failure

        var marker: String {
            switch self {
            case .info: return "·"
            case .timing: return "⏱"
            case .warning: return "!"
            case .failure: return "✗"
            }
        }
    }

    public struct Entry: Codable, Sendable {
        public let elapsed: Double
        public let level: Level
        public let category: String
        public let message: String
        public let memoryMB: Double
    }

    private var entries: [Entry] = []
    private let lock = NSLock()
    private let started = Date()
    /// Bounded so a long editing session cannot grow the log without limit. Oldest entries go
    /// first — the tail is what matters when something has just failed.
    private let limit = 3000

    private let logger = Logger(subsystem: PerformanceLog.subsystem, category: "Diagnostics")

    private init() {}

    // MARK: - Recording

    public func record(
        _ level: Level,
        _ category: String,
        _ message: String
    ) {
        let entry = Entry(
            elapsed: Date().timeIntervalSince(started),
            level: level,
            category: category,
            message: message,
            memoryMB: PerformanceLog.memoryFootprintMB()
        )

        lock.lock()
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        lock.unlock()

        // Also to the system log, so `idevicesyslog` over USB shows it live on Windows.
        logger.log("[\(category, privacy: .public)] \(message, privacy: .public)")
    }

    public func info(_ category: String, _ message: String) { record(.info, category, message) }
    public func warning(_ category: String, _ message: String) { record(.warning, category, message) }
    public func failure(_ category: String, _ message: String) { record(.failure, category, message) }

    public func timing(_ category: String, _ message: String, seconds: Double) {
        record(.timing, category, String(format: "%@ — %.2fs", message, seconds))
    }

    // MARK: - Reading

    public func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// The text the user sends. Deliberately plain and self-explanatory — it is read by a person
    /// who was not present when it was produced.
    public func formattedReport() -> String {
        let snapshot = self.snapshot()

        var lines: [String] = []
        lines.append("REFRAME DIAGNOSTIC LOG")
        lines.append(String(repeating: "=", count: 52))
        lines.append("")
        lines.append(DeviceInfo.summary())
        lines.append("")
        lines.append("Entries: \(snapshot.count)   Peak footprint: \(String(format: "%.0f MB", snapshot.map(\.memoryMB).max() ?? 0))")
        lines.append(String(repeating: "-", count: 52))

        for entry in snapshot {
            lines.append(
                String(
                    format: "%7.2fs %@ %-14@ %@   [%.0fMB]",
                    entry.elapsed,
                    entry.level.marker,
                    entry.category,
                    entry.message,
                    entry.memoryMB
                )
            )
        }

        if snapshot.isEmpty {
            lines.append("(nothing recorded — the app has not run anything yet)")
        }

        return lines.joined(separator: "\n")
    }

    /// Writes the report to a temporary file for the share sheet.
    public func writeReport() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reframe-diagnostics.txt")
        try formattedReport().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Device facts worth having at the top of every report.
public enum DeviceInfo {

    public static func summary() -> String {
        var lines: [String] = []
        lines.append("Device:   \(modelIdentifier())")
        lines.append("OS:       \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Memory:   \(ProcessInfo.processInfo.physicalMemory / 1_048_576) MB")
        lines.append("Cores:    \(ProcessInfo.processInfo.processorCount)")
        lines.append("Thermal:  \(thermalDescription())")
        lines.append("Low power: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")")
        return lines.joined(separator: "\n")
    }

    /// e.g. `iPhone16,2`. More useful than a marketing name for narrowing down a hardware-
    /// specific failure — Neural Engine generation and codec support track this, not the name.
    public static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    public static func thermalDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
