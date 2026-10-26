import CoreHaptics
import AVFoundation
import AudioToolbox

// Called on the main queue. No haptic API is called from the audio render thread.
final class HapticOutput {
    private var engine: CHHapticEngine?
    private var continuous: CHHapticAdvancedPatternPlayer?
    private var ready = false
    private var lastMode = ""
    private var probe: CHHapticAdvancedPatternPlayer?
    private var probeToken: UUID?
    private var supportPlayer: CHHapticAdvancedPatternPlayer?
    private var reactiveAudioLevel: Float?
    var status: (String) -> Void = { _ in }
    var event: (String) -> Void = { _ in }
    var probeState: (Bool) -> Void = { _ in }
    var isProbing: Bool { probeToken != nil }
    var supported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    func prepare(profile: HapticProbeMode = .baseline) throws {
        guard supported else { status("Устройство не поддерживает Core Haptics"); return }
        if engine == nil {
            let session: AVAudioSession? = profile == .independentAudio ? nil : AVAudioSession.sharedInstance()
            let created = try CHHapticEngine(audioSession: session)
            created.playsHapticsOnly = !profile.includesTone
            created.isAutoShutdownEnabled = false
            created.stoppedHandler = { [weak self] reason in
                self?.event("engine stopped reason=\(reason.rawValue)")
                DispatchQueue.main.async {
                    self?.ready = false
                    self?.continuous = nil
                    self?.status("Вибрация остановлена системой: \(reason.rawValue). Нажми Стоп → Играть.")
                }
            }
            created.resetHandler = { [weak self] in
                self?.event("engine reset")
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
        event("engine started; profile=\(profile.rawValue), playsHapticsOnly=\(!profile.includesTone)")
        status("Core Haptics готов")
    }

    @discardableResult
    func apply(level: Double, beat: Bool, settings: PulseSettings) -> Bool {
        guard ready, probeToken == nil, let engine else { return false }
        var sent = false
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
                    var events = [event]
                    if let volume = reactiveAudioLevel {
                        events.append(CHHapticEvent(eventType: .audioContinuous, parameters: [
                            CHHapticEventParameter(parameterID: .audioVolume, value: volume),
                            CHHapticEventParameter(parameterID: .audioPitch, value: -1)
                        ], relativeTime: 0, duration: 0.08))
                    }
                    let pattern = try CHHapticPattern(events: events, parameters: [])
                    let player = try engine.makePlayer(with: pattern)
                    try player.start(atTime: CHHapticTimeImmediate)
                    sent = true
                }
            } else {
                if continuous == nil {
                    let duration: TimeInterval = reactiveAudioLevel == nil ? 1 : 30
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(settings.sharpness))
                    ], relativeTime: 0, duration: duration)
                    var events = [event]
                    if let volume = reactiveAudioLevel {
                        events.append(CHHapticEvent(eventType: .audioContinuous, parameters: [
                            CHHapticEventParameter(parameterID: .audioVolume, value: volume),
                            CHHapticEventParameter(parameterID: .audioPitch, value: -1)
                        ], relativeTime: 0, duration: duration))
                    }
                    let pattern = try CHHapticPattern(events: events, parameters: [])
                    let player = try engine.makeAdvancedPlayer(with: pattern)
                    player.loopEnabled = true
                    player.loopEnd = duration
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
                sent = strength > 0.01
            }
            return sent
        } catch {
            event("haptic API error: \(error as NSError)")
            ready = false
            try? continuous?.stop(atTime: CHHapticTimeImmediate)
            continuous = nil
            status("Ошибка вибрации: \(error.localizedDescription). Нажми Стоп → Играть.")
            return false
        }
    }

    func prepareReactive(audioLevel: Float) throws {
        try prepare(profile: audioLevel == 0 ? .sharedSilent : .sharedAudio)
        reactiveAudioLevel = audioLevel
        guard let engine else { throw PrototypeError.hapticsUnavailable }
        let audio = CHHapticEvent(eventType: .audioContinuous, parameters: [
            CHHapticEventParameter(parameterID: .audioVolume, value: audioLevel),
            CHHapticEventParameter(parameterID: .audioPitch, value: -1)
        ], relativeTime: 0, duration: 30)
        let pattern = try CHHapticPattern(events: [audio], parameters: [])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        player.loopEnabled = true
        player.loopEnd = 30
        try player.start(atTime: CHHapticTimeImmediate)
        supportPlayer = player
        event("reactive audioContinuous path started; audioVolume=\(audioLevel); live music stays in AVAudioEngine")
        status(audioLevel == 0 ? "Общая аудиосессия: аудиоэлемент без звука + живая вибрация"
                             : "Общая аудиосессия: тихий тестовый тон + живая вибрация")
    }

    func startProbe(strength: Float, mode: HapticProbeMode) throws {
        stop()
        let token = UUID()
        if mode == .systemSound {
            probeToken = token
            probeState(true)
            event("probe mode=systemSound: 6 calls, 2 seconds apart; fixed system intensity")
            for index in 0..<6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index * 2)) { [weak self] in
                    guard let self, self.probeToken == token else { return }
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    self.event("system vibration call \(index + 1)/6 submitted; no API success feedback")
                }
            }
            return
        }
        try prepare(profile: mode)
        guard let engine, ready else { throw PrototypeError.hapticsUnavailable }
        var events = (0..<12).map { index in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: strength),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            ], relativeTime: Double(index))
        }
        if mode.includesTone {
            // A real, explicitly disclosed sound in this engine tests the
            // combined audio/haptics path. This is not a silent keep-alive.
            events.append(CHHapticEvent(eventType: .audioContinuous, parameters: [
                CHHapticEventParameter(parameterID: .audioVolume, value: mode.audioEventVolume),
                CHHapticEventParameter(parameterID: .audioPitch, value: -1)
            ], relativeTime: 0, duration: 12))
        }
        let pattern = try CHHapticPattern(events: events, parameters: [])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        player.completionHandler = { [weak self] error in
            self?.event("preplanned probe completion: \(error.map { String(describing: $0) } ?? "no error")")
        }
        probe = player
        probeToken = token
        do { try player.start(atTime: CHHapticTimeImmediate) }
        catch { probe = nil; probeToken = nil; throw error }
        probeState(true)
        event("preplanned 12-second probe submitted; mode=\(mode.rawValue); audioEvent=\(mode.includesTone); audioVolume=\(mode.audioEventVolume)")
    }

    func endProbe() {
        probeToken = nil
        try? probe?.stop(atTime: CHHapticTimeImmediate)
        probe = nil
        probeState(false)
        event("preplanned probe released")
    }

    func stop() {
        if probeToken != nil || probe != nil { endProbe() }
        try? continuous?.stop(atTime: CHHapticTimeImmediate)
        continuous = nil
        try? supportPlayer?.stop(atTime: CHHapticTimeImmediate)
        supportPlayer = nil
        reactiveAudioLevel = nil
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
