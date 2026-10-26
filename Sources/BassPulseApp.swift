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
                    Text("Прототип 0.1.12 • свои файлы и захват звука других приложений через системный выбор источника.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Источник") {
                    Picker("Воспроизведение", selection: $audio.playbackMode) {
                        ForEach(PlaybackMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.disabled(audio.isPlaying || audio.isImporting)
                    Text(audio.playbackMode == .systemContinuous
                         ? "Один непрерывный проигрыватель с изменяемой силой и резкостью. Новый опыт передаёт серверу отдельный запрос фоновой вибрации; приём запроса и реальную отдачу проверяем отдельно."
                         : audio.playbackMode == .bassBlend
                         ? "Предыдущий импульсный опыт 0.1.9. На устройстве ощущается стуками, плавность не подтверждена. Оставлен для сравнения."
                         : audio.playbackMode.usesSystemPulse
                         ? "Живые удары по выбранным частотам, без расчёта песни заранее. Стандартные: фиксированная системная вибрация. Сила и длительность: экспериментальные короткие импульсы 35 мс."
                         : audio.playbackMode == .planned
                         ? "Весь рисунок рассчитывается и запускается до сворачивания приложения. Музыка идёт непрерывно. Настройки выбирай до Играть; для изменения нажми Стоп."
                         : audio.useCombinedPlayback
                         ? "Предыдущий опыт с секундными участками музыки. Оставлен для сравнения."
                         : "Музыка проигрывается непрерывно, без нарезки. Настройки частот и силы применяются сразу. Фоновую вибрацию нового варианта ещё проверяем.")
                        .font(.caption).foregroundStyle(.secondary)
                    if audio.playbackMode == .systemContinuous {
                        Toggle("Запрос фоновой вибрации • опыт", isOn: $audio.requestBackgroundHaptics)
                            .disabled(audio.isPlaying || audio.isImporting)
                        Text("Выключенный запрос возвращает поведение 0.1.10. Для сравнения нажми Стоп, переключи и запусти снова.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if audio.playbackMode == .liveShared || audio.playbackMode == .planned {
                        Picker("Аудиоэлемент для проверки фона", selection: $audio.supportAudioLevel) {
                            Text("Нулевая громкость").tag(0.0)
                            Text("Минимальная громкость").tag(0.00001)
                            Text("Тестовый тон").tag(0.03)
                        }.disabled(audio.isPlaying || audio.isImporting)
                        Text(audio.supportAudioLevel == 0
                             ? "Синтезированный аудиоэлемент имеет нулевую громкость. Проверяем, сохранит ли он фоновую вибрацию без слышимого тона."
                             : audio.supportAudioLevel < 0.001
                             ? "Очень низкая громкость аудиоэлемента. Проверяем отдельно его влияние на фон и слышимость в наушниках."
                             : "Добавлен тихий синтезированный тон, как в успешном фоновом тесте. Это диагностический вариант.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { audio.startExternalCapture() } label: {
                        Label("Звук других приложений", systemImage: "apps.iphone")
                    }.disabled(audio.isPlaying || audio.isImporting)
                    Text("В системном окне выбери весь экран, затем включи музыку или видео в другом приложении. Микрофон не используется; запись в файл не создаётся. Доступность звука конкретного приложения и работа при блокировке проверяются отдельно.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !audio.captureInfo.isEmpty { Text(audio.captureInfo).font(.caption) }
                    Text(audio.isCapturingExternal ? "Источник: системный аудиозахват" : audio.title).lineLimit(2)
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
                    }.disabled(audio.isPlaying && audio.playbackMode == .planned)
                }
                Section("Вибрация") {
                    Toggle("Вибрация под музыку", isOn: $audio.settings.hapticsEnabled)
                    if audio.playbackMode.usesLayerControls {
                        blendControls
                    } else {
                        Picker("Режим", selection: $audio.settings.mode) {
                            Text("Удары").tag("beats")
                            Text("Энергия баса").tag("continuous")
                        }.pickerStyle(.segmented).disabled(audio.playbackMode.usesSystemPulse || (audio.isPlaying && audio.playbackMode == .planned))
                        if audio.playbackMode.usesSystemPulse {
                            Text("В этих двух системных режимах используются только удары. Для энергии баса с акцентами выбери «Бас + удары» после Стоп.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if audio.playbackMode == .systemPulse {
                        Text("Сила и длина стандартного импульса задаются iOS. Для регулировки силы выбери экспериментальный вариант после Стоп.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        valueSlider("Сила", value: $audio.settings.intensity, range: 0...1, step: 0.01,
                                display: "\(Int(audio.settings.intensity * 100)) %")
                        .disabled(audio.isPlaying && audio.playbackMode == .planned)
                    }
                    valueSlider("Порог реакции", value: $audio.settings.thresholdDB, range: -60 ... -5, step: 1,
                                display: "\(Int(audio.settings.thresholdDB)) dBFS")
                        .disabled(audio.isPlaying && audio.playbackMode == .planned)
                    Text("Чем ниже порог, тем тише бас, на который будет реакция. Например, −45 чувствительнее, чем −25.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !audio.playbackMode.usesSystemPulse {
                        valueSlider("Резкость", value: $audio.settings.sharpness, range: 0...1, step: 0.01,
                                display: "\(Int(audio.settings.sharpness * 100)) %")
                        .disabled(audio.playbackMode.usesSystemPulse || (audio.isPlaying && audio.playbackMode == .planned))
                    }
                    ProgressView(value: audio.drive).tint(.orange)
                        .accessibilityLabel("Энергия для вибрации")
                }
                Section("Bluetooth и синхронизация") {
                    Text(audio.route.isEmpty ? "Аудиовыход ещё не определён" : audio.route)
                    Text("Задержка выхода по данным iOS: ≈\(audio.latencyMS) мс")
                        .font(.caption).foregroundStyle(.secondary)
                    valueSlider("Поправка вибрации", value: $audio.settings.delayMS, range: -250...500, step: 10,
                                display: "\(Int(audio.settings.delayMS)) мс")
                        .disabled(audio.isPlaying && audio.playbackMode == .planned)
                    Text("Плюс — вибрация позже, минус — раньше. Новый режим использует общую шкалу времени музыки и вибрации; поправку Bluetooth подбираем на слух и по ощущениям.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Диагностика") {
                    Picker("Способ теста", selection: $audio.probeMode) {
                        ForEach(HapticProbeMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.disabled(audio.probeRunning)
                    Button(audio.probeRunning ? "Тест выполняется…" : "Тест выбранного способа (12 с)") {
                        audio.startBackgroundProbe()
                    }.disabled(!audio.isPlaying || audio.probeRunning || audio.useCombinedPlayback || audio.playbackMode == .planned)
                    Text("Запусти песню, выбери способ, нажми тест и выйди на главный экран на 6 секунд. Для блокировки повтори отдельно. Во время теста обычная реакция на музыку приостановлена.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(audio.probeMode == .systemSound
                         ? "System Sound: 6 стандартных вибраций с интервалом 2 секунды. Сила системная, ползунок её не меняет. Проверяем только доступность этого пути в фоне."
                         : audio.probeMode == .sharedSilent
                         ? "12 импульсов и синтезированный аудиоэлемент с нулевой громкостью. Сравниваем с успешным тестом с тихим тоном."
                         : audio.probeMode.includesTone
                         ? "12 импульсов и тихий тестовый тон. Звук и вибрацию создаёт один движок Core Haptics. Это эксперимент, фоновая работа не подтверждена."
                         : "Исходный режим: 12 импульсов Core Haptics без тестового тона.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(audio.hapticStatus).font(.caption)
                    if !audio.fileInfo.isEmpty { Text(audio.fileInfo).font(.caption) }
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
                        .disabled(audio.isPlaying && audio.playbackMode == .planned)
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

    @ViewBuilder private var blendControls: some View {
        Toggle("Энергия баса", isOn: $audio.settings.bassLayerEnabled)
        valueSlider("Уровень энергии", value: $audio.settings.bassLayerGain, range: 0...1, step: 0.01,
                    display: "\(Int(audio.settings.bassLayerGain * 100)) %")
            .disabled(!audio.settings.bassLayerEnabled)
        Toggle("Акценты ударов", isOn: $audio.settings.beatLayerEnabled)
        valueSlider("Уровень акцентов", value: $audio.settings.beatLayerGain, range: 0...1, step: 0.01,
                    display: "\(Int(audio.settings.beatLayerGain * 100)) %")
            .disabled(!audio.settings.beatLayerEnabled)
        valueSlider("Нарастание баса", value: $audio.settings.riseMS, range: 10...160, step: 10,
                    display: "\(Int(audio.settings.riseMS)) мс")
            .disabled(!audio.settings.bassLayerEnabled)
        valueSlider("Затухание баса", value: $audio.settings.fallMS, range: 40...500, step: 10,
                    display: "\(Int(audio.settings.fallMS)) мс")
            .disabled(!audio.settings.bassLayerEnabled)
        Text("Оба слоя смешиваются в одну огибающую. Общая сила управляет результатом. Для более текучего ощущения увеличь нарастание и затухание, а уровень акцентов уменьши.")
            .font(.caption).foregroundStyle(.secondary)
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
