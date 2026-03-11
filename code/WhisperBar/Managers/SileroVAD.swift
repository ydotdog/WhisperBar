import AVFoundation
import OnnxRuntimeBindings

/// Silero VAD v5 powered by ONNX Runtime.
/// Processes 16 kHz mono audio in 512-sample (32 ms) chunks and returns
/// per-chunk speech probabilities.
final class SileroVAD {

    struct Result {
        let hasSpeech: Bool
        let speechRatio: Float
        let trimmedRange: ClosedRange<Int>?
    }

    // Tuning knobs
    let threshold: Float = 0.5
    let minSpeechDuration: Double = 0.25   // ignore speech < 250 ms
    let padDuration: Double = 0.15         // pad 150 ms around speech boundaries
    let sampleRate: Int = 16_000
    let chunkSize: Int = 512               // 32 ms at 16 kHz

    private let env: ORTEnv
    private let session: ORTSession

    // MARK: - Init

    init?() {
        guard let modelPath = Bundle.main.path(forResource: "silero_vad", ofType: "onnx") else {
            return nil
        }
        do {
            env = try ORTEnv(loggingLevel: .warning)
            session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: nil)
        } catch {
            return nil
        }
    }

    // MARK: - Public API

    /// Analyze an audio file URL and return VAD result.
    func analyze(url: URL) -> Result {
        guard let samples = loadSamples(from: url), !samples.isEmpty else {
            return Result(hasSpeech: false, speechRatio: 0, trimmedRange: nil)
        }
        return analyze(samples: samples)
    }

    /// Analyze raw 16 kHz float samples.
    func analyze(samples: [Float]) -> Result {
        let chunkCount = samples.count / chunkSize
        guard chunkCount > 0 else {
            return Result(hasSpeech: false, speechRatio: 0, trimmedRange: nil)
        }

        // LSTM hidden state: [2, 1, 128]  (h + c, 1 layer, 128 units)
        var state = [Float](repeating: 0, count: 2 * 1 * 128)
        var probs = [Float]()
        var successCount = 0

        for i in 0..<chunkCount {
            let offset = i * chunkSize
            let chunk = Array(samples[offset..<offset + chunkSize])
            if let (p, newState) = infer(chunk: chunk, state: state) {
                probs.append(p)
                state = newState
                successCount += 1
            } else {
                probs.append(0)
            }
        }

        // If inference failed for all chunks, assume speech exists (let Whisper decide)
        if successCount == 0 {
            print("[SileroVAD] All inference calls failed, assuming speech present")
            return Result(hasSpeech: true, speechRatio: 1.0, trimmedRange: nil)
        }

        // Threshold → boolean mask
        var isSpeech = probs.map { $0 > threshold }

        // Remove short bursts
        let chunkDuration = Double(chunkSize) / Double(sampleRate)
        let minChunks = max(1, Int(minSpeechDuration / chunkDuration))
        isSpeech = removeShortSegments(isSpeech, minLength: minChunks)

        let speechCount = isSpeech.filter { $0 }.count
        let speechRatio = Float(speechCount) / Float(chunkCount)

        guard speechCount > 0 else {
            return Result(hasSpeech: false, speechRatio: 0, trimmedRange: nil)
        }

        // Compute trimmed sample range with padding
        let padChunks = max(1, Int(padDuration / chunkDuration))
        let firstSpeech = isSpeech.firstIndex(of: true)!
        let lastSpeech  = isSpeech.lastIndex(of: true)!
        let startSample = max(0, firstSpeech - padChunks) * chunkSize
        let endSample   = min(samples.count - 1, (min(chunkCount - 1, lastSpeech + padChunks) + 1) * chunkSize - 1)

        return Result(hasSpeech: true, speechRatio: speechRatio,
                      trimmedRange: startSample...endSample)
    }

    /// Trim silence from an audio file. Returns a new URL (caller cleans up)
    /// or the original if no trimming needed.
    func trimSilence(from url: URL) -> URL {
        guard let samples = loadSamples(from: url), !samples.isEmpty else { return url }
        let result = analyze(samples: samples)
        guard result.hasSpeech, let range = result.trimmedRange else { return url }

        // Skip if speech already covers most of the audio
        if result.speechRatio > 0.8 { return url }

        let trimmed = Array(samples[range])
        let outURL = url.deletingLastPathComponent()
            .appendingPathComponent("wb_vad_\(UUID().uuidString).wav")
        return writeSamples(trimmed, to: outURL) ? outURL : url
    }

    // MARK: - ONNX Inference

    private func infer(chunk: [Float], state: [Float]) -> (Float, [Float])? {
        do {
            // input: [1, 512]
            let inputData = chunk.withUnsafeBufferPointer { Data(buffer: $0) }
            let inputValue = try ORTValue(
                tensorData: NSMutableData(data: inputData),
                elementType: .float,
                shape: [1, NSNumber(value: chunkSize)]
            )

            // state: [2, 1, 128]
            let stateData = state.withUnsafeBufferPointer { Data(buffer: $0) }
            let stateValue = try ORTValue(
                tensorData: NSMutableData(data: stateData),
                elementType: .float,
                shape: [2, 1, 128]
            )

            // sr: [1] int64
            var sr = Int64(sampleRate)
            let srData = Data(bytes: &sr, count: MemoryLayout<Int64>.size)
            let srValue = try ORTValue(
                tensorData: NSMutableData(data: srData),
                elementType: .int64,
                shape: [1]
            )

            let outputs = try session.run(
                withInputs: ["input": inputValue, "state": stateValue, "sr": srValue],
                outputNames: Set(["output", "stateN"]),
                runOptions: nil
            )

            // speech probability
            guard let outVal = outputs["output"] else { return nil }
            let outData = try outVal.tensorData() as Data
            let prob = outData.withUnsafeBytes { $0.load(as: Float.self) }

            // updated LSTM state
            guard let stateNVal = outputs["stateN"] else { return nil }
            let stateNData = try stateNVal.tensorData() as Data
            let newState = stateNData.withUnsafeBytes { buf -> [Float] in
                Array(buf.bindMemory(to: Float.self))
            }

            return (prob, newState)
        } catch {
            return nil
        }
    }

    // MARK: - Audio I/O

    private func loadSamples(from url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frameCount)
        else { return nil }
        try? file.read(into: buffer)
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(frameCount)))
    }

    private func writeSamples(_ samples: [Float], to url: URL) -> Bool {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(buffer.floatChannelData![0], samples,
               samples.count * MemoryLayout<Float>.size)
        guard let outFile = try? AVAudioFile(forWriting: url, settings: format.settings)
        else { return false }
        try? outFile.write(from: buffer)
        return true
    }

    // MARK: - Utilities

    private func removeShortSegments(_ flags: [Bool], minLength: Int) -> [Bool] {
        var result = flags
        var i = 0
        while i < result.count {
            if result[i] {
                let start = i
                while i < result.count && result[i] { i += 1 }
                if i - start < minLength {
                    for j in start..<i { result[j] = false }
                }
            } else {
                i += 1
            }
        }
        return result
    }
}
