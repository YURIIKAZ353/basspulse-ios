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
        do {
            try tap.start()
            onStarted()
        } catch { onError(error) }
    }

    func stop() {
        generation = UUID()
        tap.stop()
    }
}
