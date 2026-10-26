import Foundation

enum PlaybackMode: String, CaseIterable, Identifiable {
    case bassBlend, systemPulse, customPulse, planned, liveShared, liveBasic, combined
    var usesSystemPulse: Bool { self == .bassBlend || self == .systemPulse || self == .customPulse }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bassBlend: return "Бас + удары • плавная огибающая (опыт)"
        case .systemPulse: return "Системные удары • стандартные"
        case .customPulse: return "Системные удары • сила и длительность (опыт)"
        case .planned: return "Рисунок на всю песню • новый опыт"
        case .liveShared: return "Непрерывный • опыт 0.1.6"
        case .liveBasic: return "Непрерывный • исходный"
        case .combined: return "Совместный • версия 0.1.5"
        }
    }
}
