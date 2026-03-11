import SwiftUI
import WhisperKit
import ApplicationServices
import AVFoundation
import Accelerate

@MainActor
class TranscriptionEngine: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcribedText = ""
    @Published var autoCopied = false          // shows "✓ 已复制" indicator
    @Published var audioLevels: [Float] = Array(repeating: 0.05, count: 30)
    @Published var statusText = "长按空格 / ⌥⌘R 录音"
    @Published var modelState: ModelState = .loading
    @Published var needsAccessibility = false   // prompt user to grant permission

    enum ModelState { case loading, ready, error(String) }

    let holdThreshold: TimeInterval = 0.8

    private let recorder = RecordingEngine()
    private var whisperKit: WhisperKit?
    private var pressStartTime: Date?
    private var isToggleMode = false
    private var autoClearTask: Task<Void, Never>?
    private var accessibilityTimer: Timer?

    weak var vocabularyStore: VocabularyStore?
    weak var recordingStore: RecordingStore?

    private lazy var sileroVAD: SileroVAD? = SileroVAD()
    private let energyVAD = EnergyVAD()

    init() {
        setupRecorder()
        Task { await loadModel() }
        promptAccessibility()
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
            statusText = "长按空格 / ⌥⌘R 录音"
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

    /// Space bar long-press: pure push-to-talk (hold to record, release to stop).
    func handleHotkeyDown() {
        guard !isRecording, !isTranscribing, case .ready = modelState else { return }
        startRecording()
    }

    func handleHotkeyUp() {
        guard isRecording else { return }
        stopRecording()
    }

    /// ⌥⌘R toggle: press once to start, press again to stop.
    func handleToggleHotkey() {
        if isRecording {
            stopRecording()
        } else {
            guard !isTranscribing, case .ready = modelState else { return }
            startRecording()
        }
    }

    /// UI button: tap toggles, hold is push-to-talk.
    func handleButtonDown() {
        if isToggleMode && isRecording {
            isToggleMode = false
            stopRecording()
            return
        }
        guard !isRecording, !isTranscribing, case .ready = modelState else { return }
        pressStartTime = Date()
        startRecording()
    }

    func handleButtonUp() {
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

    /// Show system prompt once, then poll until permission is granted.
    private func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        needsAccessibility = !trusted

        guard !trusted else { return }
        // Poll every 2s; once granted, hide the warning and stop.
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                if AXIsProcessTrusted() {
                    self.needsAccessibility = false
                    timer.invalidate()
                    self.accessibilityTimer = nil
                }
            }
        }
    }

    // MARK: - Auto Paste

    /// Simulate ⌘V on a background thread to avoid @MainActor isolation issues.
    /// Uses .cghidEventTap (lowest level) and .combinedSessionState for reliability.
    private nonisolated static func simulatePaste() {
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.1) {
            let src = CGEventSource(stateID: CGEventSourceStateID.combinedSessionState)
            let vKey: CGKeyCode = 9 // kVK_ANSI_V

            let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
            down?.flags = CGEventFlags.maskCommand
            down?.post(tap: CGEventTapLocation.cghidEventTap)

            usleep(50_000) // 50ms gap so target app can process keyDown before keyUp

            let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
            up?.flags = CGEventFlags.maskCommand
            up?.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }

    // MARK: - Audio Normalization

    /// Peak-normalize a WAV file so quiet recordings reach -3 dB.
    /// Returns a new file URL (caller must clean up) or the original URL if skipped.
    private nonisolated static func normalizeAudio(at url: URL) -> URL {
        do {
            let inputFile = try AVAudioFile(forReading: url)
            let format = inputFile.processingFormat
            let frameCount = AVAudioFrameCount(inputFile.length)

            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
            else { return url }

            try inputFile.read(into: buffer)
            buffer.frameLength = frameCount

            guard let samples = buffer.floatChannelData?[0] else { return url }
            let count = vDSP_Length(frameCount)

            // Find peak amplitude
            var peak: Float = 0
            vDSP_maxmgv(samples, 1, &peak, count)

            // Skip if silence or already loud enough
            guard peak > 0.0001, peak < 0.5 else { return url }

            // Scale to -3 dB (0.707), cap amplification at 10×
            var scale = min(Float(0.707) / peak, 10.0)
            vDSP_vsmul(samples, 1, &scale, samples, 1, count)

            // Write normalized audio to a new file
            let outURL = url.deletingLastPathComponent()
                .appendingPathComponent("wb_norm_\(UUID().uuidString).wav")
            let outFile = try AVAudioFile(
                forWriting: outURL,
                settings: inputFile.fileFormat.settings
            )
            try outFile.write(from: buffer)
            return outURL
        } catch {
            return url
        }
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
        guard whisperKit != nil else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        isTranscribing = true
        statusText = "转写中…"

        // Persist the recording file; fallback to temp URL if store unavailable
        if let store = recordingStore {
            let recording = store.save(from: url)
            try? FileManager.default.removeItem(at: url)
            if let storedURL = store.fileURL(for: recording) {
                await performTranscription(audioURL: storedURL, recordingID: recording.id)
            } else {
                isTranscribing = false
            }
        } else {
            // No store — transcribe directly from temp file, clean up after
            defer { try? FileManager.default.removeItem(at: url) }
            await performTranscription(audioURL: url, recordingID: nil)
        }
    }

    /// Retry transcription for a previously failed recording.
    func retryTranscription(for recording: RecordingStore.Recording) async {
        guard !isTranscribing,
              let audioURL = recordingStore?.fileURL(for: recording) else { return }

        recordingStore?.update(id: recording.id, status: .pending)
        isTranscribing = true
        statusText = "转写中…"

        await performTranscription(audioURL: audioURL, recordingID: recording.id)
    }

    /// Core transcription pipeline shared by first-run and retry.
    private func performTranscription(audioURL: URL, recordingID: UUID?) async {
        guard let kit = whisperKit else {
            isTranscribing = false
            return
        }

        var tempFiles: [URL] = []
        defer { tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        // VAD: trim trailing silence to prevent hallucination loops
        var trimmedURL = audioURL
        if let silero = sileroVAD {
            let t = silero.trimSilence(from: audioURL)
            trimmedURL = t
            if t.lastPathComponent != audioURL.lastPathComponent { tempFiles.append(t) }
        } else {
            let t = energyVAD.trimSilence(from: audioURL)
            trimmedURL = t
            if t.lastPathComponent != audioURL.lastPathComponent { tempFiles.append(t) }
        }

        do {
            // Attempt 1: trimmed audio, no promptTokens (avoids WhisperKit #372 bug)
            var text = try await runWhisper(
                kit: kit, audioPath: trimmedURL.path,
                promptTokens: nil,
                noSpeechThreshold: 0.6,
                logProbThreshold: -1.0,
                compressionRatioThreshold: 2.4
            )

            // Attempt 2: original audio + relaxed filters (keep compressionRatio to block hallucinations)
            if text.isEmpty {
                statusText = "重试中…"
                text = try await runWhisper(
                    kit: kit, audioPath: audioURL.path,
                    promptTokens: nil,
                    noSpeechThreshold: nil,
                    logProbThreshold: nil,
                    firstTokenLogProbThreshold: nil,
                    compressionRatioThreshold: 2.4,
                    temperature: 0.0
                )
            }

            // Post-processing: remove hallucination loops
            text = Self.removeRepetitions(text)

            // Post-processing: vocabulary substitution (case-insensitive)
            if let subs = vocabularyStore?.substitutions {
                for (wrong, correct) in subs where !wrong.isEmpty {
                    text = text.replacingOccurrences(
                        of: wrong, with: correct,
                        options: .caseInsensitive
                    )
                }
            }

            transcribedText = text

            if !text.isEmpty {
                if let rid = recordingID {
                    recordingStore?.update(id: rid, status: .success, transcription: text)
                }

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                autoCopied = true

                statusText = "已复制到剪贴板"

                // Attempt auto-paste silently (best-effort)
                if AXIsProcessTrusted() {
                    Self.simulatePaste()
                }

                autoClearTask = Task {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled else { return }
                    self.transcribedText = ""
                    self.autoCopied = false
                    self.statusText = "长按空格 / ⌥⌘R 录音"
                }
            } else {
                if let rid = recordingID {
                    recordingStore?.update(id: rid, status: .failed("未检测到语音"))
                }
                statusText = "未检测到语音"
                autoClearTask = Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    self.statusText = "长按空格 / ⌥⌘R 录音"
                }
            }
        } catch {
            if let rid = recordingID {
                recordingStore?.update(id: rid, status: .failed(error.localizedDescription))
            }
            statusText = "转写失败：\(error.localizedDescription)"
        }

        isTranscribing = false
    }

    // MARK: - Whisper Helpers

    private func buildPromptTokens(kit: WhisperKit) -> [Int]? {
        var prompt = "以下是普通话的句子。"
        if let tokenizer = kit.tokenizer,
           let terms = vocabularyStore?.terms, !terms.isEmpty {
            let names = terms.map { $0.correct }
            var suffix = "涉及的专有名词："
            for (i, name) in names.enumerated() {
                let candidate = suffix + name + (i < names.count - 1 ? "、" : "。")
                if tokenizer.encode(text: prompt + candidate).count > 200 { break }
                suffix = candidate
            }
            if suffix != "涉及的专有名词：" { prompt += suffix }
        }
        return kit.tokenizer?.encode(text: prompt)
    }

    private func runWhisper(
        kit: WhisperKit,
        audioPath: String,
        promptTokens: [Int]?,
        noSpeechThreshold: Float?,
        logProbThreshold: Float?,
        firstTokenLogProbThreshold: Float? = -1.5,
        compressionRatioThreshold: Float?,
        temperature: Float = 0.0
    ) async throws -> String {
        let options = DecodingOptions(
            task: .transcribe,
            language: "zh",
            temperature: temperature,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            detectLanguage: false,
            promptTokens: promptTokens,
            compressionRatioThreshold: compressionRatioThreshold,
            logProbThreshold: logProbThreshold,
            firstTokenLogProbThreshold: firstTokenLogProbThreshold,
            noSpeechThreshold: noSpeechThreshold
        )
        let results = try await kit.transcribe(audioPath: audioPath, decodeOptions: options)
        return results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detect and remove hallucination loops (e.g. "我会想到你" repeated 20+ times).
    /// Scans for any substring of 2-20 chars that repeats 3+ times consecutively, keeps only first occurrence.
    private static func removeRepetitions(_ text: String) -> String {
        var result = text
        // Try pattern lengths from longest to shortest for greedy matching
        for len in stride(from: min(20, text.count / 3), through: 2, by: -1) {
            let chars = Array(result)
            guard chars.count >= len * 3 else { continue }
            var i = 0
            var cleaned = ""
            while i < chars.count {
                let remaining = chars.count - i
                guard remaining >= len * 2 else {
                    cleaned += String(chars[i...])
                    break
                }
                let phrase = String(chars[i..<i + len])
                // Count consecutive repeats
                var count = 1
                var j = i + len
                while j + len <= chars.count && String(chars[j..<j + len]) == phrase {
                    count += 1
                    j += len
                }
                if count >= 3 {
                    // Hallucination detected: keep phrase once, skip the rest
                    cleaned += phrase
                    i = j
                } else {
                    cleaned.append(chars[i])
                    i += 1
                }
            }
            result = cleaned
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
