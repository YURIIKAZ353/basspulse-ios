import Foundation

let trace = RuntimeDiagnostics()
trace.transition("background")
DispatchQueue.concurrentPerform(iterations: 2000) { _ in
    trace.increment(0)
    trace.increment(1)
    trace.increment(2)
}
let report = trace.report()
precondition(report.contains("background: analysis=2000, mainDelivery=2000, nonzeroHapticAPI=2000"), "Concurrent counters lost updates")
trace.transition("active")
trace.increment(0)
precondition(trace.report().contains("active: analysis=1, mainDelivery=0, nonzeroHapticAPI=0"), "Foreground counter classification failed")
for i in 0..<100 { trace.record("event-\(i)") }
let bounded = trace.report()
precondition(!bounded.contains("event-0\n"), "Event log must discard old entries")
precondition(bounded.contains("event-99"), "Event log must preserve newest entry")
precondition(bounded.components(separatedBy: "\n").filter { $0.contains("event-") }.count == 40,
             "Event log must be bounded to 40 entries")
print("PASS: concurrent runtime counters, lifecycle classification, bounded event history")
