import AVFoundation

struct ChunkAnalysisPoint {
    let time: TimeInterval
    let detection: Detection
}

struct PreparedAudioChunk {
    let url: URL
    let sourceOffset: TimeInterval
    let duration: TimeInterval
    let settings: PulseSettings
    let points: [ChunkAnalysisPoint]
}

// Confined to the decoder queue. Register only a few small PCM resources at a
// time instead of giving Core Haptics the entire decoded song.
final class AudioChunkReader {
    private let file: AVAudioFile
    private let folder: URL
    private var detector = BassDetector()
    private var framePosition: AVAudioFramePosition = 0
    private let onAnalysis: () -> Void
    let formatDescription: String

    init(url: URL, folder: URL, onAnalysis: @escaping () -> Void = {}) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.channelCount <= 2 else { throw PrototypeError.tooManyChannels }
        self.folder = folder
        self.onAnalysis = onAnalysis
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        formatDescription = "Файл: \(file.processingFormat.sampleRate) Гц / \(file.processingFormat.channelCount) кан."
    }

    func next(settings: PulseSettings) throws -> PreparedAudioChunk? {
        guard framePosition < file.length else { return nil }
        let format = file.processingFormat
        // One second for ordinary music. Cap data size for unusual sample rates.
        let maxFrames = min(Int(format.sampleRate), 250000 / max(1, Int(format.channelCount)))
        let count = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), file.length - framePosition))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw PrototypeError.emptyFile }
        try file.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { return nil }
        let offset = Double(framePosition) / format.sampleRate
        framePosition += AVAudioFramePosition(buffer.frameLength)
        var points: [ChunkAnalysisPoint] = []
        var index = 0
        while index < Int(buffer.frameLength) {
            let blockSize = min(1024, Int(buffer.frameLength) - index)
            let result = detector.analyze(frameCount: blockSize, channels: Int(format.channelCount),
                                          sampleRate: format.sampleRate, settings: settings) { channel, sample in
                samples[channel][index + sample]
            }
            points.append(ChunkAnalysisPoint(time: Double(index) / format.sampleRate, detection: result))
            onAnalysis()
            index += blockSize
        }
        let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        do { try write(buffer, url: url) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        return PreparedAudioChunk(url: url, sourceOffset: offset,
                                  duration: Double(buffer.frameLength) / format.sampleRate,
                                  settings: settings, points: points)
    }

    private func write(_ buffer: AVAudioPCMBuffer, url: URL) throws {
        var settings = buffer.format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: url, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try output.write(from: buffer)
    }
}
