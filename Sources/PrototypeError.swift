import Foundation

enum PrototypeError: LocalizedError {
    case emptyFile
    case unavailableOutput
    case preparedFileMissing
    var errorDescription: String? {
        switch self {
        case .emptyFile: return "Файл пуст или не содержит доступного аудио."
        case .unavailableOutput: return "iOS ещё не предоставила аудиовыход. Выбери наушники в Пункте управления и повтори запуск."
        case .preparedFileMissing: return "Подготовленная копия аудио отсутствует. Выбери исходный файл заново."
        }
    }
}
