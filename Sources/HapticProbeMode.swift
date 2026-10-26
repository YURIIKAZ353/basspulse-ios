import Foundation

enum HapticProbeMode: String, CaseIterable, Identifiable {
    case baseline, sharedAudio, independentAudio, systemSound
    var id: String { rawValue }
    var title: String {
        switch self {
        case .baseline: return "Core Haptics: исходный"
        case .sharedAudio: return "Core Haptics: общая аудиосессия"
        case .independentAudio: return "Core Haptics: своя аудиосессия"
        case .systemSound: return "System Sound: стандартная вибрация"
        }
    }
    var includesTone: Bool { self == .sharedAudio || self == .independentAudio }
}
