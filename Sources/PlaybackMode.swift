import Foundation

enum PlaybackMode: String, CaseIterable, Identifiable {
    case systemContinuous, bassBlend, systemPulse, customPulse, planned, liveShared, liveBasic, combined
    var usesSystemPulse: Bool { self == .bassBlend || self == .systemPulse || self == .customPulse }
    var usesLayerControls: Bool { self == .systemContinuous || self == .bassBlend }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .systemContinuous: return "Непрерывный бас + удары • SystemSound (опыт)"
        case .bassBlend: return "Бас + удары • импульсный опыт 0.1.9"
        case .systemPulse: return "Системные удары • стандартные"
        case .customPulse: return "Системные удары • сила и длительность (опыт)"
        case .planned: return "Рисунок на всю песню • новый опыт"
        case .liveShared: return "Непрерывный • опыт 0.1.6"
        case .liveBasic: return "Непрерывный • исходный"
        case .combined: return "Совместный • версия 0.1.5"
        }
    }
}
