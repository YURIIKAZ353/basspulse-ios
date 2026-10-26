import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func response(frequency: Double, channels: Int = 1, antiphase: Bool = false,
              enabled: Bool = true, sampleRate: Double = 48000) -> Detection {
    var detector = BassDetector()
    var settings = PulseSettings()
    settings.bands = [FrequencyBand(enabled: enabled, low: 35, high: 90),
                      FrequencyBand(enabled: false, low: 100, high: 180)]
    var result = Detection(bandDB: [], level: 0, beat: false)
    for block in 0..<100 {
        result = detector.analyze(frameCount: 1024, channels: channels, sampleRate: sampleRate,
                                  settings: settings) { channel, frame in
            let t = Double(block * 1024 + frame) / sampleRate
            return Float(0.5 * sin(2 * Double.pi * frequency * t) *
                         (antiphase && channel == 1 ? -1 : 1))
        }
    }
    return result
}

for rate in [44100.0, 48000.0] {
    let bass = response(frequency: 60, sampleRate: rate)
    let treble = response(frequency: 1000, sampleRate: rate)
    require(bass.bandDB[0] > treble.bandDB[0] + 30, "Band must reject 1 kHz by >30 dB relative to 60 Hz")
    require(bass.level > 0.5, "Bass must drive the envelope")
    require(treble.level < 0.01, "Out-of-band tone must not drive haptics")
}
let stereo = response(frequency: 60, channels: 2, antiphase: true)
let mono = response(frequency: 60)
require(abs(stereo.bandDB[0] - mono.bandDB[0]) < 0.01, "Anti-phase bass must survive stereo analysis")
require(response(frequency: 60, enabled: false).level == 0, "Disabled bands must be silent")

var detector = BassDetector()
let settings = PulseSettings()
var beatCount = 0
for block in 0..<200 {
    let hit = (block % 24) < 4
    let result = detector.analyze(frameCount: 1024, channels: 1, sampleRate: 48000,
                                  settings: settings) { _, frame in
        hit ? Float(0.7 * sin(2 * Double.pi * 60 * Double(block * 1024 + frame) / 48000)) : 0
    }
    if result.beat { beatCount += 1 }
    require(result.level.isFinite && (0...1).contains(result.level), "Envelope must remain finite and bounded")
}
require((7...10).contains(beatCount), "Expected one onset per bass burst, got \(beatCount)")
let empty = detector.analyze(frameCount: 0, channels: 0, sampleRate: 0, settings: settings) { _, _ in 0 }
require(empty.level == 0, "Empty input must be safe")
print("PASS: frequency rejection, 44.1/48 kHz, anti-phase stereo, disabled bands, onset bursts, empty input")
