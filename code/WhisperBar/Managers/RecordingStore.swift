import Foundation

@MainActor
class RecordingStore: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var retentionPolicy: RetentionPolicy = .thirtyDays

    // MARK: - Models

    struct Recording: Identifiable, Codable {
        var id = UUID()
        var filename: String          // e.g. "wb_1741234567.wav"
        var date: Date
        var status: Status
        var transcription: String?

        enum Status: Codable, Equatable {
            case pending
            case success
            case failed(String)

            var isFailed: Bool {
                if case .failed = self { return true }
                return false
            }
        }
    }

    enum RetentionPolicy: String, CaseIterable, Codable {
        case threeDays  = "3天"
        case thirtyDays = "30天"
        case permanent  = "永久"

        var maxAge: TimeInterval? {
            switch self {
            case .threeDays:  return 3 * 24 * 3600
            case .thirtyDays: return 30 * 24 * 3600
            case .permanent:  return nil
            }
        }
    }

    // MARK: - Storage Paths

    static let recordingsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WhisperBar/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let metadataURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WhisperBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recordings.json")
    }()

    private static let policyKey = "WhisperBar.retentionPolicy"

    // MARK: - Init

    init() {
        loadMetadata()
        if let raw = UserDefaults.standard.string(forKey: Self.policyKey),
           let policy = RetentionPolicy(rawValue: raw) {
            retentionPolicy = policy
        }
        applyRetentionPolicy()
    }

    // MARK: - Public API

    /// Save a recording file from a temp location to persistent storage.
    /// Returns the new Recording entry.
    @discardableResult
    func save(from tempURL: URL) -> Recording {
        let filename = tempURL.lastPathComponent
        let destURL = Self.recordingsDir.appendingPathComponent(filename)
        try? FileManager.default.copyItem(at: tempURL, to: destURL)

        let recording = Recording(
            filename: filename,
            date: Date(),
            status: .pending
        )
        recordings.insert(recording, at: 0)
        saveMetadata()
        return recording
    }

    /// Update a recording's status and transcription result.
    func update(id: UUID, status: Recording.Status, transcription: String? = nil) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[idx].status = status
        recordings[idx].transcription = transcription
        saveMetadata()
    }

    /// Get the file URL for a recording (nil if file is missing).
    func fileURL(for recording: Recording) -> URL? {
        let url = Self.recordingsDir.appendingPathComponent(recording.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Delete a single recording and its file.
    func delete(at offsets: IndexSet) {
        for idx in offsets {
            let r = recordings[idx]
            let url = Self.recordingsDir.appendingPathComponent(r.filename)
            try? FileManager.default.removeItem(at: url)
        }
        recordings.remove(atOffsets: offsets)
        saveMetadata()
    }

    func setRetentionPolicy(_ policy: RetentionPolicy) {
        retentionPolicy = policy
        UserDefaults.standard.set(policy.rawValue, forKey: Self.policyKey)
        applyRetentionPolicy()
    }

    // MARK: - Retention

    private func applyRetentionPolicy() {
        guard let maxAge = retentionPolicy.maxAge else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let expired = recordings.filter { $0.date < cutoff }
        for r in expired {
            let url = Self.recordingsDir.appendingPathComponent(r.filename)
            try? FileManager.default.removeItem(at: url)
        }
        recordings.removeAll { $0.date < cutoff }
        saveMetadata()
    }

    // MARK: - Persistence

    private func saveMetadata() {
        if let data = try? JSONEncoder().encode(recordings) {
            try? data.write(to: Self.metadataURL)
        }
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: Self.metadataURL),
              let decoded = try? JSONDecoder().decode([Recording].self, from: data)
        else { return }
        recordings = decoded
    }
}
