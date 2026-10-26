import SwiftUI
import UniformTypeIdentifiers

@main
struct BassPulseApp: App {
    @StateObject private var audio = AudioController()
    var body: some Scene {
        WindowGroup { ContentView(audio: audio) }
    }
}

struct ContentView: View {
    @ObservedObject var audio: AudioController
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Бас, который можно почувствовать")
                        .font(.headline)
                    Text("Прототип 0.1.1 • свои аудиофайлы. Spotify, YouTube и захват чужого звука пока не подключены.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Источник") {
                    Text(audio.title).lineLimit(2)
                    Button { importing = true } label: { Label("Выбрать аудио из Файлов", systemImage: "folder") }
                        .disabled(audio.isPlaying || audio.isImporting)
                    Button { audio.loadDemo() } label: { Label("Загрузить тест 60 → 140 Гц", systemImage: "waveform") }
                        .disabled(audio.isPlaying || audio.isImporting)
                    HStack {
                        Button {
                            if audio.isPlaying { audio.stop() } else { audio.play() }
                        } label: { Label(audio.isPlaying ? "Стоп" : "Играть", systemImage: audio.isPlaying ? "stop.fill" : "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(audio.isImporting)
                        Spacer()
                        Button("Тест вибрации") { audio.testHaptics() }.disabled(audio.isPlaying || audio.isImporting)
                    }
                    if audio.isImporting { ProgressView("Подготовка аудиофайла…") }
                    Text(audio.status).font(.caption).foregroundStyle(.secondary)
                }
                Section("Частоты реакции") {
                    Text("Звук не фильтруется. Полосы управляют только вибрацией; достаточно сигнала в любой включённой полосе.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(0..<2, id: \.self) { index in
                        bandControls(index)
                    }
                }
                Section("Вибрация") {
                    Toggle("Вибрация под музыку", isOn: $audio.settings.hapticsEnabled)
                    Picker("Режим", selection: $audio.settings.mode) {
                        Text("Удары").tag("beats")
                        Text("Энергия баса").tag("continuous")
                    }.pickerStyle(.segmented)
                    valueSlider("Сила", value: $audio.settings.intensity, range: 0...1, step: 0.01,
                                display: "\(Int(audio.settings.intensity * 100)) %")
                    valueSlider("Порог реакции", value: $audio.settings.thresholdDB, range: -60 ... -5, step: 1,
                                display: "\(Int(audio.settings.thresholdDB)) dBFS")
                    Text("Чем ниже порог, тем тише бас, на который будет реакция. Например, −45 чувствительнее, чем −25.")
                        .font(.caption).foregroundStyle(.secondary)
                    valueSlider("Резкость", value: $audio.settings.sharpness, range: 0...1, step: 0.01,
                                display: "\(Int(audio.settings.sharpness * 100)) %")
                    ProgressView(value: audio.drive).tint(.orange)
                        .accessibilityLabel("Энергия для вибрации")
                }
                Section("Bluetooth и синхронизация") {
                    Text(audio.route.isEmpty ? "Аудиовыход ещё не определён" : audio.route)
                    Text("Задержка выхода по данным iOS: ≈\(audio.latencyMS) мс")
                        .font(.caption).foregroundStyle(.secondary)
                    valueSlider("Поправка вибрации", value: $audio.settings.delayMS, range: -250...500, step: 10,
                                display: "\(Int(audio.settings.delayMS)) мс")
                    Text("Плюс — вибрация позже; минус — раньше относительно оценки iOS. Это ручная калибровка, точная синхронизация не гарантирована.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Диагностика") {
                    Text(audio.hapticStatus).font(.caption)
                    if !audio.audioFormatInfo.isEmpty { Text(audio.audioFormatInfo).font(.caption) }
                    if !audio.lastFailure.isEmpty {
                        Text(audio.lastFailure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Text("Аудио настроено для фонового воспроизведения. Вибрацию в фоне и при блокировке проверяем на твоём iPhone; система может её остановить.")
                        .font(.caption).foregroundStyle(.secondary)
                    ShareLink(item: audio.diagnosticText()) {
                        Label("Поделиться диагностикой", systemImage: "square.and.arrow.up")
                    }
                    Button("Сбросить настройки") { audio.resetSettings() }
                }
            }
            .navigationTitle("BassPulse")
            .tint(.orange)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): audio.importFile(url)
                case .failure(let error): audio.errorMessage = error.localizedDescription
                }
            }
            .alert("BassPulse", isPresented: Binding(get: { audio.errorMessage != nil }, set: { if !$0 { audio.errorMessage = nil } })) {
                Button("Понятно", role: .cancel) { audio.errorMessage = nil }
            } message: { Text(audio.errorMessage ?? "") }
        }
    }

    @ViewBuilder private func bandControls(_ index: Int) -> some View {
        Toggle("Полоса \(index + 1)", isOn: Binding(
            get: { audio.settings.bands[index].enabled },
            set: { audio.settings.bands[index].enabled = $0 }))
        let low = Binding<Double>(get: { audio.settings.bands[index].low }, set: {
            audio.settings.bands[index].low = $0
            if audio.settings.bands[index].high < $0 + 5 { audio.settings.bands[index].high = $0 + 5 }
        })
        let high = Binding<Double>(get: { audio.settings.bands[index].high }, set: {
            audio.settings.bands[index].high = $0
            if audio.settings.bands[index].low > $0 - 5 { audio.settings.bands[index].low = $0 - 5 }
        })
        Group {
            valueSlider("От", value: low, range: 20...995, step: 5,
                        display: "\(Int(audio.settings.bands[index].low)) Гц")
            valueSlider("До", value: high, range: 25...1000, step: 5,
                        display: "\(Int(audio.settings.bands[index].high)) Гц")
        }.disabled(!audio.settings.bands[index].enabled)
        let db = audio.levels.indices.contains(index) ? audio.levels[index] : -100
        HStack {
            ProgressView(value: max(0, min(1, (db + 70) / 70)))
            Text(db < -90 ? "тишина" : "\(Int(db)) dBFS").font(.caption.monospacedDigit()).frame(width: 80)
        }.accessibilityElement(children: .combine)
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                             step: Double, display: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(display).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }
}
