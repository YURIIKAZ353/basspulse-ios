import AVFoundation
import Combine
import UIKit

// Only the render callback owns detector state. Configuration is copied under a
// short lock; audio processing never runs while the UI is holding that lock.
final class AnalysisBridge {
    private let lock = NSLock()
    private var settings = PulseSettings()
    private var detector = BassDetector()
    var diagnostics: RuntimeDiagnostics?

    func configure(_ value: PulseSettings) {
        lock.lock()
        settings = value
        lock.unlock()
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Detection? {
        diagnostics?.increment(0)
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
            combined.updateSettings(settings)
            planned.setEnabled(settings.hapticsEnabled)
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings.v1") }
            // Do not retain haptic commands calculated using older settings.
            settingsRevision += 1
        }
    }
    @Published private(set) var title = "Файл не выбран"
    @Published private(set) var isPlaying = false
    @Published private(set) var isCapturingExternal = false
    @Published private(set) var captureInfo = ""
    @Published var captureAudioOutputOnly = true
    private var captureConfigurationSnapshot = ""
    private var captureSessionSnapshots: [String] = []
    @Published private(set) var isImporting = false
    @Published private(set) var levels: [Double] = [-100, -100]
    @Published private(set) var drive = 0.0
    @Published private(set) var status = "Готов к тесту"
    @Published private(set) var hapticStatus = "Вибрация ещё не запускалась"
    @Published private(set) var route = ""
    @Published private(set) var latencyMS = 0
    @Published private(set) var lastFailure = ""
    @Published private(set) var audioFormatInfo = ""
    @Published private(set) var fileInfo = ""
    @Published private(set) var probeRunning = false
    @Published var probeMode: HapticProbeMode = .sharedSilent
    @Published var playbackMode: PlaybackMode = .systemContinuous
    @Published var supportAudioLevel: Double = 0.03
    @Published var requestBackgroundHaptics = true
    var useCombinedPlayback: Bool { playbackMode == .combined }
    @Published var errorMessage: String?

