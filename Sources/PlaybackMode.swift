import Foundation

enum PlaybackMode: String, CaseIterable, Identifiable {
    case liveShared, liveBasic, combined
    var id: String { rawValue }
    var title: String {
        switch self {
        case .liveShared: return "Непрерывный • новый фоновый опыт"
        case .liveBasic: return "Непрерывный • исходный"
        case .combined: return "Совместный • версия 0.1.5"
        }
    }
}
