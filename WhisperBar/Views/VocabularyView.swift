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
        NavigationStack {
            Form {
                Section {
                    TextField("正确词汇（如：OpenAI、李明）", text: $correct)
                } header: {
                    Text("词汇")
                } footer: {
                    Text("这是你希望出现在转写结果中的正确形式")
                        .font(.caption)
                }

                Section {
                    TextField("如：open ai, o p e n a i（用逗号分隔）", text: $aliasText)
                } header: {
                    Text("Whisper 可能识别成的错误写法（可选）")
                } footer: {
                    Text("填写后，App 会在转写完成后自动替换这些错误形式")
                        .font(.caption)
                }

                Section {
                    TextField("备注（可选）", text: $note)
                } header: {
                    Text("备注")
                }
            }
            .navigationTitle("添加词汇")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onAdd(correct, aliases, note)
                        dismiss()
                    }
                    .disabled(correct.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(width: 380, height: 380)
    }
}

// MARK: - MenuBar Menu

struct MenuBarView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @EnvironmentObject var vocabulary: VocabularyStore

    var body: some View {
        VStack(alignment: .leading) {
            Text(engine.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("词汇管理…") {
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.openVocabularyWindow()
                }
            }

            Divider()

            Button("退出 WhisperBar") {
                NSApp.terminate(nil)
            }
        }
    }
}
