import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var engine: TranscriptionEngine

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("录音记录")
                        .font(.title2.bold())
                    Text("所有录音自动保存，转写失败可重试")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("保留", selection: Binding(
                    get: { store.retentionPolicy },
                    set: { store.setRetentionPolicy($0) }
                )) {
                    ForEach(RecordingStore.RetentionPolicy.allCases, id: \.self) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            .padding()

            Divider()

            if store.recordings.isEmpty {
                ContentUnavailableView(
                    "暂无录音",
                    systemImage: "waveform",
                    description: Text("录音完成后会自动保存在这里")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.recordings) { recording in
                        RecordingRow(recording: recording, engine: engine, store: store)
                    }
                    .onDelete(perform: store.delete)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 400)
    }
}

// MARK: - Recording Row

struct RecordingRow: View {
    let recording: RecordingStore.Recording
    let engine: TranscriptionEngine
    let store: RecordingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusIcon
                Text(recording.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(recording.date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                actionButtons
            }

            if let text = recording.transcription, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            if case .failed(let reason) = recording.status {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch recording.status {
        case .pending:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 14, height: 14)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if recording.status.isFailed {
                Button(action: {
                    Task { await engine.retryTranscription(for: recording) }
                }) {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(engine.isTranscribing)
            }

            if let text = recording.transcription, !text.isEmpty {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("复制文本")
            }
        }
    }
}
