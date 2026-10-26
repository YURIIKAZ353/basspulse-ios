import AudioToolbox
import Foundation
import Darwin

// Main queue only. No Core Haptics engine is created by this backend.
final class SystemPulseOutput {
    private typealias CustomPlay = @convention(c) (UInt32, UnsafeRawPointer?, CFDictionary) -> Void
    private typealias CustomStop = @convention(c) (UInt32) -> Void
    private let custom: Bool
    private var playCustom: CustomPlay?
    private var stopCustom: CustomStop?
    private var library: UnsafeMutableRawPointer?
    private var lastPulse = -Double.infinity
    private var calls = 0
    var event: (String) -> Void = { _ in }

    init(custom: Bool) { self.custom = custom }

    func prepare() throws {
        if custom {
            // Keep the framework loaded for the lifetime of the function pointers.
            let handle = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW)
            guard let handle else { throw unavailable("AudioToolbox не удалось загрузить") }
            library = handle
            guard let play = dlsym(handle, "AudioServicesPlaySystemSoundWithVibration"),
                  let stop = dlsym(handle, "AudioServicesStopSystemSound") else {
                throw unavailable("В этой версии iOS не найден API управляемых импульсов. Выбери стандартные системные удары.")
            }
            playCustom = unsafeBitCast(play, to: CustomPlay.self)
            stopCustom = unsafeBitCast(stop, to: CustomStop.self)
        }
        event("SystemPulse prepared custom=\(custom); no Core Haptics; live onset-driven; API has no physical success feedback")
    }

    func apply(level: Double, beat: Bool, settings: PulseSettings) -> Bool {
        guard settings.hapticsEnabled, beat, level > 0.01 else { return false }
        let strength = min(1, max(0, level * settings.intensity))
        if custom && strength <= 0.01 { return false }
        let now = ProcessInfo.processInfo.systemUptime
        // Standard vibration is long and fixed. Do not flood its service.
        guard now - lastPulse >= (custom ? 0.12 : 0.30) else { return false }
        if custom {
            guard let playCustom else { return false }
            let pattern: NSDictionary = ["Intensity": strength,
                                         "VibePattern": [NSNumber(value: true), NSNumber(value: 35)]]
            playCustom(kSystemSoundID_Vibrate, nil, pattern as CFDictionary)
        } else {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        lastPulse = now
        calls += 1
        if calls == 1 || calls % 20 == 0 {
            event("SystemPulse calls=\(calls) custom=\(custom) requestedIntensity=\(custom ? strength : 1) uptime=\(now)")
        }
        return true
    }

    func stop() {
        if custom && calls > 0 { stopCustom?(kSystemSoundID_Vibrate) }
        calls = 0
        lastPulse = -Double.infinity
    }

    deinit { if let library { dlclose(library) } }

    private func unavailable(_ message: String) -> NSError {
        NSError(domain: "BassPulse.SystemPulse", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