    private var activeAnalysis: AnalysisBridge?
    private var externalCapture: AudioCaptureSource?
    private let haptics = HapticOutput()
    private let combined = CombinedPlayback()
    private let planned = PlannedTrackPlayback()
    private let diagnostics = RuntimeDiagnostics()
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
        haptics.event = { [weak diagnostics] message in diagnostics?.record(message) }
        haptics.probeState = { [weak self] running in self?.probeRunning = running }
        combined.onStatus = { [weak self] message in self?.status = message }
        combined.onEvent = { [weak diagnostics] message in diagnostics?.record(message) }
        combined.onAnalysis = { [weak diagnostics] in diagnostics?.increment(0) }
        combined.onHapticPattern = { [weak diagnostics] in diagnostics?.increment(2) }
        combined.onFormat = { [weak self] format in self?.audioFormatInfo = format }
        combined.onMeter = { [weak self] value in
            guard let self else { return }
            self.levels = value.bandDB
            self.drive = value.level
            self.diagnostics.increment(1)
        }
        combined.onFinish = { [weak self] in
            self?.stop()
            self?.status = "Воспроизведение завершено"
        }
        combined.onError = { [weak self] error in
            guard let self else { return }
            let failure = self.describe(error, stage: "совместное воспроизведение музыки и вибрации")
            self.stop()
            self.lastFailure = failure
            self.errorMessage = failure
            self.status = "Совместное воспроизведение остановлено из-за ошибки"
        }
        planned.onStatus = { [weak self] message in
            self?.status = message
            if message.hasPrefix("Играет") { self?.hapticStatus = "Core Haptics: весь рисунок запущен заранее" }
        }
        planned.onEvent = { [weak diagnostics] message in diagnostics?.record(message) }
        planned.onFormat = { [weak self] format in self?.audioFormatInfo = format }
        planned.onMeter = { [weak self] value in
            self?.levels = value.bandDB
            self?.drive = value.level
            self?.diagnostics.increment(1)
        }
        planned.onFinish = { [weak self] in self?.stop(); self?.status = "Воспроизведение завершено" }
        planned.onError = { [weak self] error in
            guard let self else { return }
            let failure = self.describe(error, stage: "рисунок на всю песню")
            self.stop()
            self.lastFailure = failure
            self.errorMessage = failure
        }
        let nc = NotificationCenter.default
        for (notification, phase) in [
            (UIApplication.willResignActiveNotification, "inactive"),
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "foreground"),
            (UIApplication.didBecomeActiveNotification, "active")
        ] {
            observers.append(nc.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                self?.diagnostics.transition(phase)
            })
        }
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
        guard !isImporting else { return }
        stop()
        let access = source.startAccessingSecurityScopedResource()
        isImporting = true
        status = "Преобразую файл в PCM. Это может занять некоторое время…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let result = Result { try PCMImporter.decode(source) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isImporting = false
                switch result {
                case .success(let destination):
                    // Protect by filename inside the owned directory; a URL
                    // comparison can differ for two spellings of the same file.
                    let folder = destination.deletingLastPathComponent()
                    try? ImportedAudioStore.removePreviousFiles(in: folder, keeping: destination)
                    self.selectedURL = destination
                    self.title = source.lastPathComponent
                    self.fileInfo = ImportedAudioStore.fileSummary(destination)
                    self.audioFormatInfo = ""
                    self.lastFailure = ""
                    self.status = "Файл преобразован в PCM. Нажми Играть."
                case .failure(let error):
                    self.status = "Не удалось декодировать выбранный файл"
                    self.lastFailure = self.describe(error, stage: "импорт и декодирование файла в PCM")
                    self.errorMessage = self.lastFailure
                }
            }
        }
    }

    func loadDemo() {
        guard !isImporting else { return }
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
        guard !isImporting else { return }
        if playbackMode.usesSystemPulse { settings.mode = "beats" }
        guard let selectedURL else { errorMessage = "Сначала выбери аудиофайл или встроенный тест."; return }
        if playbackMode == .planned { playPlanned(url: selectedURL); return }
        if useCombinedPlayback { playCombined(url: selectedURL); return }
        stop(deactivateSession: false)
        audioFormatInfo = ""
        fileInfo = ImportedAudioStore.fileSummary(selectedURL)
        var stage = "настройка аудиосессии"
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            stage = "активация аудиосессии"
            try session.setActive(true)
            updateRoute()
            stage = "открытие выбранного файла"
            guard FileManager.default.fileExists(atPath: selectedURL.path) else {
                throw PrototypeError.preparedFileMissing
            }
            let file = try AVAudioFile(forReading: selectedURL)
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            stage = "проверка аудиовыхода"
            let output = engine.outputNode
            let hardware = output.outputFormat(forBus: 0)
            audioFormatInfo = "Файл: \(file.processingFormat.sampleRate) Гц / \(file.processingFormat.channelCount) кан.\nВыход: \(hardware.sampleRate) Гц / \(hardware.channelCount) кан."
            guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
                throw PrototypeError.unavailableOutput
            }
            stage = "соединение аудиоузлов"
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            engine.connect(engine.mainMixerNode, to: output, format: hardware)
            let token = UUID()
            generation = token
            let analysis = AnalysisBridge()
            analysis.diagnostics = diagnostics
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
            stage = "подготовка AVAudioEngine"
            engine.prepare()
            stage = "запуск AVAudioEngine"
            try engine.start()
            // A haptic error must not prevent audio playback or the meters.
            do { try prepareLiveHaptics() }
            catch {
                hapticStatus = error.localizedDescription
                diagnostics.record("haptic preparation error: \(error as NSError)")
            }
            isPlaying = true
            lastAnalysis = Date()
            maximumDeliveryTime = 0
            node.play()
            diagnostics.record("audio playback started")
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
            updateRoute()
            let failure = describe(error, stage: stage)
            stop()
            lastFailure = failure
            status = "Ошибка на этапе: \(stage)"
            errorMessage = failure
        }
    }

    func startExternalCapture(useDirectTap: Bool = false) {
        guard !isPlaying, !isImporting else { return }
        guard #available(iOS 27.0, *) else {
            errorMessage = "Для захвата звука других приложений нужна iOS 27 или новее."
            return
        }
        stop(deactivateSession: false)
        playbackMode = .systemContinuous
        lastFailure = ""
        captureConfigurationSnapshot = ""
        captureSessionSnapshots = []
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            recordCaptureSession("before haptics")
            try prepareLiveHaptics()
            restoreCaptureMixing("after haptics")
            updateRoute()
            let token = generation
            let analysis = AnalysisBridge()
            analysis.diagnostics = diagnostics
            analysis.configure(settings)
            activeAnalysis = analysis
            let capture: AudioCaptureSource
            if useDirectTap {
                capture = DirectAudioCapture()
                captureConfigurationSnapshot = "DirectTap system audio; own PID excluded; no SCStream; no entitlement changes"
            } else {
                let screen = SystemAudioCapture()
                screen.audioOutputOnly = captureAudioOutputOnly
                capture = screen
            }
            capture.onEvent = { [weak self, weak diagnostics] message in
                diagnostics?.record(message)
                // Preserve startup metadata outside the rolling event log.
                if message.hasPrefix("Capture configuration:") {
                    self?.captureConfigurationSnapshot = message
                }
            }
            capture.onPCM = { [weak self] buffer, time in
                guard let result = analysis.process(buffer) else { return }
                DispatchQueue.main.async {
                    guard let self, self.generation == token, self.isCapturingExternal else { return }
                    self.receive(result, renderedAt: time, token: token)
                }
            }
            capture.onSignal = { [weak self] message in
                guard let self, self.generation == token else { return }
                self.captureInfo = message
            }
            capture.onStarted = { [weak self] in
                guard let self, self.generation == token else { return }
                self.restoreCaptureMixing("after capture start")
                self.status = useDirectTap ? "Аудиоточка запущена. Проверяем поступление звука." : "Слушаю системный звук. Открой приложение с музыкой или видео."
                self.audioFormatInfo = useDirectTap ? "DirectTap: Float32, стерео; приход PCM подтверждается отдельно" : "Захват других приложений: 48 кГц, стерео; формат буферов проверяется при получении"
            }
            capture.onCancelled = { [weak self] in
                guard let self, self.generation == token else { return }
                self.stop()
                self.status = "Выбор источника отменён"
            }
            capture.onError = { [weak self] error in
                guard let self, self.generation == token else { return }
                let detail = self.describe(error, stage: useDirectTap ? "прямая аудиоточка" : "захват системного звука")
                self.diagnostics.record("System capture stopped/error: \(error as NSError)")
                self.stop()
                self.lastFailure = detail
                self.status = "Захват остановлен: \(error.localizedDescription)"
                self.errorMessage = detail
            }
            externalCapture = capture
            isCapturingExternal = true
            isPlaying = true
            lastAnalysis = .distantPast
            maximumDeliveryTime = 0
            captureInfo = useDirectTap ? "Пробный прямой захват: ждём PCM, без записи экрана" : "Выбери весь экран для перехода между приложениями"
            status = useDirectTap ? "Проверяю доступ к аудиоточке" : "Ожидаю выбор источника в системном окне"
            capture.start()
            guard generation == token, isCapturingExternal else { return }
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, self.generation == token, self.isCapturingExternal else { return }
                if Date().timeIntervalSince(self.lastAnalysis) > 0.5 {
                    // Pauses or capture gaps must not leave a sustained motor level.
                    self.drive = 0
                    self.levels = [-100, -100]
                    self.haptics.apply(level: 0, beat: false, settings: self.settings)
                }
            }
        } catch {
            let detail = describe(error, stage: "подготовка захвата и фоновой вибрации")
            diagnostics.record("Capture preparation error: \(error as NSError)")
            stop()
            lastFailure = detail
            errorMessage = detail
        }
    }

    private func receive(_ result: Detection, renderedAt: TimeInterval, token: UUID) {
        diagnostics.increment(1)
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
            if self.haptics.apply(level: result.level, beat: result.beat, settings: self.settings) {
                self.diagnostics.increment(2)
            }
        }
    }

    func stop(deactivateSession: Bool = true) {
        generation = UUID() // Invalidates completion callbacks and delayed haptics.
        isPlaying = false
        isCapturingExternal = false
        externalCapture?.stop()
        externalCapture = nil
        pending = 0
        watchdog?.invalidate()
        watchdog = nil
        haptics.stop()
        combined.stop()
        planned.stop()
        player?.stop()
        audioEngine?.mainMixerNode.removeTap(onBus: 0)
        audioEngine?.stop()
        player = nil
        audioEngine = nil
        activeAnalysis = nil
        levels = [-100, -100]
        drive = 0
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        status = "Остановлено"
    }

    func testHaptics() {
        guard !isPlaying, !isImporting else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try prepareLiveHaptics()
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
        } catch {
            lastFailure = describe(error, stage: "отдельный тест вибрации")
            errorMessage = lastFailure
        }
    }

    func resetSettings() { settings = PulseSettings() }

    func startBackgroundProbe() {
        guard isPlaying, !probeRunning else { return }
        guard !useCombinedPlayback, playbackMode != .planned else {
            errorMessage = "Отдельные тесты доступны в прежнем режиме. Нажми Стоп и выключи совместное воспроизведение."
            return
        }
        guard settings.intensity > 0 else { errorMessage = "Для теста установи силу выше нуля."; return }
        do {
            try haptics.startProbe(strength: Float(settings.intensity), mode: probeMode)
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.generation == token else { return }
                self.haptics.endProbe()
                self.haptics.stop()
                if self.isPlaying {
                    do { try self.prepareLiveHaptics() }
                    catch { self.hapticStatus = "Возврат к обычной вибрации: \(error.localizedDescription)" }
                }
            }
        } catch {
            diagnostics.record("probe start error: \(error as NSError)")
            errorMessage = describe(error, stage: "запланированный тест фона")
        }
    }

    func diagnosticText() -> String {
        """
        BassPulse 0.1.15 (16)
        iOS: \(UIDevice.current.systemVersion)
        Route: \(route)
        Reported output latency: \(latencyMS) ms (estimate)
        Haptics supported: \(haptics.supported)
        Haptics: \(hapticStatus)
        State: \(status)
        Formats: \(audioFormatInfo)
        File: \(fileInfo)
        Last error: \(lastFailure)
        Selected probe: \(probeMode.rawValue)
        Playback mode: \(playbackMode.rawValue); support audio level: \(supportAudioLevel)
        System Pulse: \(playbackMode.usesSystemPulse); blend=\(playbackMode == .bassBlend); API calls do not prove physical vibration
        Persistent SystemSound category player: \(playbackMode == .systemContinuous); see factory actualCategory and dynamic update events
        Background capability request enabled: \(requestBackgroundHaptics)
        External capture: \(isCapturingExternal); \(captureInfo)
        Capture startup configuration: \(captureConfigurationSnapshot)
        Capture session snapshots:
        \(captureSessionSnapshots.joined(separator: "\n"))
        Playback backend: \(playbackMode == .systemContinuous ? "AVAudioEngine music + SystemSound-category Core Haptics; ONE continuous player + dynamic parameters, no repeated short starts" : playbackMode.usesSystemPulse ? "continuous AVAudioEngine + live DSP + AudioToolbox pulses; no preplanned pattern and no Core Haptics engine" : playbackMode == .planned ? "ONE complete preplanned Core Haptics pattern + continuous AVAudioEngine music; no per-beat players or dynamic parameter updates" : useCombinedPlayback ? "combined audioCustom + frequency patterns; analysis prepared ahead, API counter counts scheduled patterns" : playbackMode == .liveShared ? "continuous AVAudioEngine music + shared Core Haptics audioContinuous + live frequency haptics" : "legacy AVAudioEngine + haptics-only commands")
        Runtime:
        \(diagnostics.report())
        Settings: \((try? String(data: JSONEncoder().encode(settings), encoding: .utf8)) ?? "?")
        """
    }

    private func updateRoute() {
        let session = AVAudioSession.sharedInstance()
        route = session.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        latencyMS = Int(session.outputLatency * 1000)
    }

    private func recordCaptureSession(_ stage: String) {
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let message = "\(stage): category=\(session.category.rawValue) options=\(session.categoryOptions.rawValue) duckOthers=\(session.categoryOptions.contains(.duckOthers)) volume=\(session.outputVolume) rate=\(session.sampleRate) outputs=[\(ports)]"
        captureSessionSnapshots.append(message)
        diagnostics.record("Capture mixing \(message)")
    }

    private func restoreCaptureMixing(_ stage: String) {
        recordCaptureSession("\(stage), before correction")
        let session = AVAudioSession.sharedInstance()
        // Starting the shared SystemSound haptic engine may add duckOthers.
        // Restore the requested mixing policy once at each startup boundary.
        // Do not repeatedly change the session while receiving audio buffers.
        if session.categoryOptions.contains(.duckOthers) {
            do {
                var options = session.categoryOptions
                options.remove(.duckOthers)
                options.insert(.mixWithOthers)
                try session.setCategory(session.category, mode: session.mode, options: options)
            } catch {
                diagnostics.record("Capture mixing correction failed: \(error as NSError)")
            }
        }
        recordCaptureSession("\(stage), after correction")
    }

    private func prepareLiveHaptics() throws {
        if playbackMode == .systemContinuous {
            try haptics.prepareContinuousSystem(requestBackground: requestBackgroundHaptics)
        } else if playbackMode.usesSystemPulse {
            try haptics.prepareSystemPulse(custom: playbackMode != .systemPulse, blend: playbackMode == .bassBlend)
        } else if playbackMode == .liveShared {
            try haptics.prepareReactive(audioLevel: Float(supportAudioLevel))
        } else { try haptics.prepare() }
    }

    private func playCombined(url: URL) {
        stop(deactivateSession: false)
        audioFormatInfo = ""
        lastFailure = ""
        fileInfo = ImportedAudioStore.fileSummary(url)
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { throw PrototypeError.preparedFileMissing }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            updateRoute()
            isPlaying = true
            try combined.start(url: url, settings: settings)
            hapticStatus = "Core Haptics: настоящая музыка + реакция на частоты"
        } catch {
            let failure = describe(error, stage: "запуск совместного воспроизведения")
            stop()
            lastFailure = failure
            errorMessage = failure
        }
    }

    private func playPlanned(url: URL) {
        stop(deactivateSession: false)
        audioFormatInfo = ""
        lastFailure = ""
        fileInfo = ImportedAudioStore.fileSummary(url)
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { throw PrototypeError.preparedFileMissing }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            updateRoute()
            isPlaying = true
            planned.start(url: url, settings: settings, supportLevel: Float(supportAudioLevel))
            hapticStatus = "Подготовка полного рисунка перед воспроизведением"
        } catch {
            let failure = describe(error, stage: "подготовка полного рисунка")
            stop()
            lastFailure = failure
            errorMessage = failure
        }
    }

    private func describe(_ error: Error, stage: String) -> String {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let details = underlying.map { "\nПричина: \($0.domain), \($0.code): \($0.localizedDescription)" } ?? ""
        return """
        Этап: \(stage)
        \(ns.localizedDescription)
        Код: \(ns.code) • \(ns.domain)\(details)
        Выход: \(route.isEmpty ? "не определён" : route)
        \(fileInfo)
        \(audioFormatInfo)
        """
    }
}

