import Foundation

@MainActor
class VocabularyStore: ObservableObject {
    @Published var terms: [Term] = []

    struct Term: Identifiable, Codable, Hashable {
        var id = UUID()
        var correct: String          // The word as it should appear
        var aliases: [String]        // What Whisper tends to produce instead
        var note: String             // Optional personal note
    }

    /// Dictionary used for post-processing substitution: alias → correct
    var substitutions: [String: String] {
        var result: [String: String] = [:]
        for term in terms {
            for alias in term.aliases where !alias.isEmpty {
                result[alias] = term.correct
            }
        }
        return result
    }

    // MARK: - Persistence

    private static let saveURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WhisperBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary.json")
    }()

    init() { load() }

    func save() {
        if let data = try? JSONEncoder().encode(terms) {
            try? data.write(to: Self.saveURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.saveURL),
              let decoded = try? JSONDecoder().decode([Term].self, from: data)
        else { return }
        terms = decoded
    }

    // MARK: - Mutations

    func add(correct: String, aliases: [String], note: String) {
        terms.append(Term(correct: correct, aliases: aliases, note: note))
        save()
    }

    func delete(at offsets: IndexSet) {
        terms.remove(atOffsets: offsets)
        save()
    }

    func update(_ term: Term) {
        if let idx = terms.firstIndex(where: { $0.id == term.id }) {
            terms[idx] = term
            save()
        }
    }
}
