import Foundation

struct FrequencyBand: Codable, Equatable {
    var enabled: Bool = true
    var low: Double
    var high: Double
}

struct PulseSettings: Codable, Equatable {
    var bands = [FrequencyBand(low: 35, high: 90), FrequencyBand(low: 90, high: 180)]
    var intensity: Double = 0.65
    var thresholdDB: Double = -38
    var sharpness: Double = 0.25
    var delayMS: Double = 0
    var mode: String = "beats"
    var hapticsEnabled: Bool = true
}

// RBJ Butterworth filters. The selected frequencies describe the audio detector,
// not the mechanical oscillation frequency of the Taptic Engine.
struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0, z2 = 0.0

    init(cutoff: Double, sampleRate: Double, highPass: Bool) {
        let f = min(max(cutoff, 10), sampleRate * 0.45)
        let omega = 2 * Double.pi * f / sampleRate
        let c = cos(omega), alpha = sin(omega) / sqrt(2.0)
        let a0 = 1 + alpha
        if highPass {
            b0 = (1 + c) / (2 * a0)
            b1 = -(1 + c) / a0
            b2 = b0
        } else {
            b0 = (1 - c) / (2 * a0)
            b1 = (1 - c) / a0
            b2 = b0
        }
        a1 = -2 * c / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }
}

struct BandFilter {
    var highPass: Biquad
    var lowPass: Biquad
    init(band: FrequencyBand, sampleRate: Double) {
        highPass = Biquad(cutoff: band.low, sampleRate: sampleRate, highPass: true)
        lowPass = Biquad(cutoff: max(band.high, band.low + 1), sampleRate: sampleRate, highPass: false)
    }
    mutating func process(_ sample: Double) -> Double {
        lowPass.process(highPass.process(sample))
    }
}

struct Detection {
    var bandDB: [Double]
    var level: Double
    var beat: Bool
}

struct BassDetector {
    private var filters: [BandFilter] = []
    private var bands: [FrequencyBand] = []
    private var rate = 0.0
    private var envelope = 0.0
    private var previousLevel = 0.0
    private var lastBeat = -100.0
    private var elapsed = 0.0

    // Mono mixdown can cancel opposite-phase stereo bass. Filter channels
    // separately, then add their energy; both in-phase and side bass survive.
    private var channelCount = 0
    mutating func analyze(frameCount: Int, channels: Int, sampleRate: Double,
                          settings: PulseSettings,
                          sample: (Int, Int) -> Float) -> Detection {
        guard frameCount > 0, channels > 0, sampleRate > 0 else {
            return Detection(bandDB: [-100, -100], level: 0, beat: false)
        }
        if bands != settings.bands || rate != sampleRate || channelCount != channels {
            bands = settings.bands
            rate = sampleRate
            channelCount = channels
            filters = bands.flatMap { band in
                (0..<channels).map { _ in BandFilter(band: band, sampleRate: sampleRate) }
            }
            envelope = 0
            previousLevel = 0
        }
        var energy = Array(repeating: 0.0, count: bands.count)
        for index in 0..<frameCount {
            for channel in 0..<channels {
                let x = Double(sample(channel, index))
                for band in bands.indices where bands[band].enabled {
                    let y = filters[band * channels + channel].process(x)
                    energy[band] += y * y
                }
            }
        }
        let db = energy.map { 10 * log10(max($0 / Double(frameCount * channels), 1e-10)) }
        let maxDB = db.max() ?? -100
        let target = min(1, max(0, (maxDB - settings.thresholdDB) / 24))
        let dt = Double(frameCount) / sampleRate
        let timeConstant = target > envelope ? 0.025 : 0.14
        envelope += (target - envelope) * (1 - exp(-dt / timeConstant))
        elapsed += dt
        let beat = target > 0.12 && target - previousLevel > 0.10 && elapsed - lastBeat > 0.12
        if beat { lastBeat = elapsed }
        // Fast attack / slower decay reference for onset detection.
        previousLevel += (target - previousLevel) * (1 - exp(-dt / 0.08))
        return Detection(bandDB: db, level: envelope, beat: beat)
    }
}
