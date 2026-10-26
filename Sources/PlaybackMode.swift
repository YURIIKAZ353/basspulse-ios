import Foundation

enum PlaybackMode: String, CaseIterable, Identifiable {
    case planned, liveShared, liveBasic, combined
    var id: String { rawValue }
    var title: String {
        switch self {
        case .planned: return "Рисунок на всю песню • новый опыт"
        case .liveShared: return "Непрерывный • опыт 0.1.6"
        case .liveBasic: return "Непрерывный • исходный"
        case .combined: return "Совместный • версия 0.1.5"
        }
    }
}
