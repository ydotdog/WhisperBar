import SwiftUI
import WhisperKit

@MainActor
class TranscriptionEngine: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcribedText = ""
    @Published var autoCopied = false          // shows "✓ 已复制" indicator
    @Published var audioLevels: [Float] = Array(repeating: 0.05, count: 30)
    @Published var statusText = "⌥⌘R 开始录音"
    @Published var modelState: ModelState = .loading
    @Published var needsAccessibility = false   // prompt user to grant permission

    enum ModelState { case loading, ready, error(String) }

    let holdThreshold: TimeInterval = 0.8

    private let recorder = RecordingEngine()
    private var whisperKit: WhisperKit?
    private var pressStartTime: Date?
    private var isToggleMode = false
    private var autoClearTask: Task<Void, Never>?

    weak var vocabularyStore: VocabularyStore?

    init() {
        setupRecorder()
        Task { await loadModel() }
    }

    // MARK: - Setup

    private func setupRecorder() {
        recorder.onComplete = { [weak self] url in
            Task { @MainActor [weak self] in await self?.transcribeFile(at: url) }
        }
        recorder.onLevelUpdate = { [weak self] levels in
            Task { @MainActor [weak self] in self?.audioLevels = levels }
        }
    }

    // MARK: - Model Loading

    private func loadModel() async {
        modelState = .loading
        statusText = "正在加载模型…"
        do {
            guard let bundleModelsURL = Bundle.main.url(forResource: "Models", withExtension: nil),
                  let modelFolderURL = firstModelFolder(in: bundleModelsURL)
            else {
                throw NSError(domain: "WhisperBar", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "App bundle 中未找到模型文件夹"])
            }
            whisperKit = try await WhisperKit(modelFolder: modelFolderURL.path)
            modelState = .ready
            statusText = "⌥⌘R 开始录音"
        } catch {
            modelState = .error(error.localizedDescription)
            statusText = "加载失败：\(error.localizedDescription)"
        }
    }

    private func firstModelFolder(in modelsURL: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: modelsURL, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? []
        return contents.first {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    // MARK: - Recording Trigger

    func handleHotkeyDown() {
        if isToggleMode && isRecording {
            isToggleMode = false
            stopRecording()
            return
        }
        guard !isRecording, case .ready = modelState else { return }
        pressStartTime = Date()
        startRecording()
    }

    func handleHotkeyUp() {
        guard isRecording, let start = pressStartTime else { return }
        let held = Date().timeIntervalSince(start)
        pressStartTime = nil

        if held >= holdThreshold {
            isToggleMode = false
            stopRecording()
        } else {
            isToggleMode = true
        }
    }

    func handleButtonDown() { handleHotkeyDown() }
    func handleButtonUp()   { handleHotkeyUp() }

    func markNeedsAccessibility() {
        needsAccessibility = true
    }

    // MARK: - Recording Control

    private func startRecording() {
        // Cancel any pending auto-clear and reset state
        autoClearTask?.cancel()
        autoClearTask = nil
        transcribedText = ""
        autoCopied = false

        recorder.start()
        isRecording = true
        statusText = "录音中…"
    }

    private func stopRecording() {
        recorder.stop()
        isRecording = false
        audioLevels = Array(repeating: 0.05, count: 30)
    }

    // MARK: - Transcription

    private func transcribeFile(at url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let kit = whisperKit else { return }

        isTranscribing = true
        statusText = "转写中…"

        do {
            // Fix for Chinese-English code-switching:
            // Auto language detection samples only the first few tokens and often
            // picks "en" when English words appear early, locking the entire transcription
            // into English mode. Forcing "zh" lets Whisper's multilingual model
            // correctly handle mixed Chinese-English speech (code-switching).
            let options = DecodingOptions(
                task: .transcribe,
                language: "zh",
                usePrefillPrompt: true
            )
            let results = try await kit.transcribe(audioPath: url.path, decodeOptions: options)
            var text = results.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let subs = vocabularyStore?.substitutions {
                for (wrong, correct) in subs where !wrong.isEmpty {
                    text = text.replacingOccurrences(of: wrong, with: correct)
                }
            }

            transcribedText = text

            if !text.isEmpty {
                // Auto-copy to clipboard
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                autoCopied = true
                statusText = "✓ 已复制到剪贴板"

                // Auto-clear after 6 seconds
                autoClearTask = Task {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled else { return }
                    self.transcribedText = ""
                    self.autoCopied = false
                    self.statusText = "⌥⌘R 开始录音"
                }
            } else {
                statusText = "未检测到语音"
                autoClearTask = Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    self.statusText = "⌥⌘R 开始录音"
                }
            }
        } catch {
            statusText = "转写失败：\(error.localizedDescription)"
        }

        isTranscribing = false
    }
}
