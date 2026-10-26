import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let old = Data("""
{"bands":[{"enabled":true,"low":40,"high":95},{"enabled":false,"low":100,"high":180}],"intensity":0.42,"thresholdDB":-31,"sharpness":0.2,"delayMS":70,"mode":"continuous","hapticsEnabled":true}
""".utf8)
let migrated = try JSONDecoder().decode(PulseSettings.self, from: old)
require(migrated.intensity == 0.42 && migrated.bands[0].low == 40 && migrated.delayMS == 70,
        "Adding envelope settings must preserve installed user preferences")
require(migrated.bassLayerEnabled && migrated.beatLayerEnabled, "Old settings need both layer defaults")
let decoded = try JSONDecoder().decode(PulseSettings.self, from: JSONEncoder().encode(migrated))
require(decoded == migrated, "Settings must round trip")

var settings = PulseSettings()
settings.intensity = 1
settings.bassLayerGain = 1
settings.beatLayerGain = 1
settings.beatLayerEnabled = false
var bass = BassBlendEnvelope()
var stable = 0.0
for frame in 0..<100 { stable = bass.step(level: 0.8, beat: false, settings: settings, now: Double(frame) * 0.02) }
require(stable > 0.79 && stable <= 0.8, "A sustained note must produce sustained energy without beats")
let tail = bass.step(level: 0, beat: false, settings: settings, now: 2)
require(tail > 0.5 && tail < stable, "Energy must fade, not switch off at the end of a note")
var silence = tail
for frame in 101..<250 { silence = bass.step(level: 0, beat: false, settings: settings, now: Double(frame) * 0.02) }
require(silence < 0.001, "Release must eventually return to silence")

settings.bassLayerEnabled = false
settings.beatLayerEnabled = true
var hits = BassBlendEnvelope()
require(hits.step(level: 1, beat: false, settings: settings, now: 0) == 0,
        "Beats-only must ignore sustained bass without an onset")
let hit = hits.step(level: 1, beat: true, settings: settings, now: 0.02)
require(hit > 0 && hit < 1, "Beat accents must have a rounded attack")
var hitTail = hit
for frame in 2..<50 { hitTail = hits.step(level: 1, beat: false, settings: settings, now: Double(frame) * 0.02) }
require(hitTail < 0.001, "A beat accent must decay even if the bass note continues")

var energyOnly = BassBlendEnvelope()
var beatsOnly = BassBlendEnvelope()
var both = BassBlendEnvelope()
var energySettings = settings
energySettings.bassLayerEnabled = true
energySettings.beatLayerEnabled = false
var bothSettings = energySettings
bothSettings.beatLayerEnabled = true
let energyValue = energyOnly.step(level: 0.4, beat: true, settings: energySettings, now: 0)
let beatsValue = beatsOnly.step(level: 0.4, beat: true, settings: settings, now: 0)
let mixed = both.step(level: 0.4, beat: true, settings: bothSettings, now: 0)
require(abs(mixed - energyValue - beatsValue) < 1e-9, "Both layers must contribute to one mixed intensity")
bothSettings.bassLayerEnabled = false
bothSettings.beatLayerEnabled = false
require(both.step(level: 1, beat: true, settings: bothSettings, now: 0.02) == 0,
        "Both switches off must silence output immediately")
bothSettings.bassLayerEnabled = true
bothSettings.hapticsEnabled = false
require(both.step(level: 1, beat: true, settings: bothSettings, now: 0.04) == 0,
        "Master switch must silence output immediately")

var fast = BassBlendEnvelope()
var slow = BassBlendEnvelope()
var fastSettings = energySettings
var slowSettings = energySettings
fastSettings.riseMS = 10
slowSettings.riseMS = 160
let fastStart = fast.step(level: 0.7, beat: false, settings: fastSettings, now: 0)
let slowStart = slow.step(level: 0.7, beat: false, settings: slowSettings, now: 0)
require(fastStart > slowStart * 3, "Rise control must change the envelope, not only its label")
require(slow.step(level: .nan, beat: true, settings: slowSettings, now: 1).isFinite,
        "Invalid input must not send a NaN intensity")
print("PASS: settings migration, energy sustain/release, rounded accents, independent layer mixing, master mute, rise control")
