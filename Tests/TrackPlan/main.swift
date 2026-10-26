import Foundation
import AVFoundation
import CoreHaptics

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("build/track-plan-fixtures", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let source = root.appendingPathComponent("bursts.caf")
let rate = 44100.0
let duration = 36.0
let hits = [2.0, 5.0, 14.0, 23.0, 35.0]
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * duration))!
buffer.frameLength = buffer.frameCapacity
for frame in 0..<Int(buffer.frameLength) {
    let t = Double(frame) / rate
    let elapsed = hits.map { t - $0 }.first { $0 >= 0 && $0 < 0.15 }
    let x = elapsed.map { Float(0.8 * exp(-$0 * 15) * sin(2 * Double.pi * 60 * t)) } ?? 0
    buffer.floatChannelData![0][frame] = x
    buffer.floatChannelData![1][frame] = -x
}
func write() throws {
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    let file = try AVAudioFile(forWriting: source, settings: settings)
    try file.write(from: buffer)
}
try write()
var settings = PulseSettings()
settings.intensity = 0.8
var progress: [Double] = []
let plan = try TrackPlanner.prepare(url: source, settings: settings, token: TrackPreparationToken()) { progress.append($0) }
check(abs(plan.duration - duration) < 1e-9, "Track duration must be preserved")
check(progress.last == 1, "Preparation must reach 100 percent")
check(zip(plan.points, plan.points.dropFirst()).allSatisfy { $0.0.time < $0.1.time }, "Timeline must be ordered")
for hit in hits {
    check(plan.beats.contains { abs($0.time - hit) < 0.15 }, "Missing prepared bass onset at \(hit)s")
}
check(plan.beats.count <= hits.count * 2, "Too many spurious onsets")
for mode in ["beats", "continuous"] {
    settings.mode = mode
    let configured = TrackPlan(duration: plan.duration, points: plan.points, settings: settings, formatDescription: plan.formatDescription)
    let pattern = try PlannedPatternBuilder.make(plan: configured, hapticLead: 0.28, supportLevel: 0.03)
    check(pattern.duration >= duration, "Complete pattern must cover the full song beyond 12 and 30 seconds")
    print("PASS: complete \(mode) Core Haptics pattern accepted for 36-second song (no physical playback)")
}
settings.bands = settings.bands.map { FrequencyBand(enabled: false, low: $0.low, high: $0.high) }
let disabled = try TrackPlanner.prepare(url: source, settings: settings, token: TrackPreparationToken())
check(disabled.beats.isEmpty && disabled.points.allSatisfy { $0.detection.level == 0 }, "Disabled bands must remove the track response")
let cancelled = TrackPreparationToken()
cancelled.cancel()
do {
    _ = try TrackPlanner.prepare(url: source, settings: settings, token: cancelled)
    fatalError("Cancelled preparation must terminate")
} catch is CancellationError { print("PASS: whole-track preparation cancellation") }
print("PASS: full-song timing, anti-phase bass bursts, settings snapshot, progress, disabled bands")
