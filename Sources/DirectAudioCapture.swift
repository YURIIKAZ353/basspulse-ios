import AVFoundation

final class DirectAudioCapture: AudioCaptureSource {
    var onPCM: (AVAudioPCMBuffer, TimeInterval) -> Void = { _, _ in }
    var onEvent: (String) -> Void = { _ in }
    var onStarted: () -> Void = {}
    var onCancelled: () -> Void = {}
    var onError: (Error) -> Void = { _ in }
    var onSignal: (String) -> Void = { _ in }
    private let tap = BPDirectAudioTap()
    private var generation = UUID()
    private let sourcePID: Int32
    private var waitingForSource = false

    init(sourcePID: Int32 = 0) { self.sourcePID = sourcePID }

    func start() {
        let token = UUID()
        generation = token
        tap.onPCM = { [weak self] buffer, time in self?.onPCM(buffer, time) }
        tap.onEvent = { [weak self] message in
            self?.onEvent(message)
            if message.hasPrefix("DirectTap PCM") {
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.onSignal(message)
                }
            }
        }
        if sourcePID > 0 { startTap(pid: sourcePID); return }
        waitingForSource = true
        onEvent("DirectTap resolving now-playing application PID")
        BPFindNowPlayingProcess { [weak self] pid in
            guard let self, self.generation == token, self.waitingForSource else { return }
            self.waitingForSource = false
            self.startTap(pid: pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == token, self.waitingForSource else { return }
            self.waitingForSource = false
            self.startTap(pid: 0)
        }
    }

    private func startTap(pid: Int32) {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            onError(NSError(domain: "BassPulse.DirectAudioTap", code: -6,
                            userInfo: [NSLocalizedDescriptionKey: "Не удалось определить приложение с музыкой. В диагностике можно указать PID источника вручную. Очередь не запускалась."]))
            return
        }
        tap.targetProcessID = pid
        tap.useStandardInput = true
        onEvent("DirectTap standard queue and process tap; targetPID=\(pid)")
        do { try tap.start(); onStarted() }
        catch { onError(error) }
    }

    func stop() {
        generation = UUID()
        waitingForSource = false
        tap.stop()
    }
}
