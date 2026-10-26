import Foundation
import AVFoundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("build/chunk-tests", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let source = root.appendingPathComponent("source.caf")
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
let length: AVAudioFrameCount = 99225 // 2.25 seconds: exercises a partial tail.
let original = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length)!
original.frameLength = length
for i in 0..<Int(length) {
    let t = Double(i) / 44100
    let value = Float(0.5 * sin(2 * Double.pi * 60 * t))
    original.floatChannelData![0][i] = value
    original.floatChannelData![1][i] = -value
}
func writeSource() throws {
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    let output = try AVAudioFile(forWriting: source, settings: settings)
    try output.write(from: original)
}
try writeSource()
let reader = try AudioChunkReader(url: source, folder: root.appendingPathComponent("chunks"))
var config = PulseSettings()
var total = 0
var chunks = 0
while let chunk = try reader.next(settings: config) {
    require(abs(chunk.sourceOffset - Double(total) / 44100) < 1e-9, "Chunk source offsets must be contiguous")
    require(chunk.duration > 0 && chunk.duration <= 1.001, "Chunk duration must be bounded")
    require(chunk.points.allSatisfy { $0.time >= 0 && $0.time < chunk.duration }, "Analysis times must stay inside chunk")
    if chunks == 0 {
        require(chunk.points.contains { $0.detection.level > 0.5 }, "Bass must drive prepared haptics")
    } else {
        require(chunk.points.allSatisfy { $0.detection.level == 0 }, "Disabled bands must affect next prepared chunk")
    }
    let file = try AVAudioFile(forReading: chunk.url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    for i in 0..<Int(buffer.frameLength) {
        for channel in 0..<2 {
            require(buffer.floatChannelData![channel][i] == original.floatChannelData![channel][total + i],
                    "Chunked audio must preserve samples exactly, with no duplication or gaps")
        }
    }
    total += Int(buffer.frameLength)
    chunks += 1
    config.bands = config.bands.map { FrequencyBand(enabled: false, low: $0.low, high: $0.high) }
}
require(total == Int(length) && chunks == 3, "Must preserve full track and partial last chunk")
let finalChunk = try reader.next(settings: config)
require(finalChunk == nil, "EOF must remain stable")
print("PASS: sample-exact music chunks, stereo anti-phase, contiguous offsets, partial tail, frequency-setting update, stable EOF")
