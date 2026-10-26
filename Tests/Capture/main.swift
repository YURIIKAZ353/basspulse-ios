import AVFoundation
import CoreMedia

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func sampleBuffer(bytes: Data, format: AVAudioFormat, count: Int) -> CMSampleBuffer {
    var description: CMAudioFormatDescription?
    require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &description) == noErr, "Create audio description")
    var block: CMBlockBuffer?
    require(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr, "Create PCM block")
    bytes.withUnsafeBytes { raw in
        require(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
            dataLength: bytes.count) == noErr, "Populate PCM bytes")
    }
    var sample: CMSampleBuffer?
    require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
        dataBuffer: block!, formatDescription: description!, sampleCount: count,
        presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample) == noErr, "Create PCM sample")
    return sample!
}

let decoder = CapturedPCMDecoder()
for common in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32] {
    let frames = 2048
    let format = AVAudioFormat(commonFormat: common, sampleRate: 48000, channels: 2, interleaved: true)!
    var bytes = Data()
    var expected = [Float]()
    for frame in 0..<frames {
        let value = Float(0.6 * sin(2 * Double.pi * 60 * Double(frame) / 48000))
        expected.append(value)
        for channel in 0..<2 {
            let sample = channel == 0 ? value : -value
            if common == .pcmFormatInt16 {
                var integer = Int16(sample * 32767)
                withUnsafeBytes(of: &integer) { bytes.append(contentsOf: $0) }
            } else {
                var floating = sample
                withUnsafeBytes(of: &floating) { bytes.append(contentsOf: $0) }
            }
        }
    }
    let output = try decoder.decode(sampleBuffer(bytes: bytes, format: format, count: frames))
    require(output.format.commonFormat == .pcmFormatFloat32 && !output.format.isInterleaved, "Normalize for detector")
    require(output.frameLength == frames && output.format.channelCount == 2, "Preserve frame count and stereo")
    for frame in 0..<frames {
        require(abs(output.floatChannelData![0][frame] - expected[frame]) < 0.00006, "Preserve left samples")
        require(abs(output.floatChannelData![1][frame] + expected[frame]) < 0.00006, "Preserve opposite-phase right samples")
    }
}
let silentFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
let silence = try decoder.decode(sampleBuffer(bytes: Data(repeating: 0, count: 512 * 4), format: silentFormat, count: 512))
require(silence.frameLength == 512 && silence.floatChannelData![0][200] == 0, "Silence must remain silence")
print("PASS: captured CoreMedia PCM Int16/Float32, stereo anti-phase, mono silence, frame count, converter format changes")

