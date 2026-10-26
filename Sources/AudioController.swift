import AVFoundation
import Combine
import UIKit

// Only the render callback owns detector state. Configuration is copied under a
// short lock; audio processing never runs while the UI is holding that lock.
final class AnalysisBridge {
    private let lock = NSLock()
    private var settings = PulseSettings()
    private var detector = BassDetector()

    func configure(_ value: PulseSettings) {
        lock.lock()
        settings = value
        lock.unlock()
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Detection? {
        guard let channels = buffer.floatChannelData, !buffer.format.isInterleaved else { return nil }
        lock.lock()
        let current = settings
        lock.unlock()
        return detector.analyze(frameCount: Int(buffer.frameLength), channels: Int(buffer.format.channelCount),
                                sampleRate: buffer.format.sampleRate, settings: current) { channel, frame in
            channels[channel][frame]
        }
    }
}

final class AudioController: ObservableObject {
    @Published var settings: PulseSettings {
        didSet {
            activeAnalysis?.configure(settings)
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings.v1") }
            // Do not retain haptic commands calculated using older settings.
            settingsRevision += 1
        }
    }
    @Published private(set) var title = "Файл не выбран"
    @Published private(set) var isPlaying = false
    @Published private(set) var levels: [Double] = [-100, -100]
    @Published private(set) var drive = 0.0
    @Published private(set) var status = "Готов к тесту"
    @Published private(set) var hapticStatus = "Вибрация ещё не запускалась"
    @Published private(set) var route = ""
    @Published private(set) var latencyMS = 0
    @Published var errorMessage: String?

    private var activeAnalysis: AnalysisBridge?
    private let haptics = HapticOutput()
    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var selectedURL: URL?
    private var generation = UUID()
    private var settingsRevision = 0
    private var observers: [NSObjectProtocol] = []
    private var pending = 0
    private var watchdog: Timer?
    private var lastAnalysis = Date.distantPast
    private var maximumDeliveryTime = 0.0

    init() {
        let saved = UserDefaults.standard.data(forKey: "settings.v1")
        settings = saved.flatMap { try? JSONDecoder().decode(PulseSettings.self, from: $0) } ?? PulseSettings()
        haptics.status = { [weak self] message in self?.hapticStatus = message }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let kind = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            if kind == AVAudioSession.InterruptionType.began.rawValue {
                self?.stop()
                self?.status = "Аудио прервано системой. Запусти воспроизведение снова."
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.updateRoute()
            // The hardware format can change when a Bluetooth route changes.
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            if self.isPlaying && (reason == .oldDeviceUnavailable || reason == .newDeviceAvailable || reason == .override) {
                self.stop()
                self.status = "Аудиовыход изменился. Нажми Играть для перезапуска."
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
            self?.status = "Аудиосистема сброшена. Нажми Играть."
        })
        updateRoute()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        watchdog?.invalidate()
    }

    func importFile(_ source: URL) {
        stop()
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        do {
            let file = try AVAudioFile(forReading: source)
            guard file.length > 0 else { throw PrototypeError.emptyFile }
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
                .appendingPathComponent("Imported", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            // Keep one private copy; old selected files are no longer needed.
            for old in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where old != destination {
                try? FileManager.default.removeItem(at: old)
            }
            selectedURL = destination
            title = source.lastPathComponent
            status = "Файл загружен. Нажми Играть."
        } catch { errorMessage = "Не удалось открыть аудио: \(error.localizedDescription)" }
    }

    func loadDemo() {
        stop()
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("BassPulse-demo.caf")
            try? FileManager.default.removeItem(at: url)
            let sampleRate = 48000.0
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let count: AVAudioFrameCount = 48000 * 16
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            let data = buffer.floatChannelData![0]
            // Eight seconds of 60 Hz, then eight of 140 Hz. Half-second hits.
            for frame in 0..<Int(count) {
                let time = Double(frame) / sampleRate
                let frequency = time < 8 ? 60.0 : 140.0
                let beatTime = time.truncatingRemainder(dividingBy: 0.5)
                let envelope = min(1, beatTime / 0.008) * exp(-beatTime * 20)
                data[frame] = Float(0.65 * envelope * sin(2 * .pi * frequency * time))
            }
            try file.write(from: buffer)
            selectedURL = url
            title = "Тест: 60 Гц → 140 Гц, 16 секунд"
            status = "Тест загружен. Нажми Играть."
        } catch { errorMessage = error.localizedDescription }
    }

