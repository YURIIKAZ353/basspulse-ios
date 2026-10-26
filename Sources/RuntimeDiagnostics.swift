import Foundation

// Records what the process did, never whether the motor physically moved.
// Haptic callbacks can arrive outside the main queue; preserve them immediately.
final class RuntimeDiagnostics {
    private let lock = NSLock()
    private var phase = "active"
    private var counters: [String: [Int]] = [:]
    private var events: [String] = []
    private let started = ProcessInfo.processInfo.systemUptime

    func transition(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        appendLocked("lifecycle \(phase) -> \(name)")
        phase = name
    }

    func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(message)
    }

    // 0 = audio analysis callback, 1 = delivery to main queue,
    // 2 = nonzero haptic command accepted by API (not physical output).
    func increment(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        var values = counters[phase] ?? [0, 0, 0]
        if values.indices.contains(index) { values[index] += 1 }
        counters[phase] = values
    }

    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        let rows = counters.keys.sorted().map { key -> String in
            let values = counters[key]!
            return "\(key): analysis=\(values[0]), mainDelivery=\(values[1]), nonzeroHapticAPI=\(values[2])"
        }
        return (["API success does not confirm physical vibration."] + rows + ["Events:"] + events).joined(separator: "\n")
    }

    private func appendLocked(_ message: String) {
        let seconds = ProcessInfo.processInfo.systemUptime - started
        events.append(String(format: "%.2fs [%@] %@", seconds, phase, message))
        if events.count > 40 { events.removeFirst(events.count - 40) }
    }
}
