import Foundation

enum PrototypeError: LocalizedError {
    case emptyFile
    case unavailableOutput
    case preparedFileMissing
    case hapticsUnavailable
    case tooManyChannels
    case combinedStopped(Int)
    var errorDescription: String? {
        switch self {
        case .emptyFile: return "Файл пуст или не содержит доступного аудио."
        case .unavailableOutput: return "iOS ещё не предоставила аудиовыход. Выбери наушники в Пункте управления и повтори запуск."
        case .preparedFileMissing: return "Подготовленная копия аудио отсутствует. Выбери исходный файл заново."
        case .hapticsUnavailable: return "Движок тактильной отдачи не запущен."
        case .tooManyChannels: return "Для совместного воспроизведения пока поддерживаются моно и стерео."
        case .combinedStopped(let reason): return "Совместный движок остановлен системой (причина \(reason)). Нажми Играть для повторного запуска."
        }
    }
}
