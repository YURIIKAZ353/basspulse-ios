import AVFoundation
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("build/import-tests", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let wave = root.appendingPathComponent("tone.wav")
let m4a = root.appendingPathComponent("tone.m4a")
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
samples.frameLength = 44100
for i in 0..<44100 {
    let tone = Float(0.5 * sin(2 * Double.pi * 60 * Double(i) / 44100))
    samples.floatChannelData![0][i] = tone
    samples.floatChannelData![1][i] = -tone
}
func makeWave() throws {
    let file = try AVAudioFile(forWriting: wave, settings: format.settings)
    try file.write(from: samples)
}
try makeWave()
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
convert.arguments = ["-f", "m4af", "-d", "aac", wave.path, m4a.path]
try convert.run()
convert.waitUntilExit()
check(convert.terminationStatus == 0, "AAC fixture generation failed")

for input in [wave, m4a] {
    let converted = try PCMImporter.decode(input, directory: root)
    let file = try AVAudioFile(forReading: converted)
    check(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
          "Imported file must contain PCM")
    check(file.processingFormat.channelCount == 2, "Stereo channels must survive")
    check(file.processingFormat.sampleRate == 44100, "Sample rate must survive")
    check(abs(file.length - 44100) < 2048, "Duration must survive conversion")
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let data = buffer.floatChannelData!
    let count = Int(buffer.frameLength)
    let energy = (0..<count).reduce(0.0) { $0 + Double(data[0][$1] * data[0][$1]) } / Double(count)
    check(energy > 0.05 && energy < 0.2, "Audio signal must survive conversion")
    print("PASS: \(input.pathExtension) -> PCM CAF, stereo, sample rate, duration, energy")
}

let bad = root.appendingPathComponent("invalid.mp3")
try Data("this is not an audio file".utf8).write(to: bad)
do {
    _ = try PCMImporter.decode(bad, directory: root)
    fatalError("Malformed audio must fail at import")
} catch { print("PASS: malformed audio rejected at import") }
