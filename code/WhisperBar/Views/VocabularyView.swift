import SwiftUI

struct VocabularyView: View {
    @EnvironmentObject var store: VocabularyStore
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自定义词汇")
                        .font(.title2.bold())
                    Text("添加人名、地名或个人词汇，帮助 Whisper 正确识别")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { showAdd = true }) {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if store.terms.isEmpty {
                ContentUnavailableView(
                    "暂无词汇",
                    systemImage: "text.bubble",
                    description: Text("点击「添加」来教 Whisper 识别你的专属词汇")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.terms) { term in
                        TermRow(term: term)
                    }
                    .onDelete(perform: store.delete)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 400, minHeight: 400)
        .sheet(isPresented: $showAdd) {
            AddTermView { correct, aliases, note in
                store.add(correct: correct, aliases: aliases, note: note)
            }
        }
    }
}

// MARK: - Term Row

struct TermRow: View {
    let term: VocabularyStore.Term

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(term.correct)
                    .font(.body.bold())

                if !term.aliases.isEmpty {
                    Text("→")
                        .foregroundStyle(.secondary)
                    Text(term.aliases.joined(separator: " / "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !term.note.isEmpty {
                Text(term.note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add Term Sheet

struct AddTermView: View {
    let onAdd: (String, [String], String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var correct = ""
    @State private var aliasText = ""
    @State private var note = ""

    var aliases: [String] {
        aliasText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加词汇")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 4) {
                Text("正确词汇")
                    .font(.headline)
                TextField("如：OpenAI、李明", text: $correct)
                    .textFieldStyle(.roundedBorder)
                Text("这是你希望出现在转写结果中的正确形式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("错误写法（可选）")
                    .font(.headline)
                TextField("如：open ai, o p e n a i（用逗号分隔）", text: $aliasText)
                    .textFieldStyle(.roundedBorder)
                Text("Whisper 可能输出的错误形式，转写后自动替换")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("备注（可选）")
                    .font(.headline)
                TextField("备注", text: $note)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") {
                    onAdd(correct, aliases, note)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(correct.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380, height: 340)
    }
}

// MARK: - MenuBar Menu

extension Notification.Name {
    static let openRecordings = Notification.Name("WhisperBar.openRecordings")
    static let openVocabulary = Notification.Name("WhisperBar.openVocabulary")
}

struct MenuBarView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @EnvironmentObject var vocabulary: VocabularyStore

    var body: some View {
        Text(engine.statusText)

        Divider()

        Button("录音记录…") {
            NotificationCenter.default.post(name: .openRecordings, object: nil)
        }

        Button("词汇管理…") {
            NotificationCenter.default.post(name: .openVocabulary, object: nil)
        }

        Divider()

        Button("退出 WhisperBar") {
            NSApp.terminate(nil)
        }
    }
}
