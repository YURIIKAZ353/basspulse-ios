import AVFoundation
import CoreHaptics

// Main-queue scheduling and lifecycle; a serial worker decodes and analyzes.
// The real song and its haptics are scheduled in each combined pattern.
final class CombinedPlayback {
    var onStatus: (String) -> Void = { _ in }
    var onError: (Error) -> Void = { _ in }
    var onFinish: () -> Void = {}
    var onMeter: (Detection) -> Void = { _ in }
    var onFormat: (String) -> Void = { _ in }
    var onEvent: (String) -> Void = { _ in }
    var onAnalysis: () -> Void = {}
    var onHapticPattern: () -> Void = {}

    private struct Scheduled {
        let player: CHHapticAdvancedPatternPlayer
        let resource: CHHapticAudioResourceID
        let url: URL
    }
    private let worker = DispatchQueue(label: "dev.basspulse.combined-decoder", qos: .userInitiated)
    private let settingsLock = NSLock()
    private var settings = PulseSettings()
    private var engine: CHHapticEngine?
    private var reader: AudioChunkReader?
    private var folder: URL?
    private var session = UUID()
    private var loading = false
    private var eof = false
    private var started = false
    private var staged: [PreparedAudioChunk] = []
    private var scheduled: [UUID: Scheduled] = [:]
    private var nextTime = 0.0

    func updateSettings(_ value: PulseSettings) {
        settingsLock.lock(); settings = value; settingsLock.unlock()
        engine?.isMutedForHaptics = !value.hapticsEnabled
    }

    func start(url: URL, settings: PulseSettings) throws {
        stop()
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { throw PrototypeError.hapticsUnavailable }
        updateSettings(settings)
        let created = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
        created.playsHapticsOnly = false
        created.isAutoShutdownEnabled = false
        created.isMutedForHaptics = !settings.hapticsEnabled
        let token = session
        created.stoppedHandler = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, self.session == token else { return }
                self.onEvent("combined engine stopped reason=\(reason.rawValue)")
                self.fail(PrototypeError.combinedStopped(Int(reason.rawValue)))
            }
        }
        created.resetHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.session == token else { return }
                self.fail(PrototypeError.combinedStopped(-1))
            }
        }
        try created.start()
        engine = created
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BassPulse-chunks-\(token.uuidString)", isDirectory: true)
        folder = directory
        loading = true
        onStatus("Подготовка совместного воспроизведения…")
        let analysisCallback = onAnalysis
        worker.async { [weak self] in
            let result = Result { try AudioChunkReader(url: url, folder: directory, onAnalysis: analysisCallback) }
            DispatchQueue.main.async {
                guard let self, self.session == token else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                self.loading = false
                switch result {
                case .success(let reader):
                    self.reader = reader
                    self.onFormat(reader.formatDescription)
                    self.onEvent("combined engine started: real music audioCustom + frequency haptics; no test tone")
                    self.pump()
                case .failure(let error): self.fail(error)
                }
            }
        }
    }

    private func pump() {
        guard !loading, !eof, scheduled.count + staged.count < 3, let reader else { return }
        loading = true
        let token = session
        settingsLock.lock(); let config = settings; settingsLock.unlock()
        worker.async { [weak self] in
            let result = Result { try reader.next(settings: config) }
            DispatchQueue.main.async {
                guard let self, self.session == token else {
                    if case .success(let chunk?) = result { try? FileManager.default.removeItem(at: chunk.url) }
                    return
                }
                self.loading = false
                do {
                    switch result {
                    case .success(let chunk?):
                        if !self.started {
                            self.staged.append(chunk)
                            if self.staged.count >= 2 { try self.begin() }
                        } else { try self.schedule(chunk) }
                    case .success(nil):
                        self.eof = true
                        if !self.started && !self.staged.isEmpty { try self.begin() }
                    case .failure(let error): throw error
                    }
                    if self.eof && self.scheduled.isEmpty && self.staged.isEmpty {
                        self.onFinish()
                    } else { self.pump() }
                } catch { self.fail(error) }
            }
        }
    }

    private func begin() throws {
        guard let engine else { throw PrototypeError.hapticsUnavailable }
        started = true
        nextTime = engine.currentTime + 0.35
        let pending = staged
        staged.removeAll()
        for chunk in pending { try schedule(chunk) }
        onStatus("Музыка и вибрация в одном движке • проверяем фон")
    }

    private func schedule(_ chunk: PreparedAudioChunk) throws {
        guard let engine else { throw PrototypeError.hapticsUnavailable }
        let resource: CHHapticAudioResourceID
        do {
            resource = try engine.registerAudioResource(chunk.url, options: [CHHapticAudioResourceKeyUseVolumeEnvelope: false])
        }
        catch { try? FileManager.default.removeItem(at: chunk.url); throw error }
        do {
            let pattern = try CombinedPatternBuilder.make(chunk: chunk, resource: resource)
            let player = try engine.makeAdvancedPlayer(with: pattern)
            let id = UUID(), token = session
            let earliest = engine.currentTime + 0.025
            if nextTime < earliest {
                onEvent(String(format: "combined scheduling underrun %.3fs", earliest - nextTime))
                nextTime = earliest
            }
            let start = nextTime
            nextTime += chunk.duration
            player.completionHandler = { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.session == token else { return }
                    self.release(id)
                    if let error { self.fail(error); return }
                    if self.eof && self.scheduled.isEmpty { self.onFinish() }
                    else { self.pump() }
                }
            }
            scheduled[id] = Scheduled(player: player, resource: resource, url: chunk.url)
            try player.start(atTime: start)
            if chunk.settings.hapticsEnabled && chunk.settings.intensity > 0 && chunk.points.contains(where: { $0.detection.level > 0.01 }) {
                onHapticPattern()
            }
            let untilStart = max(0, start - engine.currentTime)
            let audioLead = max(0, -chunk.settings.delayMS / 1000)
            for point in chunk.points {
                DispatchQueue.main.asyncAfter(deadline: .now() + untilStart + audioLead + point.time) { [weak self] in
                    guard let self, self.session == token else { return }
                    self.onMeter(point.detection)
                }
            }
        } catch {
            try? engine.unregisterAudioResource(resource)
            try? FileManager.default.removeItem(at: chunk.url)
            throw error
        }
    }

    private func release(_ id: UUID) {
        guard let value = scheduled.removeValue(forKey: id) else { return }
        try? engine?.unregisterAudioResource(value.resource)
        try? FileManager.default.removeItem(at: value.url)
    }

    private func fail(_ error: Error) {
        onEvent("combined playback error: \(error as NSError)")
        stop()
        onError(error)
    }

    func stop() {
        session = UUID()
        for value in scheduled.values {
            try? value.player.stop(atTime: CHHapticTimeImmediate)
            try? engine?.unregisterAudioResource(value.resource)
        }
        scheduled.removeAll()
        staged.removeAll()
        let retiring = engine
        engine = nil
        retiring?.stoppedHandler = { _ in }
        retiring?.resetHandler = {}
        retiring?.stop { [retiring] _ in _ = retiring }
        let oldFolder = folder
        folder = nil
        reader = nil
        loading = false
        eof = false
        started = false
        // Runs after any decoder work already using this folder.
        worker.async { if let oldFolder { try? FileManager.default.removeItem(at: oldFolder) } }
    }
}
