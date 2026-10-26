import AVFoundation

struct TrackPoint {
    let time: TimeInterval
    let detection: Detection
}

struct TrackPlan {
    let duration: TimeInterval
    let points: [TrackPoint]
    let settings: PulseSettings
    let formatDescription: String
    var beats: [TrackPoint] { points.filter { $0.detection.beat } }
}

final class TrackPreparationToken {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum TrackPlanner {
    static func prepare(url: URL, settings: PulseSettings, token: TrackPreparationToken,
                        progress: (Double) -> Void = { _ in }) throws -> TrackPlan {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0 else { throw PrototypeError.emptyFile }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else { throw PrototypeError.emptyFile }
        var detector = BassDetector()
        var points: [TrackPoint] = []
        var total: AVAudioFramePosition = 0
        var previousPercent = -1
        while total < file.length {
            if token.isCancelled() { throw CancellationError() }
            let count = AVAudioFrameCount(min(16384, file.length - total))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            var frame = 0
            while frame < Int(buffer.frameLength) {
                let size = min(1024, Int(buffer.frameLength) - frame)
                let result = detector.analyze(frameCount: size, channels: Int(format.channelCount),
                                              sampleRate: format.sampleRate, settings: settings) { channel, index in
                    data[channel][frame + index]
                }
                points.append(TrackPoint(time: Double(total + AVAudioFramePosition(frame)) / format.sampleRate,
                                         detection: result))
                frame += size
            }
            total += AVAudioFramePosition(buffer.frameLength)
            let percent = Int(Double(total) / Double(file.length) * 100)
            if percent != previousPercent { previousPercent = percent; progress(Double(percent) / 100) }
        }
        if token.isCancelled() { throw CancellationError() }
        guard total > 0 else { throw PrototypeError.emptyFile }
        return TrackPlan(duration: Double(total) / format.sampleRate, points: points, settings: settings,
                         formatDescription: "Файл: \(format.sampleRate) Гц / \(format.channelCount) кан.")
    }
}
