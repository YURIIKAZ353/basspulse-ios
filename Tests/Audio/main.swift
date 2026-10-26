import AVFoundation
import Foundation
import Darwin

setbuf(stdout, nil)

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
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: wave, settings: settings)
    try file.write(from: samples)
}
print("Creating WAV fixture")
try makeWave()
print("Creating AAC fixture")
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
convert.arguments = ["-f", "m4af", "-d", "aac", wave.path, m4a.path]
try convert.run()
convert.waitUntilExit()
check(convert.terminationStatus == 0, "AAC fixture generation failed")

for input in [wave, m4a] {
    print("Importing \(input.lastPathComponent)")
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

// Exercise the complete import -> cleanup -> reopen path, not only decoding.
// /var and /private/var can spell the same iOS container differently. A symlink
// alias reproduces this class of identity mismatch on the macOS runner.
let library = root.appendingPathComponent("library with spaces", isDirectory: true)
try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
let alias = root.appendingPathComponent("library-alias")
try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: library.path)
let first = try PCMImporter.decode(wave, directory: library)
let firstFrameCount = try AVAudioFile(forReading: first).length
let enumerated = try FileManager.default.contentsOfDirectory(at: alias, includingPropertiesForKeys: nil)
let sameFileAlias = enumerated.first { $0.lastPathComponent == first.lastPathComponent }!
check(sameFileAlias != first, "Fixture must expose alternate URL spellings")
print("Reproduced: the original URL != cleanup would delete the active PCM through an alias")
try ImportedAudioStore.removePreviousFiles(in: alias, keeping: first)
check(FileManager.default.fileExists(atPath: first.path), "Cleanup must retain selected PCM")
let reopenedFirst = try AVAudioFile(forReading: first)
check(reopenedFirst.length == firstFrameCount, "Selected PCM must reopen after cleanup")
let second = try PCMImporter.decode(m4a, directory: alias)
try ImportedAudioStore.removePreviousFiles(in: alias, keeping: second)
check(FileManager.default.fileExists(atPath: second.path), "Second selected file must survive")
check(!FileManager.default.fileExists(atPath: first.path), "Previous imported PCM should be removed")
let reopenedSecond = try AVAudioFile(forReading: second)
check(reopenedSecond.length > 0, "Reimported AAC PCM must reopen")
print("PASS: import, alias-safe cleanup, reopen, reimport, old-file removal")
