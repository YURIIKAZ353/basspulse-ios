import AVFoundation
import CoreHaptics

// A single persistent player. Only its dynamic parameters change with music.
// Unlike SystemPulseOutput, apply() never starts or replaces vibration events.
final class ContinuousSystemOutput {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var envelope = BassBlendEnvelope()
    private var updates = 0
    private var ready = false
    var event: (String) -> Void = { _ in }
    var status: (String) -> Void = { _ in }

    func prepare(requestBackground: Bool = true) throws {
        let result = BPCreateSystemCategoryEngine(AVAudioSession.sharedInstance())
        event("ContinuousSystem factory: \(result.detail)")
        guard let engine = result.engine else {
            throw NSError(domain: "BassPulse.SystemCategory", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: result.detail])
        }
        self.engine = engine
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        engine.stoppedHandler = { [weak self] reason in
            DispatchQueue.main.async {
                self?.ready = false
                self?.event("ContinuousSystem stopped reason=\(reason.rawValue); no automatic restart")
                self?.status("Непрерывный проигрыватель остановлен системой: \(reason.rawValue)")
            }
        }
        engine.resetHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.ready = false
                self?.event("ContinuousSystem reset; no automatic restart")
                self?.status("Непрерывный проигрыватель сброшен. Нажми Стоп → Играть.")
            }
        }
        try engine.start()
        if requestBackground {
            let request = BPRequestBackgroundHaptics(engine)
            event(request.detail)
            guard request.engine != nil else {
                throw NSError(domain: "BassPulse.BackgroundGate", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: request.detail])
            }
        } else {
            event("BackgroundGate disabled by user: baseline 0.1.10 behavior")
        }
        let continuous = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
        ], relativeTime: 0, duration: 29)
        let pattern = try CHHapticPattern(events: [continuous], parameters: [])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        player.loopEnabled = true
        player.loopEnd = 29
        player.isMuted = true
        try player.start(atTime: CHHapticTimeImmediate)
        self.player = player
        ready = true
        event("ContinuousSystem player started ONCE; continuous loop=29s; subsequent calls only sendParameters")
        status(requestBackground ? "Запрос AllowBackgroundHaptics отправлен; реальную работу фона проверяем"
                                 : "Непрерывный проигрыватель без фонового запроса • как 0.1.10")
    }

    func apply(level: Double, beat: Bool, settings: PulseSettings) -> Bool {
        guard ready, let player else { return false }
        let strength = envelope.step(level: level, beat: beat, settings: settings,
                                     now: ProcessInfo.processInfo.systemUptime)
        do {
            try player.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(strength), relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,
                                         value: Float(settings.sharpness) - 0.25, relativeTime: 0)
            ], atTime: CHHapticTimeImmediate)
            player.isMuted = false
            updates += 1
            if updates == 1 || updates % 100 == 0 {
                event("ContinuousSystem dynamic updates=\(updates) intensity=\(strength); playerStarts=1")
            }
            return strength > 0.015
        } catch {
            event("ContinuousSystem parameter error: \(error as NSError)")
            status("Ошибка непрерывной вибрации: \(error.localizedDescription)")
            stop()
            return false
        }
    }

    func stop() {
        ready = false
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        envelope.reset()
        updates = 0
        let retiring = engine
        engine = nil
        retiring?.stoppedHandler = { _ in }
        retiring?.resetHandler = {}
        retiring?.stop { [retiring] _ in _ = retiring }
    }
}
