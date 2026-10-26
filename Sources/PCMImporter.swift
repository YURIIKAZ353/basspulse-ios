import AVFoundation

// Decode compressed sources before scheduling playback. AVAudioPlayerNode then
// receives the same Float32 PCM container used by the working built-in demo.
// Chunked I/O bounds RAM use independently of track duration.
enum PCMImporter {
    static func decode(_ source: URL, directory: URL? = nil) throws -> URL {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0 else { throw PrototypeError.emptyFile }
        let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            .appendingPathComponent("Imported", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        do {
            // A nested scope closes/finalizes the output before it is reopened.
            try write(file, to: destination)
            let check = try AVAudioFile(forReading: destination)
            guard check.length > 0 else { throw PrototypeError.emptyFile }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func write(_ source: AVAudioFile, to destination: URL) throws {
        let format = source.processingFormat
        var diskSettings = format.settings
        // PCM files store interleaved samples even though render buffers use
        // separate channel planes. Let AVAudioFile perform this conversion.
        diskSettings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: destination, settings: diskSettings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
            throw PrototypeError.emptyFile
        }
        var total: AVAudioFramePosition = 0
        while source.framePosition < source.length {
            let remaining = source.length - source.framePosition
            let count = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
            try source.read(into: buffer, frameCount: count)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            total += AVAudioFramePosition(buffer.frameLength)
        }
        guard total > 0 else { throw PrototypeError.emptyFile }
    }
}