    func play() {
        guard let selectedURL else { errorMessage = "Сначала выбери аудиофайл или встроенный тест."; return }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let file = try AVAudioFile(forReading: selectedURL)
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            let token = UUID()
            generation = token
            let analysis = AnalysisBridge()
            analysis.configure(settings)
            activeAnalysis = analysis
            // The mixer supplies normalized noninterleaved Float32 PCM.
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
                guard let result = analysis.process(buffer) else { return }
                let renderedAt = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async {
                    guard let self, self.generation == token, self.isPlaying else { return }
                    self.receive(result, renderedAt: renderedAt, token: token)
                }
            }
            audioEngine = engine
            player = node
            node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.stop()
                    self.status = "Воспроизведение завершено"
                }
            }
            engine.prepare()
            try engine.start()
            // A haptic error must not prevent audio playback or the meters.
            do { try haptics.prepare() }
            catch { hapticStatus = "Core Haptics: \(error.localizedDescription)" }
            isPlaying = true
            lastAnalysis = Date()
            maximumDeliveryTime = 0
            node.play()
            updateRoute()
            status = "Воспроизведение; фон и блокировку экрана проверяем на устройстве"
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, self.isPlaying else { return }
                if Date().timeIntervalSince(self.lastAnalysis) > 1.5 {
                    self.stop()
                    self.status = "Аудиоданные перестали поступать. Нажми Играть."
                }
            }
        } catch {
            stop()
            errorMessage = "Не удалось запустить: \(error.localizedDescription)"
        }
    }

    private func receive(_ result: Detection, renderedAt: TimeInterval, token: UUID) {
        lastAnalysis = Date()
        levels = result.bandDB
        drive = result.level
        // This is an estimate, not Bluetooth clock synchronization. Keep delivery
        // order monotonic when the manual delay is reduced during playback.
        let now = ProcessInfo.processInfo.systemUptime
        let session = AVAudioSession.sharedInstance()
        let estimated = renderedAt + session.outputLatency + session.ioBufferDuration + settings.delayMS / 1000
        let due = max(now, estimated)
        guard pending < 100 else { return }
        maximumDeliveryTime = max(due, maximumDeliveryTime)
        let delay = min(2, max(0, maximumDeliveryTime - now))
        let revision = settingsRevision
        pending += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == token else { return }
            self.pending = max(0, self.pending - 1)
            guard self.isPlaying, self.settingsRevision == revision else { return }
            self.haptics.apply(level: result.level, beat: result.beat, settings: self.settings)
        }
    }

    func stop() {
        generation = UUID() // Invalidates completion callbacks and delayed haptics.
        isPlaying = false
        pending = 0
        watchdog?.invalidate()
        watchdog = nil
        haptics.stop()
        player?.stop()
        audioEngine?.mainMixerNode.removeTap(onBus: 0)
        audioEngine?.stop()
        player = nil
        audioEngine = nil
        activeAnalysis = nil
        levels = [-100, -100]
        drive = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        status = "Остановлено"
    }

    func testHaptics() {
        guard !isPlaying else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try haptics.prepare()
            var testSettings = settings
            testSettings.mode = "beats"
            testSettings.hapticsEnabled = true
            haptics.apply(level: 1, beat: true, settings: testSettings)
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.generation == token, !self.isPlaying else { return }
                self.haptics.stop()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func resetSettings() { settings = PulseSettings() }

    func diagnosticText() -> String {
        """
        BassPulse 0.1.0
        iOS: \(UIDevice.current.systemVersion)
        Route: \(route)
        Reported output latency: \(latencyMS) ms (estimate)
        Haptics supported: \(haptics.supported)
        Haptics: \(hapticStatus)
        State: \(status)
        Settings: \((try? String(data: JSONEncoder().encode(settings), encoding: .utf8)) ?? "?")
        """
    }

    private func updateRoute() {
        let session = AVAudioSession.sharedInstance()
        route = session.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        latencyMS = Int(session.outputLatency * 1000)
    }
}

enum PrototypeError: LocalizedError {
    case emptyFile
    var errorDescription: String? { "Файл пуст или не содержит доступного аудио." }
}
