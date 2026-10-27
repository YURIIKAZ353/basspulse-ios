import AVFoundation
import CoreMedia
import ScreenCaptureKit

protocol AudioCaptureSource: AnyObject {
    var onPCM: (AVAudioPCMBuffer, TimeInterval) -> Void { get set }
    var onEvent: (String) -> Void { get set }
    var onStarted: () -> Void { get set }
    var onCancelled: () -> Void { get set }
    var onError: (Error) -> Void { get set }
    var onSignal: (String) -> Void { get set }
    func start()
    func stop()
}

@available(iOS 27.0, *)
final class SystemAudioCapture: NSObject, AudioCaptureSource, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    var onPCM: (AVAudioPCMBuffer, TimeInterval) -> Void = { _, _ in }
    var onEvent: (String) -> Void = { _ in }
    var onStarted: () -> Void = {}
    var onCancelled: () -> Void = {}
    var onError: (Error) -> Void = { _ in }
    var onSignal: (String) -> Void = { _ in }
    var audioOutputOnly = true
    private let queue = DispatchQueue(label: "BassPulse.system-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var accepting = false
    private var audioStreamID: ObjectIdentifier?
    private var stream: SCStream?
    private var token = UUID()
    private let decoder = CapturedPCMDecoder()
    private var buffers = 0
    private var nonSilentBuffers = 0
    private var decodeErrors = 0

    func start() {
        lock.lock(); accepting = true; lock.unlock()
        token = UUID()
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.showsMicrophoneControl = false
        config.showsCameraControl = false
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        onEvent("System capture picker presented; full-display choice needed; no microphone, files or upload")
        picker.present()
    }

    func stop() {
        token = UUID()
        lock.lock(); accepting = false; audioStreamID = nil; lock.unlock()
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        let retiring = stream
        stream = nil
        if let retiring { Task { try? await retiring.stopCapture() } }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in self?.onCancelled() }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError(error) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in self?.begin(filter) }
    }

    private func begin(_ filter: SCContentFilter) {
        lock.lock(); let active = accepting; lock.unlock()
        guard active else { return }
        let attempt = UUID()
        token = attempt
        let previous = stream
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 64
        config.height = 64
        onEvent("Capture configuration: audioOutputOnly=\(audioOutputOnly) pickerMicrophone=\(filter.isMicrophoneEnabled); \(BPCaptureRuntimeDescription(config))")
        logSession("before stream")
        let created = SCStream(filter: filter, configuration: config, delegate: self)
        stream = created
        lock.lock(); audioStreamID = ObjectIdentifier(created); lock.unlock()
        Task { @MainActor [weak self] in
            do {
                if let previous { try? await previous.stopCapture() }
                guard let self, self.token == attempt else { return }
                // Compare an audio-only consumer with the original screen+audio consumer.
                // Whether this changes lock policy must be measured on the device.
                if !self.audioOutputOnly {
                    try created.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                }
                try created.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                try await created.startCapture()
                guard self.token == attempt else { try? await created.stopCapture(); return }
                self.onEvent("System capture started: audio=48kHz/stereo; pickerMicrophone=\(filter.isMicrophoneEnabled); audioOutputOnly=\(self.audioOutputOnly)")
                self.logSession("after stream start")
                self.onStarted()
            } catch {
                guard let self, self.token == attempt else { return }
                self.onError(error)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.logSession("stream stopped")
            self.onError(error)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        lock.lock(); let active = accepting && audioStreamID == ObjectIdentifier(stream); lock.unlock()
        guard active, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        do {
            let pcm = try decoder.decode(sampleBuffer)
            buffers += 1
            var peak: Float = 0
            var energy = 0.0
            if let data = pcm.floatChannelData {
                for channel in 0..<Int(pcm.format.channelCount) {
                    for frame in 0..<Int(pcm.frameLength) {
                        let sample = data[channel][frame]
                        peak = max(peak, abs(sample))
                        energy += Double(sample * sample)
                    }
                }
            }
            if peak > 0.00001 { nonSilentBuffers += 1 }
            let now = ProcessInfo.processInfo.systemUptime
            var renderedAt = now
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isValid, let clock = stream.synchronizationClock {
                let hostTime = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
                let seconds = CMTimeGetSeconds(hostTime)
                if seconds.isFinite && abs(seconds - now) < 10 { renderedAt = seconds }
            }
            if buffers == 1 || buffers % 100 == 0 {
                if buffers == 1 || buffers % 1000 == 0 { logSession("buffer \(buffers)") }
                let rms = sqrt(energy / max(1, Double(pcm.frameLength) * Double(pcm.format.channelCount)))
                let db = 20 * log10(max(rms, 1e-8))
                onEvent("Capture buffers=\(buffers) nonSilent=\(nonSilentBuffers) peak=\(peak) rmsDB=\(db) timestampAgeMS=\((now-renderedAt)*1000)")
                let message = peak > 0.00001 ? "Сигнал захвата: \(Int(db)) dBFS" : "В захвате тишина — включи контент или выбери другой источник"
                DispatchQueue.main.async { [weak self] in self?.onSignal(message) }
            }
            onPCM(pcm, renderedAt)
        } catch {
            decodeErrors += 1
            if decodeErrors == 1 || decodeErrors % 100 == 0 {
                onEvent("Capture PCM decode errors=\(decodeErrors): \(error as NSError)")
            }
        }
    }

    private func logSession(_ stage: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        onEvent("Capture session \(stage): category=\(session.category.rawValue) mode=\(session.mode.rawValue) options=\(session.categoryOptions.rawValue) rate=\(session.sampleRate) volume=\(session.outputVolume) outputs=[\(outputs)] inputs=[\(inputs)] latency=\(session.outputLatency)")
    }
}
