import Foundation

enum PlaybackMode: String, CaseIterable, Identifiable {
    case systemPulse, customPulse, planned, liveShared, liveBasic, combined
    var usesSystemPulse: Bool { self == .systemPulse || self == .customPulse }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .systemPulse: return "Системные удары • стандартные"
        case .customPulse: return "Системные удары • сила и длительность (опыт)"
        case .planned: return "Рисунок на всю песню • новый опыт"
        case .liveShared: return "Непрерывный • опыт 0.1.6"
        case .liveBasic: return "Непрерывный • исходный"
        case .combined: return "Совместный • версия 0.1.5"
        }
    }
}
