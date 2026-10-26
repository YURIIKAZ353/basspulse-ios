import AudioToolbox
import Foundation
import Darwin

// Main queue only. No Core Haptics engine is created by this backend.
final class SystemPulseOutput {
    private typealias CustomPlay = @convention(c) (UInt32, UnsafeRawPointer?, CFDictionary) -> Void
    private typealias CustomStop = @convention(c) (UInt32) -> Void
    private let custom: Bool
    private let blend: Bool
    private var envelope = BassBlendEnvelope()
    private var blendActive = false
    private var playCustom: CustomPlay?
    private var stopCustom: CustomStop?
    private var library: UnsafeMutableRawPointer?
    private var lastPulse = -Double.infinity
    private var calls = 0
    var event: (String) -> Void = { _ in }

    init(custom: Bool, blend: Bool = false) { self.custom = custom; self.blend = blend }

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
        event("SystemPulse prepared custom=\(custom) blend=\(blend); no Core Haptics; API has no physical success feedback")
    }

    func apply(level: Double, beat: Bool, settings: PulseSettings) -> Bool {
        if blend { return applyBlend(level: level, beat: beat, settings: settings) }
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
        envelope.reset()
        blendActive = false
        calls = 0
        lastPulse = -Double.infinity
    }

    deinit { if let library { dlclose(library) } }

    private func applyBlend(level: Double, beat: Bool, settings: PulseSettings) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let strength = envelope.step(level: level, beat: beat, settings: settings, now: now)
        guard strength > 0.015 else {
            if blendActive {
                stopCustom?(kSystemSoundID_Vibrate)
                blendActive = false
                lastPulse = -Double.infinity
            }
            return false
        }
        guard let playCustom, now - lastPulse >= 0.04 else { return false }
        // Bounded overlapping leases approximate a varying envelope through the
        // legacy API. It has no documented intensity-curve facility. Physical
        // smoothness/retrigger behavior must be assessed on the phone.
        let pattern: NSDictionary = ["Intensity": strength,
                                     "VibePattern": [NSNumber(value: true), NSNumber(value: 80)]]
        playCustom(kSystemSoundID_Vibrate, nil, pattern as CFDictionary)
        lastPulse = now
        blendActive = true
        calls += 1
        if calls == 1 || calls % 50 == 0 {
            event("BassBlend calls=\(calls) intensity=\(strength) bass=\(settings.bassLayerEnabled) beats=\(settings.beatLayerEnabled)")
        }
        return true
    }

    private func unavailable(_ message: String) -> NSError {
        NSError(domain: "BassPulse.SystemPulse", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
