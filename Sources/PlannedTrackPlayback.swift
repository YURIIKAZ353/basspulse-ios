import AVFoundation
import CoreHaptics
import Darwin
import UIKit

final class PlannedTrackPlayback {
    var onStatus: (String) -> Void = { _ in }
    var onError: (Error) -> Void = { _ in }
    var onFinish: () -> Void = {}
    var onMeter: (Detection) -> Void = { _ in }
    var onFormat: (String) -> Void = { _ in }
    var onEvent: (String) -> Void = { _ in }
    private let worker = DispatchQueue(label: "dev.basspulse.track-plan", qos: .userInitiated)
    private var cancellation: TrackPreparationToken?
    private var generation = UUID()
    private var audio: AVAudioEngine?
    private var music: AVAudioPlayerNode?
    private var haptics: CHHapticEngine?
    private var patternPlayer: CHHapticAdvancedPatternPlayer?
    private var meter: Timer?

    func setEnabled(_ enabled: Bool) { haptics?.isMutedForHaptics = !enabled }

    func start(url: URL, settings: PulseSettings, supportLevel: Float) {
        stop()
        let session = generation
        let token = TrackPreparationToken()
        cancellation = token
        onStatus("Рассчитываю рисунок вибрации для всей песни…")
        worker.async { [weak self] in
            let result = Result {
                try TrackPlanner.prepare(url: url, settings: settings, token: token) { fraction in
                    DispatchQueue.main.async {
                        guard let self, self.generation == session else { return }
                        self.onStatus("Подготовка рисунка: \(Int(fraction * 100)) %")
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == session else { return }
                do {
                    let plan = try result.get()
                    self.onFormat(plan.formatDescription)
                    try self.begin(plan: plan, url: url, supportLevel: supportLevel, session: session)
                } catch { self.fail(error) }
            }
        }
    }

    private func begin(plan: TrackPlan, url: URL, supportLevel: Float, session: UUID) throws {
        guard UIApplication.shared.applicationState == .active else { throw PrototypeError.mustStartInForeground }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { throw PrototypeError.hapticsUnavailable }
        let file = try AVAudioFile(forReading: url)
        let audio = AVAudioEngine()
        let node = AVAudioPlayerNode()
        audio.attach(node)
        audio.connect(node, to: audio.mainMixerNode, format: file.processingFormat)
        let format = audio.outputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw PrototypeError.unavailableOutput }
        audio.connect(audio.mainMixerNode, to: audio.outputNode, format: format)
        self.audio = audio
        music = node
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == session else { return }
                self.onFinish()
            }
        }
        audio.prepare()
        try audio.start()
        let engine = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
        engine.playsHapticsOnly = false
        engine.isAutoShutdownEnabled = false
        engine.isMutedForHaptics = !plan.settings.hapticsEnabled
        engine.stoppedHandler = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, self.generation == session else { return }
                self.onEvent("preplanned engine stopped reason=\(reason.rawValue)")
                self.fail(PrototypeError.combinedStopped(Int(reason.rawValue)))
            }
        }
        engine.resetHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == session else { return }
                self.fail(PrototypeError.combinedStopped(-1))
            }
        }
        haptics = engine
        try engine.start()
        let lead = max(0, AVAudioSession.sharedInstance().outputLatency + plan.settings.delayMS / 1000)
        let pattern = try PlannedPatternBuilder.make(plan: plan, hapticLead: lead, supportLevel: supportLevel)
        let player = try engine.makeAdvancedPlayer(with: pattern)
        player.completionHandler = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.generation == session else { return }
                self.onEvent("whole-track pattern completion: \(error.map { String(describing: $0) } ?? "no error")")
                if let error { self.fail(error) }
            }
        }
        patternPlayer = player
        let engineNow = engine.currentTime
        let hostNow = mach_absolute_time()
        let startupLead = 0.5
        try player.start(atTime: engineNow + startupLead)
        node.play(at: AVAudioTime(hostTime: hostNow + AVAudioTime.hostTime(forSeconds: startupLead)))
        onEvent("whole-track pattern submitted ONCE before background; duration=\(plan.duration)s; beats=\(plan.beats.count); mode=\(plan.settings.mode); audioVolume=\(supportLevel); hapticLead=\(lead)s; no new players or dynamic updates during playback")
        onStatus("Играет заранее рассчитанный рисунок всей песни")
        var pointIndex = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.generation == session,
                  let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render) else { return }
            let seconds = Double(time.sampleTime) / time.sampleRate
            while pointIndex + 1 < plan.points.count && plan.points[pointIndex + 1].time <= seconds { pointIndex += 1 }
            if plan.points.indices.contains(pointIndex) { self.onMeter(plan.points[pointIndex].detection) }
        }
        meter = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func fail(_ error: Error) {
        onEvent("whole-track playback error: \(error as NSError)")
        stop()
        onError(error)
    }

    func stop() {
        generation = UUID()
        cancellation?.cancel()
        cancellation = nil
        meter?.invalidate()
        meter = nil
        try? patternPlayer?.stop(atTime: CHHapticTimeImmediate)
        patternPlayer = nil
        music?.stop()
        audio?.stop()
        music = nil
        audio = nil
        let retiring = haptics
        haptics = nil
        retiring?.stoppedHandler = { _ in }
        retiring?.resetHandler = {}
        retiring?.stop { [retiring] _ in _ = retiring }
    }
}
