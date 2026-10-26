import Foundation

// One bounded intensity stream combines the two layers; independent calls to
// the same SystemSoundID would replace each other rather than mix physically.
struct BassBlendEnvelope {
    private var bass = 0.0
    private var accent = 0.0
    private var roundedAccent = 0.0
    private var previousTime: TimeInterval?

    mutating func reset() { self = BassBlendEnvelope() }

    mutating func step(level: Double, beat: Bool, settings: PulseSettings, now: TimeInterval) -> Double {
        guard settings.hapticsEnabled, settings.bassLayerEnabled || settings.beatLayerEnabled else {
            reset()
            return 0
        }
        let dt = min(0.1, max(0, now - (previousTime ?? (now - 0.02))))
        previousTime = now
        let input = level.isFinite ? min(1, max(0, level)) : 0
        let target = settings.bassLayerEnabled ? input : 0
        let rise = min(0.3, max(0.01, settings.riseMS / 1000))
        let fall = min(1, max(0.04, settings.fallMS / 1000))
        bass += (target - bass) * (1 - exp(-dt / (target > bass ? rise : fall)))
        accent *= exp(-dt / 0.09)
        if settings.beatLayerEnabled && beat { accent = max(accent, input) }
        if !settings.beatLayerEnabled { accent = 0; roundedAccent = 0 }
        // Round onset accents instead of adding an instantaneous hard step.
        roundedAccent += (accent - roundedAccent) * (1 - exp(-dt / 0.018))
        let mixed = (settings.bassLayerEnabled ? bass * settings.bassLayerGain : 0)
                  + (settings.beatLayerEnabled ? roundedAccent * settings.beatLayerGain : 0)
        let result = mixed * settings.intensity
        return result.isFinite ? min(1, max(0, result)) : 0
    }
}
