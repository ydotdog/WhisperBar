import Accelerate
import AVFoundation

/// Energy-based Voice Activity Detection using Accelerate/vDSP.
/// Detects speech segments by analyzing RMS energy in short frames.
struct EnergyVAD {

    /// Result of VAD analysis.
    struct Result {
        let hasSpeech: Bool
        let speechRatio: Float          // fraction of frames with speech
        let trimmedRange: ClosedRange<Int>?  // sample range of speech region
    }

    // Parameters
    let sampleRate: Int = 16_000
    let frameDuration: Double = 0.03    // 30 ms per frame
    let speechThresholdDB: Float = -40  // frames above this are speech candidates
    let minSpeechDuration: Double = 0.2 // ignore speech shorter than 200ms
    let padDuration: Double = 0.15      // pad 150ms around speech boundaries

    /// Analyze an audio file and return VAD result.
    func analyze(url: URL) -> Result {
        guard let samples = loadSamples(from: url), samples.count > 0 else {
            return Result(hasSpeech: false, speechRatio: 0, trimmedRange: nil)
        }

        let frameSize = Int(Double(sampleRate) * frameDuration)
        let frameCount = samples.count / frameSize
        guard frameCount > 0 else {
            return Result(hasSpeech: false, speechRatio: 0, trimmedRange: nil)
        }

        // Compute RMS energy (in dB) for each frame
        var energiesDB = [Float](repeating: -100, count: frameCount)
        for i in 0..<frameCount {
            let offset = i * frameSize
            let slice = Array(samples[offset..<offset + frameSize])
            var sumSq: Float = 0
            vDSP_svesq(slice, 1, &sumSq, vDSP_Length(frameSize))
            let rms = sqrt(sumSq / Float(frameSize))
            energiesDB[i] = rms > 1e-10 ? 20 * log10(rms) : -100
        }

        // Adaptive noise floor: use the 10th percentile of energy
        let sorted = energiesDB.sorted()
        let noiseFloorIdx = max(0, Int(Float(frameCount) * 0.1))
        let noiseFloor = sorted[noiseFloorIdx]

        // Speech threshold: at least speechThresholdDB, or noiseFloor + 15 dB
        let threshold = max(speechThresholdDB, noiseFloor + 15)

        // Mark frames as speech
        var isSpeech = energiesDB.map { $0 > threshold }

        // Apply minimum duration filter: remove short speech bursts
        let minSpeechFrames = Int(minSpeechDuration / frameDuration)
        isSpeech = filterShortSegments(isSpeech, minLength: minSpeechFrames)

        let speechFrameCount = isSpeech.filter { $0 }.count
        let speechRatio = Float(speechFrameCount) / Float(frameCount)

        guard speechFrameCount > 0 else {
            return Result(hasSpeech: false, speechRatio: 0, trimmedRange: nil)
        }

        // Find trimmed range (first speech frame to last speech frame, with padding)
        let padFrames = Int(padDuration / frameDuration)
        let firstSpeech = isSpeech.firstIndex(of: true)!
        let lastSpeech = isSpeech.lastIndex(of: true)!

        let startFrame = max(0, firstSpeech - padFrames)
        let endFrame = min(frameCount - 1, lastSpeech + padFrames)

        let startSample = startFrame * frameSize
        let endSample = min(samples.count - 1, (endFrame + 1) * frameSize - 1)

        return Result(
            hasSpeech: true,
            speechRatio: speechRatio,
            trimmedRange: startSample...endSample
        )
    }

    /// Trim silence from an audio file. Returns a new file URL with only speech,
    /// or the original URL if no trimming needed / analysis failed.
    func trimSilence(from url: URL) -> URL {
        let result = analyze(url: url)
        guard result.hasSpeech, let range = result.trimmedRange else { return url }

        guard let samples = loadSamples(from: url) else { return url }

        // If speech covers >80% of the audio, no need to trim
        if result.speechRatio > 0.8 { return url }

        let trimmed = Array(samples[range])

        // Write trimmed audio
        let outURL = url.deletingLastPathComponent()
            .appendingPathComponent("wb_vad_\(UUID().uuidString).wav")

        guard writeSamples(trimmed, to: outURL) else { return url }
        return outURL
    }

    // MARK: - Helpers

    private func loadSamples(from url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat, frameCapacity: frameCount
              ) else { return nil }
        try? file.read(into: buffer)
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(frameCount)))
    }

    private func writeSamples(_ samples: [Float], to url: URL) -> Bool {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

        guard let outFile = try? AVAudioFile(
            forWriting: url,
            settings: format.settings
        ) else { return false }
        try? outFile.write(from: buffer)
        return true
    }

    /// Remove segments shorter than minLength from a boolean array.
    private func filterShortSegments(_ flags: [Bool], minLength: Int) -> [Bool] {
        var result = flags
        var i = 0
        while i < result.count {
            if result[i] {
                let start = i
                while i < result.count && result[i] { i += 1 }
                let length = i - start
                if length < minLength {
                    for j in start..<i { result[j] = false }
                }
            } else {
                i += 1
            }
        }
        return result
    }
}
