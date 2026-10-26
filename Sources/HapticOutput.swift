import CoreHaptics
import AVFoundation

// Called on the main queue. No haptic API is called from the audio render thread.
final class HapticOutput {
    private var engine: CHHapticEngine?
    private var continuous: CHHapticAdvancedPatternPlayer?
    private var ready = false
    private var lastMode = ""
    var status: (String) -> Void = { _ in }
    var supported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    func prepare() throws {
        guard supported else { status("Устройство не поддерживает Core Haptics"); return }
        if engine == nil {
            let created = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
            created.playsHapticsOnly = true
            created.isAutoShutdownEnabled = false
            created.stoppedHandler = { [weak self] reason in
                DispatchQueue.main.async {
                    self?.ready = false
                    self?.continuous = nil
                    self?.status("Вибрация остановлена системой: \(reason.rawValue). Нажми Стоп → Играть.")
                }
            }
            created.resetHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.ready = false
                    self?.continuous = nil
                    self?.status("Core Haptics сброшен. Нажми Стоп → Играть.")
                }
            }
            engine = created
        }
        try engine?.start()
        ready = true
        status("Core Haptics готов")
    }

    func apply(level: Double, beat: Bool, settings: PulseSettings) {
        guard ready, let engine else { return }
        do {
            if lastMode != settings.mode {
                try continuous?.stop(atTime: CHHapticTimeImmediate)
                continuous = nil
                lastMode = settings.mode
            }
            let strength = Float(settings.hapticsEnabled ? min(1, max(0, level * settings.intensity)) : 0)
            if settings.mode == "beats" {
                if beat && strength > 0.01 {
                    let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: strength),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(settings.sharpness))
                    ], relativeTime: 0)
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    let player = try engine.makePlayer(with: pattern)
                    try player.start(atTime: CHHapticTimeImmediate)
                }
            } else {
                if continuous == nil {
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(settings.sharpness))
                    ], relativeTime: 0, duration: 1)
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    let player = try engine.makeAdvancedPlayer(with: pattern)
                    player.loopEnabled = true
                    player.loopEnd = 1
                    // Keep the first frame muted until its dynamic level is set.
                    player.isMuted = true
                    try player.start(atTime: CHHapticTimeImmediate)
                    continuous = player
                }
                try continuous?.sendParameters([
                    CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: strength, relativeTime: 0),
                    CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: Float(settings.sharpness) - 0.5, relativeTime: 0)
                ], atTime: CHHapticTimeImmediate)
                continuous?.isMuted = false
            }
        } catch {
            ready = false
            try? continuous?.stop(atTime: CHHapticTimeImmediate)
            continuous = nil
            status("Ошибка вибрации: \(error.localizedDescription). Нажми Стоп → Играть.")
        }
    }

    func stop() {
        try? continuous?.stop(atTime: CHHapticTimeImmediate)
        continuous = nil
        ready = false
        // stop is asynchronous. A subsequent prepare must not restart this same
        // engine while its previous stop is still pending.
        let retiring = engine
        engine = nil
        retiring?.stoppedHandler = { _ in }
        retiring?.resetHandler = {}
        retiring?.stop { [retiring] _ in _ = retiring }
    }
}
