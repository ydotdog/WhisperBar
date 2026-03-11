import AVFoundation

@MainActor
class RecordingEngine {
    var isRecording = false
    private(set) var audioLevels: [Float] = Array(repeating: 0.05, count: 30)

    var onComplete: ((URL) -> Void)?
    var onLevelUpdate: (([Float]) -> Void)?

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var tempURL: URL?

    func start() {
        guard !isRecording else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb_\(Int(Date().timeIntervalSince1970)).wav")
        tempURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.record()
            isRecording = true

            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateLevels() }
            }
        } catch {
            print("RecordingEngine: failed to start – \(error)")
        }
    }

    func stop() {
        levelTimer?.invalidate()
        levelTimer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        audioLevels = Array(repeating: 0.05, count: 30)

        if let url = tempURL {
            tempURL = nil
            onComplete?(url)
        }
    }

    private func updateLevels() {
        recorder?.updateMeters()
        let power = recorder?.averagePower(forChannel: 0) ?? -80.0
        // Map -60 dB..0 dB → 0..1
        let normalized = Float(max(0.0, min(1.0, (Double(power) + 60.0) / 60.0)))

        audioLevels.removeFirst()
        audioLevels.append(normalized)
        onLevelUpdate?(audioLevels)
    }
}
