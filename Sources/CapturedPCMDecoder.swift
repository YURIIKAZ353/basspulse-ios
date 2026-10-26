import AVFoundation
import CoreMedia

// Owned by the serial capture queue. Preserve all channels, including side bass.
final class CapturedPCMDecoder {
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?

    func decode(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample) else {
            throw failure("Неполный аудиобуфер захвата")
        }
        let count = CMSampleBufferGetNumSamples(sample)
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard count > 0, count <= 192000, format.sampleRate > 0, format.channelCount > 0,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw failure("Неподдерживаемый формат аудиозахвата")
        }
        input.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(count), into: input.mutableAudioBufferList)
        guard status == noErr else { throw failure("Копирование PCM: \(status)") }
        if format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved { return input }
        guard let target = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: input.frameLength) else {
            throw failure("Не удалось подготовить Float32 PCM")
        }
        if converterInput != format {
            converter = AVAudioConverter(from: format, to: target)
            converterInput = format
        }
        guard let converter else { throw failure("Формат захвата не преобразуется в PCM") }
        try converter.convert(to: output, from: input)
        return output
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "BassPulse.CapturePCM", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
